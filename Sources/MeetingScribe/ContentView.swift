import AppKit
import SwiftUI

private let brandAccent = Color(red: 0.79, green: 0.35, blue: 0.21)

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            AppSidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
        } detail: {
            MainWorkspace()
        }
        .navigationSplitViewStyle(.balanced)
        .tint(brandAccent)
        .frame(minWidth: 760, minHeight: 560)
        .sheet(item: renameRequest) { record in
            RenameMeetingView(record: record)
                .environmentObject(model)
        }
        .alert(
            "Mover reunião para a Lixeira?",
            isPresented: deleteRequestPresented,
            presenting: deleteRecord
        ) { record in
            Button("Cancelar", role: .cancel) { model.meetingManagementRequest = nil }
            Button("Mover para a Lixeira", role: .destructive) {
                Task { await model.deleteMeeting(record) }
            }
        } message: { _ in
            Text("A pasta completa, incluindo o WAV e a transcrição, poderá ser recuperada pela Lixeira.")
        }
        .alert(
            "Pasta não encontrada",
            isPresented: orphanRequestPresented,
            presenting: orphanRecord
        ) { record in
            Button("Cancelar", role: .cancel) { model.meetingManagementRequest = nil }
            Button("Remover do histórico", role: .destructive) {
                model.removeOrphanedMeeting(record)
            }
        } message: { _ in
            Text("Os arquivos já não estão no local registrado. Você pode remover apenas esta entrada do histórico.")
        }
    }

    private var renameRequest: Binding<MeetingRecord?> {
        Binding(
            get: {
                guard case let .rename(record) = model.meetingManagementRequest else { return nil }
                return record
            },
            set: { if $0 == nil { model.meetingManagementRequest = nil } }
        )
    }

    private var deleteRequestPresented: Binding<Bool> {
        Binding(
            get: {
                if case .delete = model.meetingManagementRequest { return true }
                return false
            },
            set: { if !$0 { model.meetingManagementRequest = nil } }
        )
    }

    private var deleteRecord: MeetingRecord? {
        guard case let .delete(record) = model.meetingManagementRequest else { return nil }
        return record
    }

    private var orphanRequestPresented: Binding<Bool> {
        Binding(
            get: {
                if case .removeOrphan = model.meetingManagementRequest { return true }
                return false
            },
            set: { if !$0 { model.meetingManagementRequest = nil } }
        )
    }

    private var orphanRecord: MeetingRecord? {
        guard case let .removeOrphan(record) = model.meetingManagementRequest else { return nil }
        return record
    }
}

private struct AppSidebar: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""

    private var filteredRecords: [MeetingRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.records }
        return model.records.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.microphoneName.localizedCaseInsensitiveContains(query)
                || $0.status.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PontoGrava")
                        .font(.system(.title, design: .serif, weight: .semibold))
                    Text("Gravação local com transcrição editável")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                AppStatusPill()
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            Text("REUNIÕES")
                .font(.caption2.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)

            List(filteredRecords, selection: $model.selectedRecordID) { record in
                MeetingRow(record: record)
                    .tag(record.id)
                    .contextMenu {
                        Button("Renomear…") { model.presentRename(record) }
                            .disabled(model.isBusy)
                        Button("Mostrar no Finder") { model.reveal(record) }
                        Divider()
                        Button("Mover para a Lixeira", role: .destructive) {
                            model.presentDelete(record)
                        }
                        .disabled(model.isBusy)
                    }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Buscar reuniões")
            .overlay {
                if model.records.isEmpty {
                    ContentUnavailableView(
                        "Sem reuniões",
                        systemImage: "waveform",
                        description: Text("Suas gravações aparecerão aqui.")
                    )
                } else if filteredRecords.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }

            Divider()
            SidebarSettings()
        }
        .background(.regularMaterial)
    }
}

private struct AppStatusPill: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Label(model.phase.title, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityLabel("Status: \(model.phase.title)")
    }

    private var icon: String {
        switch model.phase {
        case .idle: "checkmark.circle.fill"
        case .preparing, .finalizing, .transcribing: "hourglass"
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        }
    }

    private var color: Color {
        switch model.phase {
        case .idle: .green
        case .preparing, .finalizing, .transcribing: .blue
        case .recording: .red
        case .paused: .orange
        }
    }
}

