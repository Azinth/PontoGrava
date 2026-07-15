import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let meetingStore: MeetingStore
    let deviceManager: AudioDeviceManager
    let playbackController: AudioPlaybackController
    let notificationService: NotificationService

    @Published var selectedMicrophoneID: String?
    @Published var recordingMode: RecordingMode {
        didSet { settings.recordingMode = recordingMode }
    }
    @Published var selectedDiscordGuildID: String? {
        didSet { settings.discordGuildID = selectedDiscordGuildID }
    }
    @Published var selectedDiscordChannelID: String? {
        didSet { settings.discordChannelID = selectedDiscordChannelID }
    }
    @Published var selectedRecordID: UUID? {
        didSet { playbackController.load(selectedRecord) }
    }
    @Published var phase: AppPhase = .idle
    @Published var progress: Double = 0
    @Published var statusDetail = "Escolha o microfone e inicie uma reunião."
    @Published var warningMessage: String?
    @Published var errorMessage: String?
    @Published var showOnboarding: Bool
    @Published var meetingManagementRequest: MeetingManagementRequest?
    @Published var notificationPermissionState: NotificationPermissionState = .unknown
    @Published var showNotificationInvitation = false
    @Published private(set) var summaryRevision = 0
    @Published private(set) var summarizingRecordID: UUID?
    @Published private(set) var recordingTimeline = RecordingTimeline()
    @Published private(set) var systemAudioLevel: Float = 0
    @Published private(set) var microphoneAudioLevel: Float = 0
    @Published private(set) var discordAudioLevel: Float = 0
    @Published var discordTokenDraft = ""
    @Published private(set) var discordHasToken: Bool
    @Published private(set) var discordConnected = false
    @Published private(set) var discordConnectionDetail = "Configure o bot para listar os canais."
    @Published private(set) var discordApplicationID: String?
    @Published private(set) var discordGuilds: [DiscordGuild] = []
    @Published private(set) var discordChannels: [DiscordChannel] = []
    @Published private(set) var discordParticipants: [String] = []
    @Published var discordRecoveryRequest: DiscordRecoveryRequest?

    private let recordingEngine = RecordingEngine()
    private let transcriptionService = TranscriptionService()
    private let summaryService = SummaryService()
    private let discordBotClient = DiscordBotClient()
    private let meetingFileService: MeetingFileService
    private var activeFolder: URL?
    private var activeCreatedAt: Date?
    private var activeMicrophoneName: String?
    private var activeDiscordRecording = false

    init(
        settings: AppSettings? = nil,
        meetingStore: MeetingStore? = nil,
        deviceManager: AudioDeviceManager? = nil,
        playbackController: AudioPlaybackController? = nil,
        notificationService: NotificationService? = nil,
        meetingFileService: MeetingFileService? = nil
    ) {
        let settings = settings ?? AppSettings()
        self.settings = settings
        recordingMode = settings.recordingMode
        selectedDiscordGuildID = settings.discordGuildID
        selectedDiscordChannelID = settings.discordChannelID
        self.meetingStore = meetingStore ?? MeetingStore()
        self.deviceManager = deviceManager ?? AudioDeviceManager()
        self.playbackController = playbackController ?? AudioPlaybackController()
        self.notificationService = notificationService ?? NotificationService()
        self.meetingFileService = meetingFileService ?? MeetingFileService()
        discordHasToken = DiscordTokenStore.load() != nil
        discordRecoveryRequest = nil
        showOnboarding = !settings.hasCompletedOnboarding

        recordingEngine.onWarning = { [weak self] message in
            Task { @MainActor in self?.warningMessage = message }
        }
        recordingEngine.onAudioLevels = { [weak self] system, microphone in
            Task { @MainActor in
                self?.systemAudioLevel = system
                self?.microphoneAudioLevel = microphone
            }
        }
        discordBotClient.onEvent = { [weak self] event in
            self?.handleDiscordEvent(event)
        }
    }

    var records: [MeetingRecord] { meetingStore.records }
    var isBusy: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording }
    var isPaused: Bool { phase == .paused }
    var isRecordingSession: Bool { isRecording || isPaused }
    var isDiscordRecording: Bool { isRecordingSession && activeDiscordRecording }
    var canPauseRecording: Bool { isRecordingSession && !activeDiscordRecording }
    var recordingStartedAt: Date? { recordingTimeline.startedAt }
    var summaryUnavailableMessage: String? { SummaryService.unavailabilityMessage }

    var canBeginRecording: Bool {
        guard phase == .idle else { return false }
        if recordingMode == .discord {
            return discordConnected
                && selectedDiscordGuildID != nil
                && selectedDiscordChannelID != nil
        }
        return selectedMicrophoneID != nil
    }

    var selectedRecord: MeetingRecord? {
        guard let selectedRecordID else { return nil }
        return records.first { $0.id == selectedRecordID }
    }

    var selectedMicrophoneName: String {
        guard let selectedMicrophoneID else { return "Nenhum microfone" }
        return deviceManager.name(for: selectedMicrophoneID) ?? "Microfone indisponível"
    }

    var recordingSourceName: String {
        if activeDiscordRecording {
            let channel = discordChannels.first { $0.id == selectedDiscordChannelID }?.name ?? "Discord"
            return "Discord · #\(channel)"
        }
        return selectedMicrophoneName
    }

    var discordInviteURL: URL? {
        guard let discordApplicationID else { return nil }
        return URL(string: "https://discord.com/oauth2/authorize?client_id=\(discordApplicationID)&scope=bot%20applications.commands&permissions=1051648")
    }

    func initialize() async {
        do {
            try settings.ensureOutputFolder()
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshMicrophones()
        detectDiscordRecoverySession()
        restoreSummaryPaths()
        if discordHasToken { await connectDiscord() }
        if selectedRecordID == nil { selectedRecordID = records.first?.id }
        await refreshNotificationPermission()
        showNotificationInvitation = settings.hasCompletedOnboarding
            && !settings.hasSeenNotificationInvitation
            && notificationPermissionState == .notDetermined
    }

    func refreshMicrophones() {
        deviceManager.refresh()
        selectedMicrophoneID = deviceManager.preferredDeviceID(
            currentSelection: selectedMicrophoneID
        )
    }

    func beginRecording() async {
        if recordingMode == .discord {
            await beginDiscordRecording()
        } else {
            await beginMacRecording()
        }
    }

    private func beginMacRecording() async {
        guard phase == .idle else { return }
        playbackController.pause()
        phase = .preparing
        progress = 0
        statusDetail = "Validando permissões e dispositivos…"

        refreshMicrophones()
        guard let microphoneID = selectedMicrophoneID,
              deviceManager.contains(deviceID: microphoneID) else {
            fail(AppError.microphoneUnavailable)
            return
        }
        guard await deviceManager.requestMicrophonePermission() else {
            fail(AppError.microphonePermissionDenied)
            return
        }
        let createdAt = Date()
        let folder = uniqueMeetingFolder(for: createdAt, imported: false)
        do {
            try settings.ensureOutputFolder()
            try await recordingEngine.start(
                microphoneID: microphoneID,
                destinationFolder: folder
            )
            deviceManager.markScreenCaptureAvailable()
            activeFolder = folder
            activeCreatedAt = createdAt
            activeMicrophoneName = selectedMicrophoneName
            recordingTimeline.start(at: createdAt)
            phase = .recording
            statusDetail = "Sistema + \(selectedMicrophoneName)"
        } catch {
            try? FileManager.default.removeItem(at: folder)
            fail(error)
        }
    }

    func pauseRecording() {
        guard phase == .recording, !activeDiscordRecording else { return }
        do {
            try recordingEngine.pause()
            recordingTimeline.pause(at: Date())
            phase = .paused
            statusDetail = "Pausada — o intervalo não será incluído no WAV."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resumeRecording() {
        guard phase == .paused, !activeDiscordRecording else { return }
        do {
            try recordingEngine.resume()
            recordingTimeline.resume(at: Date())
            phase = .recording
            statusDetail = "Sistema + \(selectedMicrophoneName)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() async {
        if activeDiscordRecording {
            await stopDiscordRecording()
        } else {
            await stopMacRecording()
        }
    }

    private func stopMacRecording() async {
        guard isRecordingSession,
              let folder = activeFolder,
              let createdAt = activeCreatedAt else { return }
        RecordingPanelController.shared.hide()
        phase = .finalizing
        statusDetail = "Sincronizando e combinando as duas fontes…"

        do {
            let result = try await recordingEngine.stop()
            var record = MeetingRecord(
                id: UUID(),
                createdAt: createdAt,
                title: MeetingNaming.title(for: createdAt),
                folderPath: folder.path,
                audioPath: result.audioURL.path,
                transcriptPath: nil,
                duration: result.duration,
                status: .transcribing,
                errorMessage: nil,
                microphoneName: activeMicrophoneName ?? "Microfone"
            )
            meetingStore.upsert(record)
            selectedRecordID = record.id
            clearActiveRecording()
            await transcribe(&record)
        } catch {
            clearActiveRecording()
            fail(error)
        }
    }

    func importAudio(from source: URL) async {
        guard phase == .idle else { return }
        phase = .finalizing
        progress = 0
        statusDetail = "Convertendo o arquivo para WAV…"

        let createdAt = Date()
        let folder = uniqueMeetingFolder(for: createdAt, imported: true)
        let destination = folder.appendingPathComponent("audio.wav")
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let duration = try await AudioImportService.convertToStandardWAV(
                source: source,
                destination: destination
            )
            var record = MeetingRecord(
                id: UUID(),
                createdAt: createdAt,
                title: MeetingNaming.title(for: createdAt, imported: true),
                folderPath: folder.path,
                audioPath: destination.path,
                transcriptPath: nil,
                duration: duration,
                status: .transcribing,
                errorMessage: nil,
                microphoneName: "Arquivo importado"
            )
            meetingStore.upsert(record)
            selectedRecordID = record.id
            await transcribe(&record)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            fail(error)
        }
    }

    func retranscribe(_ record: MeetingRecord) async {
        guard phase == .idle, FileManager.default.fileExists(atPath: record.audioPath) else { return }
        var mutable = record
        mutable.status = .transcribing
        mutable.errorMessage = nil
        meetingStore.upsert(mutable)
        await transcribe(&mutable)
    }

    func requestSummary(for record: MeetingRecord) {
        guard phase == .idle, record.transcriptURL != nil else { return }
        if hasSummary(record) {
            meetingManagementRequest = .replaceSummary(record)
        } else {
            Task { await generateSummary(for: record, overwrite: false) }
        }
    }

    func replaceSummary(for record: MeetingRecord) async {
        meetingManagementRequest = nil
        await generateSummary(for: record, overwrite: true)
    }

    func hasSummary(_ record: MeetingRecord) -> Bool {
        FileManager.default.fileExists(atPath: summaryURL(for: record).path)
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.outputFolderURL
        panel.prompt = "Selecionar"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.outputFolderPath = url.path
        do {
            try settings.ensureOutputFolder()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Importar"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importAudio(from: url) }
    }

    func reveal(_ record: MeetingRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.audioURL])
    }

    func openOutputFolder() {
        NSWorkspace.shared.open(settings.outputFolderURL)
    }

    func presentRename(_ record: MeetingRecord) {
        guard phase == .idle else { return }
        meetingManagementRequest = .rename(record)
    }

    func presentDelete(_ record: MeetingRecord) {
        guard phase == .idle else { return }
        meetingManagementRequest = .delete(record)
    }

    func renameMeeting(_ record: MeetingRecord, to name: String) throws {
        guard phase == .idle else { return }
        let wasLoaded = playbackController.loadedRecordID == record.id
        if wasLoaded { playbackController.reset() }
        do {
            let renamed = try meetingFileService.rename(record, to: name)
            meetingStore.upsert(renamed)
            meetingManagementRequest = nil
            if selectedRecordID == renamed.id {
                playbackController.load(renamed)
            }
        } catch {
            if wasLoaded { playbackController.load(record) }
            throw error
        }
    }

    func deleteMeeting(_ record: MeetingRecord) async {
        guard phase == .idle else { return }
        let wasLoaded = playbackController.loadedRecordID == record.id
        if wasLoaded { playbackController.reset() }
        do {
            try await meetingFileService.moveToTrash(record)
            removeFromHistory(record)
        } catch MeetingFileError.folderMissing {
            if wasLoaded { playbackController.load(record) }
            meetingManagementRequest = .removeOrphan(record)
        } catch {
            if wasLoaded { playbackController.load(record) }
            meetingManagementRequest = nil
            errorMessage = error.localizedDescription
        }
    }

    func removeOrphanedMeeting(_ record: MeetingRecord) {
        guard phase == .idle else { return }
        if playbackController.loadedRecordID == record.id {
            playbackController.reset()
        }
        removeFromHistory(record)
    }

    func requestNotificationPermission() async {
        settings.hasSeenNotificationInvitation = true
        showNotificationInvitation = false
        do {
            _ = try await notificationService.requestPermission()
            await refreshNotificationPermission()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissNotificationInvitation() {
        settings.hasSeenNotificationInvitation = true
        showNotificationInvitation = false
    }

    func openNotificationSettings() {
        notificationService.openSettings()
    }

    func refreshNotificationPermission() async {
        notificationPermissionState = await notificationService.permissionState()
        if notificationPermissionState != .notDetermined {
            showNotificationInvitation = false
        }
    }

    func handleDeepLink(_ url: URL) {
        guard let id = MeetingRoute.meetingID(from: url),
              records.contains(where: { $0.id == id }) else { return }
        selectedRecordID = id
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func showRecordingPanel() {
        guard isRecordingSession, !activeDiscordRecording else { return }
        RecordingPanelController.shared.show(model: self)
    }

    func hideRecordingPanel() {
        RecordingPanelController.shared.hide()
    }

    func recordedDuration(at date: Date = Date()) -> TimeInterval {
        recordingTimeline.elapsed(at: date)
    }

    func finishOnboarding() {
        settings.hasCompletedOnboarding = true
        settings.hasSeenNotificationInvitation = true
        showOnboarding = false
        refreshMicrophones()
    }

    func requestMicrophonePermission() async {
        _ = await deviceManager.requestMicrophonePermission()
    }

    func requestScreenPermission() {
        _ = deviceManager.requestScreenPermission()
    }

    func saveDiscordTokenAndConnect() async {
        let token = discordTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            errorMessage = "Cole o token do bot do Discord."
            return
        }
        do {
            try DiscordTokenStore.save(token)
            discordTokenDraft = ""
            discordHasToken = true
            await connectDiscord()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func connectDiscord() async {
        guard phase == .idle, let token = DiscordTokenStore.load() else { return }
        discordConnectionDetail = "Conectando ao Discord…"
        do {
            let identity = try await discordBotClient.connect(token: token)
            discordApplicationID = identity.applicationId
            discordGuilds = try await discordBotClient.listGuilds()
            discordConnected = true
            discordConnectionDetail = "Conectado como \(identity.username)."
            let selected = selectedDiscordGuildID.flatMap { id in
                discordGuilds.first { $0.id == id }?.id
            } ?? discordGuilds.first?.id
            await selectDiscordGuild(selected)
        } catch {
            discordConnected = false
            discordGuilds = []
            discordChannels = []
            discordConnectionDetail = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func removeDiscordToken() {
        guard !isRecordingSession else { return }
        DiscordTokenStore.delete()
        discordBotClient.terminate()
        discordHasToken = false
        discordConnected = false
        discordApplicationID = nil
        discordGuilds = []
        discordChannels = []
        discordAudioLevel = 0
        selectedDiscordGuildID = nil
        selectedDiscordChannelID = nil
        discordConnectionDetail = "Configure o bot para listar os canais."
    }

    func selectDiscordGuild(_ id: String?) async {
        selectedDiscordGuildID = id
        selectedDiscordChannelID = nil
        discordChannels = []
        guard let id, discordConnected else { return }
        do {
            discordChannels = try await discordBotClient.listChannels(guildId: id)
            selectedDiscordChannelID = discordChannels.first?.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissDiscordRecovery() {
        discordRecoveryRequest = nil
    }

    func recoverDiscordSession(_ request: DiscordRecoveryRequest) async {
        discordRecoveryRequest = nil
        let folder = request.folder
        let manifestURL = folder.appendingPathComponent(".discord/manifest.json")
        let audioURL = folder.appendingPathComponent("audio.wav")
        phase = .finalizing
        statusDetail = "Recuperando uma gravação do Discord…"
        do {
            let result: DiscordCaptureResult
            if FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(".discord/session.json").path
            ) {
                result = try await discordBotClient.recover(folder: folder)
            } else {
                let manifest = try DiscordManifest.load(from: folder)
                result = DiscordCaptureResult(
                    guildId: manifest.guildId,
                    guildName: manifest.guildName,
                    channelId: manifest.channelId,
                    channelName: manifest.channelName,
                    startedAt: manifest.startedAt,
                    durationSeconds: manifest.durationSeconds,
                    participants: manifest.participants,
                    folderPath: folder.path,
                    audioPath: audioURL.path,
                    manifestPath: manifestURL.path
                )
            }
            await finishDiscordCapture(result)
            detectDiscordRecoverySession()
        } catch {
            phase = .idle
            warningMessage = "Não foi possível recuperar \(folder.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func transcribe(_ record: inout MeetingRecord) async {
        phase = .transcribing
        progress = 0.02
        statusDetail = "Preparando o Whisper local…"
        var shouldGenerateSummary = false
        do {
            let reportProgress: @Sendable (Double, String) -> Void = { [weak self] value, detail in
                Task { @MainActor in
                    self?.progress = value
                    self?.statusDetail = detail
                }
            }
            let transcriptURL: URL
            if let manifest = try? DiscordManifest.load(from: record.folderURL) {
                transcriptURL = try await transcriptionService.transcribeDiscord(
                    manifest: manifest,
                    folder: record.folderURL,
                    audioURL: record.audioURL,
                    language: settings.language,
                    createdAt: record.createdAt,
                    progress: reportProgress
                )
            } else {
                transcriptURL = try await transcriptionService.transcribe(
                    audioURL: record.audioURL,
                    language: settings.language,
                    createdAt: record.createdAt,
                    progress: reportProgress
                )
            }
            record.transcriptPath = transcriptURL.path
            record.status = .ready
            record.errorMessage = nil
            meetingStore.upsert(record)
            progress = 1
            statusDetail = "WAV e transcrição salvos."
            await notificationService.notifyTranscriptionFinished(for: record, succeeded: true)
            shouldGenerateSummary = settings.automaticallyGenerateSummary && record.summaryPath == nil
        } catch {
            record.status = .failed
            record.errorMessage = error.localizedDescription
            meetingStore.upsert(record)
            warningMessage = "O WAV foi salvo, mas a transcrição falhou: \(error.localizedDescription)"
            statusDetail = "Áudio preservado. Você pode refazer a transcrição."
            await notificationService.notifyTranscriptionFinished(for: record, succeeded: false)
        }
        phase = .idle
        if shouldGenerateSummary {
            await generateSummary(for: record, overwrite: false)
        }
    }

    private func generateSummary(for record: MeetingRecord, overwrite: Bool) async {
        guard phase == .idle, let transcriptURL = record.transcriptURL else { return }
        phase = .summarizing
        summarizingRecordID = record.id
        progress = 0.02
        statusDetail = "Preparando o resumo local…"
        defer {
            summarizingRecordID = nil
            phase = .idle
        }

        do {
            let reportProgress: @Sendable (Double, String) -> Void = { [weak self] value, detail in
                Task { @MainActor in
                    self?.progress = value
                    self?.statusDetail = detail
                }
            }
            let url = try await summaryService.generate(
                transcriptURL: transcriptURL,
                folderURL: record.folderURL,
                overwrite: overwrite,
                customPrompt: settings.activeCustomSummaryPrompt,
                progress: reportProgress
            )
            var updated = meetingStore.records.first(where: { $0.id == record.id }) ?? record
            updated.summaryPath = url.path
            meetingStore.upsert(updated)
            summaryRevision += 1
            progress = 1
            statusDetail = "Resumo salvo em resumo.md."
        } catch {
            warningMessage = "A transcrição foi preservada, mas o resumo não pôde ser gerado: \(error.localizedDescription)"
            statusDetail = "Transcrição preservada. Você pode tentar gerar o resumo novamente."
        }
    }

    private func summaryURL(for record: MeetingRecord) -> URL {
        record.summaryURL ?? record.folderURL.appendingPathComponent("resumo.md")
    }

    private func restoreSummaryPaths() {
        for record in records where record.summaryPath == nil {
            let url = summaryURL(for: record)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var updated = record
            updated.summaryPath = url.path
            meetingStore.upsert(updated)
        }
    }

    private func uniqueMeetingFolder(for date: Date, imported: Bool) -> URL {
        let baseName = MeetingNaming.folderName(for: date, imported: imported)
        var candidate = settings.outputFolderURL.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = settings.outputFolderURL
                .appendingPathComponent("\(baseName)_\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private func uniqueDiscordFolder(for date: Date) -> URL {
        let baseName = MeetingNaming.discordFolderName(for: date)
        var candidate = settings.outputFolderURL.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = settings.outputFolderURL
                .appendingPathComponent("\(baseName)_\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private func clearActiveRecording() {
        activeFolder = nil
        activeCreatedAt = nil
        activeMicrophoneName = nil
        activeDiscordRecording = false
        discordParticipants = []
        recordingTimeline.reset()
        systemAudioLevel = 0
        microphoneAudioLevel = 0
        discordAudioLevel = 0
    }

    private func removeFromHistory(_ record: MeetingRecord) {
        let recordsBeforeRemoval = meetingStore.records
        let removedIndex = recordsBeforeRemoval.firstIndex(where: { $0.id == record.id }) ?? 0
        meetingStore.remove(record)
        meetingManagementRequest = nil

        guard selectedRecordID == record.id else { return }
        let remaining = meetingStore.records
        if remaining.isEmpty {
            selectedRecordID = nil
        } else {
            selectedRecordID = remaining[min(removedIndex, remaining.count - 1)].id
        }
    }

    private func fail(_ error: Error) {
        RecordingPanelController.shared.hide()
        phase = .idle
        progress = 0
        statusDetail = "Não foi possível concluir a operação."
        errorMessage = error.localizedDescription
    }

    private func beginDiscordRecording(request: DiscordStartRequest? = nil) async {
        guard phase == .idle else {
            if let request {
                await discordBotClient.rejectStart(
                    requestId: request.requestId,
                    message: "O PontoGrava está ocupado no Mac. Aguarde a operação atual terminar."
                )
            }
            return
        }
        guard discordConnected,
              let guildID = request?.guildId ?? selectedDiscordGuildID,
              let channelID = request?.channelId ?? selectedDiscordChannelID else {
            if let request {
                await discordBotClient.rejectStart(
                    requestId: request.requestId,
                    message: "O bot não está conectado ao PontoGrava no Mac."
                )
            }
            return
        }
        if request != nil {
            recordingMode = .discord
            selectedDiscordGuildID = guildID
            selectedDiscordChannelID = channelID
        }
        playbackController.pause()
        phase = .preparing
        progress = 0
        discordAudioLevel = 0
        statusDetail = "Conectando o bot ao canal…"
        if request != nil {
            discordGuilds = (try? await discordBotClient.listGuilds()) ?? discordGuilds
            discordChannels = (try? await discordBotClient.listChannels(guildId: guildID)) ?? []
            selectedDiscordGuildID = guildID
            selectedDiscordChannelID = channelID
        }
        let createdAt = Date()
        let folder = uniqueDiscordFolder(for: createdAt)
        do {
            try settings.ensureOutputFolder()
            try await discordBotClient.start(
                guildId: guildID,
                channelId: channelID,
                folder: folder,
                requestId: request?.requestId
            )
            activeFolder = folder
            activeCreatedAt = createdAt
            activeDiscordRecording = true
            discordParticipants = []
            recordingTimeline.start(at: createdAt)
            phase = .recording
            statusDetail = "Gravando o canal do Discord."
        } catch {
            if let request {
                await discordBotClient.rejectStart(
                    requestId: request.requestId,
                    message: "Não foi possível iniciar a gravação. Verifique o PontoGrava no Mac."
                )
            }
            try? FileManager.default.removeItem(at: folder)
            discordAudioLevel = 0
            fail(error)
        }
    }

    private func stopDiscordRecording() async {
        guard isRecordingSession, activeDiscordRecording else { return }
        phase = .finalizing
        statusDetail = "Finalizando e combinando as faixas do Discord…"
        do {
            let result = try await discordBotClient.stop()
            await finishDiscordCapture(result)
        } catch {
            clearActiveRecording()
            fail(error)
        }
    }

    private func finishDiscordCapture(_ result: DiscordCaptureResult) async {
        let createdAt = result.startedAt
        var record = MeetingRecord(
            id: UUID(),
            createdAt: createdAt,
            title: MeetingNaming.discordTitle(channelName: result.channelName, date: createdAt),
            folderPath: result.folderPath,
            audioPath: result.audioPath,
            transcriptPath: nil,
            duration: result.durationSeconds,
            status: .transcribing,
            errorMessage: nil,
            microphoneName: "Discord · \(result.guildName) / #\(result.channelName)"
        )
        meetingStore.upsert(record)
        selectedRecordID = record.id
        clearActiveRecording()
        await transcribe(&record)
    }

    private func handleDiscordEvent(_ event: DiscordBotEvent) {
        switch event {
        case let .startRequested(request):
            Task { await beginDiscordRecording(request: request) }
        case let .participant(name):
            if !discordParticipants.contains(name) {
                discordParticipants.append(name)
                discordParticipants.sort()
            }
        case let .audioLevel(level):
            if activeDiscordRecording || phase == .preparing {
                discordAudioLevel = max(0, min(1, level))
            }
        case let .stopped(result):
            guard activeDiscordRecording else { return }
            phase = .finalizing
            statusDetail = "Finalizando a gravação automática do Discord…"
            Task { await finishDiscordCapture(result) }
        case let .failed(message):
            guard activeDiscordRecording else { return }
            clearActiveRecording()
            fail(DiscordIntegrationError.helper(message))
        case let .helperStopped(detail):
            discordConnected = false
            discordAudioLevel = 0
            discordConnectionDetail = "O helper do Discord foi encerrado."
            if activeDiscordRecording {
                clearActiveRecording()
                fail(detail.map(DiscordIntegrationError.helper) ?? DiscordIntegrationError.helperStopped)
            }
        }
    }

    private func detectDiscordRecoverySession() {
        guard discordRecoveryRequest == nil else { return }
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: settings.outputFolderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        discordRecoveryRequest = folders.first { folder in
            let sessionURL = folder.appendingPathComponent(".discord/session.json")
            let manifestURL = folder.appendingPathComponent(".discord/manifest.json")
            let audioURL = folder.appendingPathComponent("audio.wav")
            let alreadyIndexed = records.contains { $0.audioPath == audioURL.path }
            guard !alreadyIndexed else { return false }
            let hasSession = FileManager.default.fileExists(atPath: sessionURL.path)
            let hasCompletedCapture = FileManager.default.fileExists(atPath: manifestURL.path)
                && FileManager.default.fileExists(atPath: audioURL.path)
            return hasSession || hasCompletedCapture
        }.map(DiscordRecoveryRequest.init(folder:))
    }
}
