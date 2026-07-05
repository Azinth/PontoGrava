import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isSidebarOpen = false

    var body: some View {
        HStack(spacing: 0) {
            RecorderHomeView()
            Divider()
            if isSidebarOpen {
                SecondarySidebarView(isOpen: $isSidebarOpen)
                    .frame(width: 210)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                CollapsedSidebarRail(isOpen: $isSidebarOpen)
                    .frame(width: 42)
            }
        }
        .frame(
            width: isSidebarOpen ? 600 : 420,
            height: isSidebarOpen ? 360 : (model.isRecordingSession ? 270 : 210)
        )
        .animation(.easeInOut(duration: 0.18), value: isSidebarOpen)
        .animation(.easeInOut(duration: 0.18), value: model.isRecordingSession)
    }
}

struct HistoryWindowView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HistoryWorkspaceView(
            store: model.meetingStore,
            selection: $model.selectedRecordID
        )
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

private struct RecorderHomeView: View {
    @EnvironmentObject private var model: AppModel

    private var combinedLevel: Float {
        max(model.systemAudioLevel, model.microphoneAudioLevel)
    }

    var body: some View {
        Group {
            if model.isRecordingSession {
                recordingView
            } else {
                idleView
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var idleView: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            microphoneRow
            Button {
                Task { await model.beginRecording() }
            } label: {
                Label("Iniciar gravação", systemImage: "record.circle")
                    .font(.headline)
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(model.isBusy || model.selectedMicrophoneID == nil)

            if model.phase == .transcribing || model.phase == .finalizing || model.phase == .preparing {
                VStack(spacing: 6) {
                    ProgressView(value: model.phase == .transcribing ? model.progress : nil)
                    Text(model.statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var recordingView: some View {
        VStack(spacing: 12) {
            HStack {
                Circle()
                    .fill(model.isPaused ? .orange : .red)
                    .frame(width: 8, height: 8)
                Text(model.selectedMicrophoneName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                RecordingClock(
                    timeline: model.recordingTimeline,
                    isPaused: model.isPaused
                )
            }

            MainLiveWaveformView(
                level: combinedLevel,
                phase: model.phase
            )
            .frame(height: 58)

            HStack(spacing: 12) {
                MainSourceLevelView(title: "Sistema", level: model.systemAudioLevel)
                MainSourceLevelView(title: "Microfone", level: model.microphoneAudioLevel)
            }

            HStack(spacing: 16) {
                Button {
                    if model.isPaused {
                        model.resumeRecording()
                    } else {
                        model.pauseRecording()
                    }
                } label: {
                    Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                        .font(.title2.weight(.semibold))
                        .frame(width: 56, height: 42)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isPaused ? .orange : .gray)
                .help(model.isPaused ? "Continuar" : "Pausar")

                Button(role: .destructive) {
                    Task { await model.stopRecording() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title2.weight(.semibold))
                        .frame(width: 56, height: 42)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("Parar e transcrever")
            }
        }
    }

    private var microphoneRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            MicrophonePicker(
                manager: model.deviceManager,
                selection: $model.selectedMicrophoneID,
                disabled: model.isBusy
            )
            Button {
                model.refreshMicrophones()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 18, height: 18)
            }
            .help("Atualizar microfones")
            .disabled(model.isBusy)
        }
    }
}

private struct CollapsedSidebarRail: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Binding var isOpen: Bool

    var body: some View {
        VStack(spacing: 10) {
            Button {
                isOpen = true
            } label: {
                Image(systemName: "sidebar.right")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Abrir opções")

            Divider()
                .padding(.horizontal, 8)

            Button {
                openWindow(id: "history")
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Histórico")

            Button {
                model.presentImportPanel()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Importar áudio")
            .disabled(model.isBusy)

            Button {
                model.openOutputFolder()
            } label: {
                Image(systemName: "folder")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Abrir pasta")

            Button {
                model.chooseOutputFolder()
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Alterar pasta")
            .disabled(model.isBusy)

            if model.isRecordingSession {
                Button {
                    model.showRecordingPanel()
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Mini painel")
            }

            Spacer()
        }
        .padding(.vertical, 12)
        .background(.background)
    }
}

private struct SecondarySidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Binding var isOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                isOpen = false
            } label: {
                Label("Recolher opções", systemImage: "sidebar.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)

            Divider()

            Button {
                openWindow(id: "history")
            } label: {
                Label("Histórico", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                model.presentImportPanel()
            } label: {
                Label("Importar áudio", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.isBusy)

            Button {
                model.openOutputFolder()
            } label: {
                Label("Abrir pasta", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if model.isRecordingSession {
                Button {
                    model.showRecordingPanel()
                } label: {
                    Label("Mini painel", systemImage: "rectangle.on.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            Button("Alterar pasta") { model.chooseOutputFolder() }
                .disabled(model.isBusy)

            Text(model.settings.outputFolderURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text("Idioma")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Idioma", selection: Binding(
                get: { model.settings.language },
                set: { model.settings.language = $0 }
            )) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            .labelsHidden()
            .disabled(model.isBusy)

            notificationControl

            Spacer()
        }
        .padding(.top, 18)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .background(.background)
    }

    @ViewBuilder
    private var notificationControl: some View {
        switch model.notificationPermissionState {
        case .authorized:
            Label("Notificações ativas", systemImage: "bell.fill")
                .foregroundStyle(.secondary)
        case .denied:
            Button("Ajustes de notificações") { model.openNotificationSettings() }
        case .notDetermined, .unknown:
            Button("Ativar notificações") {
                Task { await model.requestNotificationPermission() }
            }
        }
    }
}

private struct HistoryWorkspaceView: View {
    @ObservedObject var store: MeetingStore
    @Binding var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Histórico")
                    .font(.title3.bold())
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                Divider()
                HistorySidebar(
                    store: store,
                    selection: $selection
                )
            }
            .frame(width: 280)
            Divider()
            MeetingDetailView(
                store: store,
                selectedRecordID: selection
            )
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
            HStack(alignment: .center, spacing: 7) {
                ForEach(pattern.indices, id: \.self) { index in
                    let currentLevel = activeLevel
                    Capsule()
                        .fill(color)
                        .frame(
                            width: max(5, (geometry.size.width - 140) / CGFloat(pattern.count)),
                            height: max(10, geometry.size.height * pattern[index] * currentLevel)
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
        case .recording:
            max(0.08, CGFloat(level))
        case .paused:
            0.16
        case .preparing, .finalizing, .transcribing:
            0.22
        case .idle:
            0.12
        }
    }

    private var color: Color {
        switch phase {
        case .recording:
            .red
        case .paused:
            .orange
        case .preparing, .finalizing, .transcribing:
            .blue
        case .idle:
            .secondary.opacity(0.42)
        }
    }
}

private struct MainSourceLevelView: View {
    let title: String
    let level: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(level > 0.78 ? Color.orange : Color.red.opacity(0.82))
                        .frame(width: geometry.size.width * CGFloat(level))
                }
            }
            .frame(height: 7)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.phase.title)
                        .font(.title2.bold())
                    Text(model.statusDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if model.isRecordingSession {
                    RecordingClock(
                        timeline: model.recordingTimeline,
                        isPaused: model.isPaused
                    )
                }
            }

            HStack(alignment: .bottom, spacing: 14) {
                MicrophonePicker(
                    manager: model.deviceManager,
                    selection: $model.selectedMicrophoneID,
                    disabled: model.isBusy
                )

                Button {
                    model.refreshMicrophones()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Atualizar microfones")
                .disabled(model.isBusy)

                Spacer()

                if model.isRecordingSession {
                    if model.isPaused {
                        Button {
                            model.resumeRecording()
                        } label: {
                            Label("Continuar", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.large)
                    } else {
                        Button {
                            model.pauseRecording()
                        } label: {
                            Label("Pausar", systemImage: "pause.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }

                    Button(role: .destructive) {
                        Task { await model.stopRecording() }
                    } label: {
                        Label("Parar e transcrever", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button {
                        Task { await model.beginRecording() }
                    } label: {
                        Label("Iniciar gravação", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(model.isBusy || model.selectedMicrophoneID == nil)
                }
            }

            if model.phase == .transcribing || model.phase == .finalizing || model.phase == .preparing {
                ProgressView(value: model.phase == .transcribing ? model.progress : nil)
            }

            if model.showNotificationInvitation {
                NotificationInvitationView()
            }

            SettingsStrip(settings: model.settings)
        }
        .padding(24)
        .background(.background)
    }
}

private struct MicrophonePicker: View {
    @ObservedObject var manager: AudioDeviceManager
    @Binding var selection: String?
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Microfone desta reunião")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Microfone", selection: $selection) {
                ForEach(manager.devices) { device in
                    Text(device.name + (device.isDefault ? " — padrão atual" : ""))
                        .tag(Optional(device.id))
                }
            }
            .labelsHidden()
            .frame(minWidth: 300)
            .disabled(disabled)
        }
    }
}

private struct SettingsStrip: View {
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 18) {
            Label(settings.outputFolderURL.lastPathComponent, systemImage: "folder")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Alterar pasta") { model.chooseOutputFolder() }
                .disabled(model.isBusy)
            notificationControl
            Spacer()
            Text("Idioma")
                .foregroundStyle(.secondary)
            Picker("Idioma", selection: $settings.language) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            .labelsHidden()
            .frame(width: 190)
            .disabled(model.isBusy)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var notificationControl: some View {
        switch model.notificationPermissionState {
        case .authorized:
            Label("Notificações ativas", systemImage: "bell.fill")
                .foregroundStyle(.secondary)
        case .denied:
            Button("Ajustes de notificações") { model.openNotificationSettings() }
        case .notDetermined, .unknown:
            Button("Ativar notificações") {
                Task { await model.requestNotificationPermission() }
            }
        }
    }
}

private struct CompactSettingsStrip: View {
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Label(settings.outputFolderURL.lastPathComponent, systemImage: "folder")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Alterar pasta") { model.chooseOutputFolder() }
                    .disabled(model.isBusy)
                notificationControl
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Text("Idioma")
                    .foregroundStyle(.secondary)
                Picker("Idioma", selection: $settings.language) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                .disabled(model.isBusy)
                Spacer(minLength: 0)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var notificationControl: some View {
        switch model.notificationPermissionState {
        case .authorized:
            Label("Notificações ativas", systemImage: "bell.fill")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .denied:
            Button("Ajustes de notificações") { model.openNotificationSettings() }
        case .notDetermined, .unknown:
            Button("Ativar notificações") {
                Task { await model.requestNotificationPermission() }
            }
        }
    }
}

private struct NotificationInvitationView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge")
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Avise quando a transcrição terminar")
                    .font(.headline)
                Text("O PontoGrava pode notificar você mesmo quando a janela estiver fechada.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Agora não") { model.dismissNotificationInvitation() }
            Button("Ativar") {
                Task { await model.requestNotificationPermission() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct RecordingClock: View {
    let timeline: RecordingTimeline
    let isPaused: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = timeline.elapsed(at: context.date)
            HStack(spacing: 7) {
                Circle()
                    .fill(isPaused ? .orange : .red)
                    .frame(width: 9, height: 9)
                Text(TranscriptFormatter.timestamp(elapsed))
                    .monospacedDigit()
                    .font(.title3.weight(.semibold))
            }
            .foregroundStyle(isPaused ? .orange : .red)
        }
    }
}

private struct HistorySidebar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: MeetingStore
    @Binding var selection: UUID?

    var body: some View {
        List(store.records, selection: $selection) { record in
            VStack(alignment: .leading, spacing: 5) {
                Text(record.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack {
                    Text(duration(record.duration))
                    Text("•")
                    Text(record.status.title)
                }
                .font(.caption)
                .foregroundStyle(record.status == .failed ? .orange : .secondary)
            }
            .padding(.vertical, 4)
            .tag(record.id)
            .contextMenu {
                Button("Renomear…") { model.presentRename(record) }
                    .disabled(model.isBusy)
                Divider()
                Button("Mover para a Lixeira", role: .destructive) {
                    model.presentDelete(record)
                }
                .disabled(model.isBusy)
            }
        }
        .navigationTitle("Histórico")
        .overlay {
            if store.records.isEmpty {
                ContentUnavailableView(
                    "Sem reuniões",
                    systemImage: "waveform",
                    description: Text("Suas gravações aparecerão aqui.")
                )
            }
        }
    }

    private func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct MeetingDetailView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: MeetingStore
    let selectedRecordID: UUID?

    private var record: MeetingRecord? {
        store.records.first { $0.id == selectedRecordID }
    }

    var body: some View {
        Group {
            if let record {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.title)
                                .font(.title3.bold())
                            Text("Entrada: \(record.microphoneName)")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(record.status.title)
                            .font(.caption.bold())
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.quaternary, in: Capsule())
                    }

                    if let error = record.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }

                    HStack {
                        Button("Mostrar no Finder") { model.reveal(record) }
                        Button("Refazer transcrição") {
                            Task { await model.retranscribe(record) }
                        }
                        .disabled(model.isBusy)
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        AudioPlayerView(controller: model.playbackController)
                        TranscriptPreviewView(record: record)
                    }
                    .padding(.top, 4)
                }
                .padding(24)
            } else {
                ContentUnavailableView(
                    "Selecione uma reunião",
                    systemImage: "doc.text.magnifyingglass"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct TranscriptPreviewView: View {
    let record: MeetingRecord

    @State private var text = ""
    @State private var errorMessage: String?
    @State private var saveErrorMessage: String?

    var body: some View {
        Group {
            if record.transcriptURL == nil {
                ContentUnavailableView(
                    record.status == .transcribing ? "Transcrevendo" : "Sem transcrição",
                    systemImage: "doc.text.magnifyingglass"
                )
            } else if let errorMessage {
                ContentUnavailableView(
                    "Transcrição indisponível",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    if let saveErrorMessage {
                        Label(saveErrorMessage, systemImage: "exclamationmark.triangle")
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
}

private struct AudioPlayerView: View {
    @ObservedObject var controller: AudioPlaybackController

    var body: some View {
        Group {
            if controller.isAvailable {
                HStack(spacing: 12) {
                    Button {
                        controller.togglePlayback()
                    } label: {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 18)
                    }
                    .buttonStyle(.borderedProminent)
                    .help(controller.isPlaying ? "Pausar" : "Reproduzir")

                    Text(playbackTime(controller.currentTime))
                        .monospacedDigit()
                        .font(.caption)

                    Slider(
                        value: Binding(
                            get: { controller.currentTime },
                            set: { controller.seek(to: $0) }
                        ),
                        in: 0...max(0.1, controller.duration)
                    )

                    Text(playbackTime(controller.duration))
                        .monospacedDigit()
                        .font(.caption)

                    Image(systemName: "speedometer")
                        .foregroundStyle(.secondary)
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

                    Image(systemName: "speaker.fill")
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(controller.volume) },
                            set: { controller.volume = Float($0) }
                        ),
                        in: 0...1
                    )
                    .frame(width: 90)
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            } else {
                Label("Áudio indisponível", systemImage: "waveform.slash")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            }
        }
    }

    private func playbackRateLabel(_ rate: Float) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.minimumFractionDigits = rate.rounded() == rate ? 0 : 1
        formatter.maximumFractionDigits = 2
        return "\(formatter.string(from: NSNumber(value: rate)) ?? "\(rate)")x"
    }

    private func playbackTime(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds >= 3_600 {
            return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
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
                .font(.title2.bold())
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
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
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