private struct MeetingRow: View {
    let record: MeetingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(record.title)
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 5) {
                Text(formattedDuration(record.duration))
                Text("•")
                Label(record.status.title, systemImage: meetingStatusIcon(record.status))
                    .labelStyle(.titleOnly)
            }
            .font(.caption)
            .foregroundStyle(record.status == .failed ? Color.orange : Color.secondary)

            Text(record.microphoneName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

private struct SidebarSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                model.openOutputFolder()
            } label: {
                Label(model.settings.outputFolderURL.lastPathComponent, systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .help(model.settings.outputFolderURL.path)

            HStack {
                Text("Idioma")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Idioma", selection: Binding(
                    get: { model.settings.language },
                    set: { model.settings.language = $0 }
                )) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .disabled(model.isBusy)
            }

            HStack(spacing: 8) {
                SidebarNotificationControl()
                Spacer()
                Button {
                    model.chooseOutputFolder()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Alterar pasta de destino")
                .disabled(model.isBusy)
            }
        }
        .padding(14)
    }
}

private struct SidebarNotificationControl: View {
    @EnvironmentObject private var model: AppModel

    @ViewBuilder
    var body: some View {
        switch model.notificationPermissionState {
        case .authorized:
            Label("Notificações ativas", systemImage: "bell.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .denied:
            Button("Ajustar notificações") { model.openNotificationSettings() }
                .font(.caption)
                .buttonStyle(.link)
        case .notDetermined, .unknown:
            Button("Ativar notificações") {
                Task { await model.requestNotificationPermission() }
            }
            .font(.caption)
            .buttonStyle(.link)
        }
    }
}

private struct MainWorkspace: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 840

