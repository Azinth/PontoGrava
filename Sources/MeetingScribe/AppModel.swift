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
    @Published private(set) var recordingTimeline = RecordingTimeline()
    @Published private(set) var systemAudioLevel: Float = 0
    @Published private(set) var microphoneAudioLevel: Float = 0

    private let recordingEngine = RecordingEngine()
    private let transcriptionService = TranscriptionService()
    private let meetingFileService: MeetingFileService
    private var activeFolder: URL?
    private var activeCreatedAt: Date?
    private var activeMicrophoneName: String?

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
        self.meetingStore = meetingStore ?? MeetingStore()
        self.deviceManager = deviceManager ?? AudioDeviceManager()
        self.playbackController = playbackController ?? AudioPlaybackController()
        self.notificationService = notificationService ?? NotificationService()
        self.meetingFileService = meetingFileService ?? MeetingFileService()
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
    }

    var records: [MeetingRecord] { meetingStore.records }
    var isBusy: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording }
    var isPaused: Bool { phase == .paused }
    var isRecordingSession: Bool { isRecording || isPaused }
    var recordingStartedAt: Date? { recordingTimeline.startedAt }

    var selectedRecord: MeetingRecord? {
        guard let selectedRecordID else { return nil }
        return records.first { $0.id == selectedRecordID }
    }

    var selectedMicrophoneName: String {
        guard let selectedMicrophoneID else { return "Nenhum microfone" }
        return deviceManager.name(for: selectedMicrophoneID) ?? "Microfone indisponível"
    }

    func initialize() async {
        do {
            try settings.ensureOutputFolder()
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshMicrophones()
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
        guard phase == .recording else { return }
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
        guard phase == .paused else { return }
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
        guard isRecordingSession else { return }
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

    private func transcribe(_ record: inout MeetingRecord) async {
        phase = .transcribing
        progress = 0.02
        statusDetail = "Preparando o Whisper local…"
        do {
            let transcriptURL = try await transcriptionService.transcribe(
                audioURL: record.audioURL,
                language: settings.language,
                createdAt: record.createdAt
            ) { [weak self] value, detail in
                Task { @MainActor in
                    self?.progress = value
                    self?.statusDetail = detail
                }
            }
            record.transcriptPath = transcriptURL.path
            record.status = .ready
            record.errorMessage = nil
            meetingStore.upsert(record)
            progress = 1
            statusDetail = "WAV e transcrição salvos."
            await notificationService.notifyTranscriptionFinished(for: record, succeeded: true)
        } catch {
            record.status = .failed
            record.errorMessage = error.localizedDescription
            meetingStore.upsert(record)
            warningMessage = "O WAV foi salvo, mas a transcrição falhou: \(error.localizedDescription)"
            statusDetail = "Áudio preservado. Você pode refazer a transcrição."
            await notificationService.notifyTranscriptionFinished(for: record, succeeded: false)
        }
        phase = .idle
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

    private func clearActiveRecording() {
        activeFolder = nil
        activeCreatedAt = nil
        activeMicrophoneName = nil
        recordingTimeline.reset()
        systemAudioLevel = 0
        microphoneAudioLevel = 0
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
}