            VStack(spacing: 0) {
                WorkspaceToolbar(compact: compact)
                Divider()

                if compact {
                    VStack(spacing: 0) {
                        RecorderPanel(compact: true)
                            .padding(12)
                        Divider()
                        MeetingDetailView(
                            store: model.meetingStore,
                            selectedRecordID: model.selectedRecordID,
                            compact: true
                        )
                    }
                } else {
                    HSplitView {
                        ScrollView {
                            RecorderPanel(compact: false)
                                .padding(20)
                        }
                        .frame(minWidth: 330, idealWidth: 390, maxWidth: 480)

                        MeetingDetailView(
                            store: model.meetingStore,
                            selectedRecordID: model.selectedRecordID,
                            compact: false
                        )
                        .frame(minWidth: 500)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct WorkspaceToolbar: View {
    @EnvironmentObject private var model: AppModel
    let compact: Bool

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 12) {
                    Text("Captura e transcrição")
                        .font(.system(.title2, design: .serif, weight: .semibold))
                    Spacer()
                    Button {
                        model.presentImportPanel()
                    } label: {
                        Label("Importar", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                }
            } else {
                HStack(spacing: 16) {
                    toolbarTitle
                    Spacer()
                    toolbarActions
                }
            }
        }
        .padding(.horizontal, compact ? 16 : 22)
        .padding(.vertical, compact ? 10 : 16)
    }

    private var toolbarTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Captura e transcrição")
                .font(.system(.title, design: .serif, weight: .semibold))
            Text(toolbarSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var toolbarActions: some View {
        HStack(spacing: 10) {
            Button {
                model.presentImportPanel()
            } label: {
                Label("Importar áudio", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(model.isBusy)

            if model.isRecordingSession {
                Button(role: .destructive) {
                    Task { await model.stopRecording() }
                } label: {
                    Label("Parar e transcrever", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            } else {
                Button {
                    Task { await model.beginRecording() }
                } label: {
                    Label(
                        model.recordingMode == .discord ? "Gravar canal" : "Iniciar gravação",
                        systemImage: "record.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(brandAccent)
                .controlSize(.large)
                .disabled(!model.canBeginRecording)
            }
        }
    }

    private var toolbarSubtitle: String {
        if model.isRecordingSession { return model.statusDetail }
        if model.recordingMode == .discord { return model.discordConnectionDetail }
        return "Sistema + \(model.selectedMicrophoneName)"
    }
}

private struct RecorderPanel: View {
    @EnvironmentObject private var model: AppModel
    let compact: Bool

    private var combinedLevel: Float {
        model.isDiscordRecording
            ? model.discordAudioLevel
            : max(model.systemAudioLevel, model.microphoneAudioLevel)
    }

    var body: some View {
        if compact {
            compactPanel
        } else {
            regularPanel
        }
    }

    private var compactPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            compactRecorderHeader

            if model.isRecordingSession {
                MainLiveWaveformView(level: combinedLevel, phase: model.phase)
                    .frame(height: 46)
                    .padding(.horizontal, 8)
                    .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))

                if model.isDiscordRecording {
                    Label(
                        model.discordParticipants.isEmpty
                            ? "Aguardando participantes…"
                            : model.discordParticipants.joined(separator: ", "),
                        systemImage: "person.2.wave.2"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                } else {
                    HStack(spacing: 12) {
                        CompactSourceLevelView(title: "Sistema", level: model.systemAudioLevel)
                        CompactSourceLevelView(title: "Microfone", level: model.microphoneAudioLevel)
                    }
                }
                recordingControls
            } else if model.phase == .idle {
                HStack(alignment: .center, spacing: 12) {
                    if model.recordingMode == .discord {
                        DiscordSetupView(compact: true)
                    } else {
                        compactMicrophonePicker
                    }

                    recordingControls
                        .frame(minWidth: 160, maxWidth: 190)
                }
            }

            if model.phase == .preparing || model.phase == .finalizing || model.phase == .transcribing {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: model.phase == .transcribing ? model.progress : nil)
                    Text(model.statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.showNotificationInvitation {
                NotificationInvitationView()
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var compactRecorderHeader: some View {
        HStack(spacing: 10) {
            Text(model.phase.title)
                .font(.system(.title2, design: .serif, weight: .semibold))

            Text(model.statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if model.phase == .idle {
                HStack(spacing: 6) {
                    Text("Origem")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    Picker("Origem", selection: $model.recordingMode) {
                        ForEach(RecordingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                    .disabled(model.isBusy)
                }
                .fixedSize()
            }

            if model.isRecordingSession {
                RecordingClock(timeline: model.recordingTimeline, isPaused: model.isPaused)
            } else {
                Text("00:00")
                    .font(.title3.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var compactMicrophonePicker: some View {
        HStack(spacing: 8) {
            Picker("Microfone", selection: $model.selectedMicrophoneID) {
                ForEach(model.deviceManager.devices) { device in
                    Text(device.name + (device.isDefault ? " — padrão atual" : ""))
                        .tag(Optional(device.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .disabled(model.isBusy)

            Button {
                model.refreshMicrophones()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Atualizar microfones")
            .disabled(model.isBusy)
        }
        .accessibilityElement(children: .contain)
    }

    private var regularPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            recorderHeader

            Picker("Origem", selection: $model.recordingMode) {
                ForEach(RecordingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isBusy)

            if !model.isRecordingSession {
                if model.recordingMode == .discord {
                    DiscordSetupView(compact: false)
                } else {
                    MicrophonePicker(
                        manager: model.deviceManager,
                        selection: $model.selectedMicrophoneID,
                        disabled: model.isBusy
                    )
                }
            }

            if model.isRecordingSession {
                MainLiveWaveformView(level: combinedLevel, phase: model.phase)
                    .frame(height: 138)
                    .padding(.horizontal, 10)
                    .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))

                if model.isDiscordRecording {
                    Label(
                        model.discordParticipants.isEmpty
                            ? "Aguardando participantes falarem…"
                            : model.discordParticipants.joined(separator: ", "),
                        systemImage: "person.2.wave.2"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                } else {
                    HStack(spacing: 12) {
                        MainSourceLevelView(title: "Sistema", level: model.systemAudioLevel)
                        MainSourceLevelView(title: "Microfone", level: model.microphoneAudioLevel)
                    }
                }
            }

            recordingControls

            if model.phase == .preparing || model.phase == .finalizing || model.phase == .transcribing {
                VStack(alignment: .leading, spacing: 7) {
                    ProgressView(value: model.phase == .transcribing ? model.progress : nil)
                    Text(model.statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.showNotificationInvitation {
                NotificationInvitationView()
            }

        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var recorderHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.phase.title)
                    .font(.system(.title2, design: .serif, weight: .semibold))
                Text(model.statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if model.isRecordingSession {
                RecordingClock(timeline: model.recordingTimeline, isPaused: model.isPaused)
            } else {
                Text("00:00")
                    .font(.title2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var recordingControls: some View {
        HStack(spacing: 10) {
            if model.isRecordingSession {
                if model.canPauseRecording {
                    Button {
                        model.isPaused ? model.resumeRecording() : model.pauseRecording()
                    } label: {
                        Label(
                            model.isPaused ? "Continuar" : "Pausar",
                            systemImage: model.isPaused ? "play.fill" : "pause.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(model.isPaused ? .orange : .primary)
                }

                Button(role: .destructive) {
                    Task { await model.stopRecording() }
                } label: {
                    Label("Parar e transcrever", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            } else if model.phase == .idle {
                Button {
                    Task { await model.beginRecording() }
                } label: {
                    Label(
                        model.recordingMode == .discord ? "Gravar canal do Discord" : "Iniciar gravação",
                        systemImage: "record.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(brandAccent)
                .controlSize(.large)
                .disabled(!model.canBeginRecording)
            }
        }
    }
}

private struct DiscordSetupView: View {
    @EnvironmentObject private var model: AppModel
    let compact: Bool

    var body: some View {
        if compact {
            compactSetup
        } else {
            regularSetup
        }
    }

    @ViewBuilder
    private var compactSetup: some View {
        if !model.discordHasToken {
            HStack(spacing: 8) {
                SecureField("Token do bot", text: $model.discordTokenDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Conectar") {
                    Task { await model.saveDiscordTokenAndConnect() }
                }
                .disabled(model.discordTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Link(destination: URL(string: "https://discord.com/developers/applications")!) {
                    Image(systemName: "questionmark.circle")
                }
                .help("Criar bot no Discord")
                .accessibilityLabel("Criar bot no Discord")
            }
        } else {
            HStack(spacing: 8) {
                Label(
                    model.discordConnectionDetail,
                    systemImage: model.discordConnected ? "checkmark.circle.fill" : "bolt.horizontal.circle"
                )
                .labelStyle(.iconOnly)
                .foregroundStyle(model.discordConnected ? Color.green : Color.secondary)
                .help(model.discordConnectionDetail)

                if model.discordConnected {
                    discordGuildPicker
                        .labelsHidden()
                    discordChannelPicker
                        .labelsHidden()
                }

                Menu {
                    Button("Reconectar") { Task { await model.connectDiscord() } }
                    if let inviteURL = model.discordInviteURL {
                        Link("Convidar o bot para outro servidor", destination: inviteURL)
                    }
                    Divider()
                    Button("Remover token", role: .destructive) { model.removeDiscordToken() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("Opções do Discord")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var regularSetup: some View {
        VStack(alignment: .leading, spacing: 11) {
            if !model.discordHasToken {
                SecureField("Token do bot", text: $model.discordTokenDraft)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Salvar e conectar") {
                        Task { await model.saveDiscordTokenAndConnect() }
                    }
                    .disabled(model.discordTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Link("Criar bot no Discord", destination: URL(string: "https://discord.com/developers/applications")!)
                }
            } else {
                HStack(spacing: 8) {
                    Label(
                        model.discordConnectionDetail,
                        systemImage: model.discordConnected ? "checkmark.circle.fill" : "bolt.horizontal.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(model.discordConnected ? Color.green : Color.secondary)
                    .lineLimit(2)
                    Spacer()
                    Menu {
                        Button("Reconectar") { Task { await model.connectDiscord() } }
                        Button("Remover token", role: .destructive) { model.removeDiscordToken() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                }

                if let inviteURL = model.discordInviteURL {
                    Link("Convidar o bot para outro servidor", destination: inviteURL)
                        .font(.caption)
                }
            }

            if model.discordConnected {
                VStack(spacing: 11) {
                    discordGuildPicker
                    discordChannelPicker
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var discordGuildPicker: some View {
        Picker("Servidor", selection: Binding(
            get: { model.selectedDiscordGuildID },
            set: { id in Task { await model.selectDiscordGuild(id) } }
        )) {
            Text("Selecione o servidor").tag(Optional<String>.none)
            ForEach(model.discordGuilds) { guild in
                Text(guild.name).tag(Optional(guild.id))
            }
        }
        .accessibilityLabel("Servidor do Discord")
    }

    private var discordChannelPicker: some View {
        Picker("Canal", selection: $model.selectedDiscordChannelID) {
            Text("Selecione o canal").tag(Optional<String>.none)
            ForEach(model.discordChannels) { channel in
                Text("#\(channel.name)").tag(Optional(channel.id))
            }
        }
        .accessibilityLabel("Canal do Discord")
    }
}

private struct MicrophonePicker: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var manager: AudioDeviceManager
    @Binding var selection: String?
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Microfone desta reunião")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Picker("Microfone", selection: $selection) {
                    ForEach(manager.devices) { device in
                        Text(device.name + (device.isDefault ? " — padrão atual" : ""))
                            .tag(Optional(device.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(disabled)

                Button {
                    model.refreshMicrophones()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Atualizar microfones")
                .disabled(disabled)
            }
        }
    }
}

private struct MainLiveWaveformView: View {
    let level: Float
    let phase: AppPhase

    private let pattern: [CGFloat] = [
        0.34, 0.58, 0.42, 0.76, 0.52, 0.95, 0.68, 0.38, 0.84,
        0.48, 1, 0.62, 0.36, 0.74, 0.44, 0.88, 0.56, 0.7, 0.4
    ]

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 6) {
                ForEach(pattern.indices, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(
                            width: max(4, (geometry.size.width - 120) / CGFloat(pattern.count)),
                            height: max(12, geometry.size.height * pattern[index] * activeLevel)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.12), value: level)
        }
        .accessibilityLabel(phase == .paused ? "Gravação pausada" : "Nível de áudio da gravação")
    }

    private var activeLevel: CGFloat {
        switch phase {
        case .recording: max(0.1, CGFloat(level))
        case .paused: 0.18
        case .preparing, .finalizing, .transcribing: 0.22
        case .idle: 0.3
        }
    }

    private var color: Color {
        switch phase {
        case .recording: .red
        case .paused: .orange
        case .preparing, .finalizing, .transcribing: .blue
        case .idle: .secondary.opacity(0.28)
        }
    }
}

private struct MainSourceLevelView: View {
    let title: String
    let level: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(level > 0.78 ? Color.orange : brandAccent)
                        .frame(width: geometry.size.width * CGFloat(level))
                }
            }
            .frame(height: 7)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct CompactSourceLevelView: View {
    let title: String
    let level: Float

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: Double(level), total: 1)
                .tint(level > 0.78 ? .orange : brandAccent)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Nível de \(title)")
        .accessibilityValue("\(Int(level * 100)) por cento")
    }
}

private struct NotificationInvitationView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Avise quando a transcrição terminar", systemImage: "bell.badge")
                .font(.headline)
                .foregroundStyle(.blue)
            Text("O PontoGrava pode notificar você mesmo quando a janela estiver fechada.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Agora não") { model.dismissNotificationInvitation() }
                Button("Ativar") {
                    Task { await model.requestNotificationPermission() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct RecordingClock: View {
    let timeline: RecordingTimeline
    let isPaused: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 7) {
                Image(systemName: isPaused ? "pause.circle.fill" : "record.circle.fill")
                Text(formattedDuration(timeline.elapsed(at: context.date)))
                    .monospacedDigit()
            }
            .font(.title2.weight(.semibold))
            .foregroundStyle(isPaused ? .orange : .red)
            .accessibilityLabel(
                "\(isPaused ? "Gravação pausada" : "Gravando"), \(formattedDuration(timeline.elapsed(at: context.date)))"
            )
        }
    }
}

private struct MeetingDetailView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: MeetingStore
    let selectedRecordID: UUID?
    let compact: Bool

    private var record: MeetingRecord? {
        store.records.first { $0.id == selectedRecordID }
    }

    var body: some View {
        Group {
            if let record {
                VStack(spacing: 0) {
                    meetingHeader(record)
                    Divider()
                    AudioPlayerView(controller: model.playbackController, compact: compact)
                        .padding(.horizontal, compact ? 16 : 22)
                        .padding(.vertical, 14)
                    Divider()
                    TranscriptPreviewView(record: record)
                        .id(record.id)
                        .padding(compact ? 16 : 22)
                }
            } else {
                ContentUnavailableView(
                    "Selecione uma reunião",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Escolha uma gravação no histórico para ouvir e editar a transcrição.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }

    private func meetingHeader(_ record: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if compact {
                HStack(alignment: .top, spacing: 10) {
                    meetingTitle(record)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        MeetingStatusBadge(status: record.status)
                        meetingActions(record)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    meetingTitle(record)
                    Spacer()
                    MeetingStatusBadge(status: record.status)
                }
            }

            if let error = record.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            }

            if !compact {
                HStack(spacing: 10) {
                    Button {
                        model.reveal(record)
                    } label: {
                        Label("Mostrar no Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await model.retranscribe(record) }
                    } label: {
                        Label("Refazer transcrição", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)

                    Spacer()
                    meetingActions(record)
                }
            }
        }
        .padding(compact ? 12 : 22)
    }

    private func meetingTitle(_ record: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(record.title)
                .font(.system(.title2, design: .serif, weight: .semibold))
                .textSelection(.enabled)
            Text("\(record.microphoneName) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func meetingActions(_ record: MeetingRecord) -> some View {
        Menu {
            Button("Renomear…") { model.presentRename(record) }
                .disabled(model.isBusy)
            Button("Mostrar no Finder") { model.reveal(record) }
            Button("Refazer transcrição") {
                Task { await model.retranscribe(record) }
            }
            .disabled(model.isBusy)
            Divider()
            Button("Mover para a Lixeira", role: .destructive) {
                model.presentDelete(record)
            }
            .disabled(model.isBusy)
        } label: {
            Label("Mais ações", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct MeetingStatusBadge: View {
    let status: MeetingStatus

    var body: some View {
        Label(status.title, systemImage: meetingStatusIcon(status))
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch status {
        case .ready: .green
        case .transcribing: .blue
        case .failed: .orange
        }
    }
}

private struct TranscriptPreviewView: View {
    let record: MeetingRecord

    @State private var text = ""
    @State private var errorMessage: String?
    @State private var saveErrorMessage: String?
    @State private var copied = false

    var body: some View {
        Group {
            if record.transcriptURL == nil {
                ContentUnavailableView(
                    record.status == .transcribing ? "Transcrevendo" : "Sem transcrição",
                    systemImage: record.status == .transcribing ? "waveform.badge.magnifyingglass" : "doc.text.magnifyingglass",
                    description: record.status == .transcribing ? Text("A transcrição local aparecerá aqui quando estiver pronta.") : nil
                )
            } else if let errorMessage {
                ContentUnavailableView(
                    "Transcrição indisponível",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Label(
                            saveErrorMessage == nil ? "Salvo automaticamente em transcricao.txt" : "Não foi possível salvar",
                            systemImage: saveErrorMessage == nil ? "checkmark.circle" : "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(saveErrorMessage == nil ? Color.secondary : Color.orange)

                        Spacer()

                        Button {
                            copyTranscript()
                        } label: {
                            Label(copied ? "Copiado" : "Copiar texto", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .disabled(text.isEmpty)
                    }

                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(.quaternary, lineWidth: 1)
                        }
                        .accessibilityLabel("Transcrição editável")

                    if let saveErrorMessage {
                        Text(saveErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: load)
        .onChange(of: record.transcriptPath) { _, _ in load() }
        .onChange(of: record.status) { _, _ in load() }
        .onChange(of: text) { _, newValue in save(newValue) }
    }

    private func load() {
        guard let url = record.transcriptURL else {
            text = ""
            errorMessage = nil
            saveErrorMessage = nil
            return
        }
        do {
            text = try String(contentsOf: url, encoding: .utf8)
            errorMessage = nil
            saveErrorMessage = nil
        } catch {
            text = ""
            errorMessage = error.localizedDescription
        }
    }

    private func save(_ value: String) {
        guard let url = record.transcriptURL else { return }
        do {
            try value.write(to: url, atomically: true, encoding: .utf8)
            saveErrorMessage = nil
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}

private struct AudioPlayerView: View {
    @ObservedObject var controller: AudioPlaybackController
    let compact: Bool

    var body: some View {
        Group {
            if controller.isAvailable {
                if compact {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            playbackButton
                            currentTime
                            positionSlider
                            duration
                        }
                        HStack(spacing: 10) {
                            playbackRate
                            Spacer()
                            volume
                                .frame(maxWidth: 150)
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        playbackButton
                        currentTime
                        positionSlider
                        duration
                        playbackRate
                        volume
                            .frame(width: 100)
                    }
                }
            } else {
                Label("Áudio indisponível", systemImage: "waveform.slash")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    private var playbackButton: some View {
        Button {
            controller.togglePlayback()
        } label: {
            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderedProminent)
        .tint(brandAccent)
        .controlSize(.large)
        .help(controller.isPlaying ? "Pausar" : "Reproduzir")
    }

    private var currentTime: some View {
        Text(formattedDuration(controller.currentTime))
            .monospacedDigit()
            .font(.caption)
    }

    private var positionSlider: some View {
        Slider(
            value: Binding(
                get: { controller.currentTime },
                set: { controller.seek(to: $0) }
            ),
            in: 0...max(0.1, controller.duration)
        )
        .accessibilityLabel("Posição do áudio")
    }

    private var duration: some View {
        Text(formattedDuration(controller.duration))
            .monospacedDigit()
            .font(.caption)
    }

    private var playbackRate: some View {
        Picker("Velocidade", selection: Binding(
            get: { controller.playbackRate },
            set: { controller.playbackRate = $0 }
        )) {
            ForEach(AudioPlaybackController.playbackRates, id: \.self) { rate in
                Text(playbackRateLabel(rate)).tag(rate)
            }
        }
        .labelsHidden()
        .frame(width: 82)
        .help("Velocidade de reprodução")
    }

    private var volume: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { Double(controller.volume) },
                    set: { controller.volume = Float($0) }
                ),
                in: 0...1
            )
            .accessibilityLabel("Volume")
        }
    }
}

private struct RenameMeetingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let record: MeetingRecord
    @State private var name: String
    @State private var errorMessage: String?

    init(record: MeetingRecord) {
        self.record = record
        _name = State(initialValue: record.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Renomear reunião")
                .font(.system(.title2, design: .serif, weight: .semibold))
            Text("O título no histórico será mantido como você digitou. A pasta será ajustada para o Finder.")
                .foregroundStyle(.secondary)
            TextField("Nome da reunião", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(rename)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancelar") {
                    model.meetingManagementRequest = nil
                    dismiss()
                }
                Button("Renomear", action: rename)
                    .buttonStyle(.borderedProminent)
                    .tint(brandAccent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(26)
        .frame(width: 480)
    }

    private func rename() {
        do {
            try model.renameMeeting(record, to: name)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private func formattedDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    if seconds >= 3_600 {
        return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

private func playbackRateLabel(_ rate: Float) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "pt_BR")
    formatter.minimumFractionDigits = rate.rounded() == rate ? 0 : 1
    formatter.maximumFractionDigits = 2
    return "\(formatter.string(from: NSNumber(value: rate)) ?? "\(rate)")x"
}

private func meetingStatusIcon(_ status: MeetingStatus) -> String {
    switch status {
    case .ready: "checkmark.circle.fill"
    case .transcribing: "waveform.badge.magnifyingglass"
    case .failed: "exclamationmark.triangle.fill"
    }
}
