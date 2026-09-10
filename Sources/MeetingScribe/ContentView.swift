import AppKit
import SwiftUI

private let brandAccent = InterfaceStyle.accent

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    @StateObject private var documents: DocumentLibrary
    @State private var sidebarVisibility = NavigationSplitViewVisibility.all
    @State private var showingMeetings = false
    @State private var restoringSelection = false

    init(documents: DocumentLibrary? = nil) {
        _documents = StateObject(wrappedValue: documents ?? DocumentLibrary())
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = WorkspaceLayout.showsSidebar(width: geometry.size.width)
            NavigationSplitView(columnVisibility: Binding(
                get: { wide ? sidebarVisibility : .detailOnly },
                set: { if wide { sidebarVisibility = $0 } }
            )) {
                AppSidebar()
                    .frame(minWidth: 240, maxWidth: 300)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 300)
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                MainWorkspace()
                    .toolbar(removing: .sidebarToggle)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Group {
                                Button {
                                    if wide { sidebarVisibility = sidebarVisibility == .all ? .detailOnly : .all }
                                    else { showingMeetings = true }
                                } label: {
                                    Label("Reuniões", systemImage: "sidebar.left")
                                }
                                .accessibilityIdentifier("meetings.open")
                            }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button { model.presentImportPanel() } label: {
                                Label("Importar áudio", systemImage: "square.and.arrow.down")
                            }
                            .disabled(model.isBusy)
                            .help("Importar áudio")
                        }
                    }
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar(removing: .sidebarToggle)
        }
        .environmentObject(documents)
        .background(UnsavedDocumentProtection(documents: documents).frame(width: 0, height: 0))
        .sheet(isPresented: $showingMeetings) {
            VStack(spacing: 0) {
                HStack {
                    Text("Reuniões").font(.headline)
                    Spacer()
                    Button("Concluído") { showingMeetings = false }
                        .keyboardShortcut(.cancelAction)
                }.padding(16)
                AppSidebar()
            }
            .environmentObject(documents)
            .frame(width: 420, height: 480)
            .onChange(of: model.selectedRecordID) { _, _ in showingMeetings = false }
        }
        .onChange(of: model.selectedRecordID) { old, _ in
            if restoringSelection { restoringSelection = false; return }
            if documents.hasUnsavedChanges {
                restoringSelection = true
                model.selectedRecordID = old
                model.warningMessage = "Salve a edição pendente antes de trocar de reunião."
            }
        }
        .tint(brandAccent)
        .preferredColorScheme(settings.appearance.colorScheme)
        .frame(minWidth: WorkspaceLayout.minimumSize.width, minHeight: WorkspaceLayout.minimumSize.height)
        .sheet(item: renameRequest) { record in
            RenameMeetingView(record: record)
                .environmentObject(model)
        }
        .confirmationDialog(
            "Excluir conteúdo da reunião?",
            isPresented: deleteRequestPresented,
            titleVisibility: .visible,
            presenting: deleteRecord
        ) { record in
            Button("Excluir apenas o áudio", role: .destructive) {
                Task { await model.deleteMeeting(record, scope: .audio) }
            }
            .disabled(!model.hasContent(.audio, in: record))
            Button("Excluir apenas o texto", role: .destructive) {
                Task { await model.deleteMeeting(record, scope: .text) }
            }
            .disabled(!model.hasContent(.text, in: record))
            Button("Excluir áudio e texto", role: .destructive) {
                Task { await model.deleteMeeting(record, scope: .all) }
            }
            .disabled(!model.hasContent(.all, in: record))
            Button("Cancelar", role: .cancel) { model.meetingManagementRequest = nil }
        } message: { _ in
            Text("Os itens escolhidos serão movidos para a Lixeira. Excluir o áudio também remove todas as partes ocultas usadas na recuperação.")
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
        .alert(
            "Substituir o resumo editado?",
            isPresented: replaceSummaryRequestPresented,
            presenting: replaceSummaryRecord
        ) { record in
            Button("Cancelar", role: .cancel) { model.meetingManagementRequest = nil }
            Button("Substituir", role: .destructive) {
                Task { await model.replaceSummary(for: record) }
            }
        } message: { _ in
            Text("O conteúdo atual de resumo.md será substituído por um novo resumo da transcrição salva.")
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

    private var replaceSummaryRequestPresented: Binding<Bool> {
        Binding(
            get: {
                if case .replaceSummary = model.meetingManagementRequest { return true }
                return false
            },
            set: { if !$0 { model.meetingManagementRequest = nil } }
        )
    }

    private var replaceSummaryRecord: MeetingRecord? {
        guard case let .replaceSummary(record) = model.meetingManagementRequest else { return nil }
        return record
    }
}

private struct AppSidebar: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject private var documents: DocumentLibrary

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
                        .font(.system(.title, design: .default, weight: .semibold))
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
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)

            List(filteredRecords, selection: Binding(
                get: { model.selectedRecordID },
                set: { id in
                    guard !documents.hasUnsavedChanges else {
                        model.warningMessage = "Há uma edição que ainda não pôde ser salva. Tente salvar novamente antes de trocar de reunião."
                        return
                    }
                    model.selectedRecordID = id
                }
            )) { record in
                MeetingRow(record: record)
                    .tag(record.id)
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
        .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial))
    }
}

private struct AppStatusPill: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Label(model.phase.title, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityLabel("Status: \(model.phase.title)")
    }

    private var icon: String {
        switch model.phase {
        case .idle: "checkmark.circle.fill"
        case .preparing, .finalizing, .transcribing, .summarizing, .publishing, .cleaning: "hourglass"
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        }
    }

    private var color: Color {
        switch model.phase {
        case .idle: .green
        case .preparing, .finalizing, .transcribing, .summarizing, .publishing, .cleaning: .blue
        case .recording: .red
        case .paused: .orange
        }
    }
}

private struct MeetingRow: View {
    @EnvironmentObject private var model: AppModel
    let record: MeetingRecord

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
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

                HStack(spacing: 5) {
                    Text(record.microphoneName)
                        .lineLimit(1)
                    Text("•")
                    Text(model.formattedDiskUsage(for: record))
                        .fixedSize()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Ações da reunião")
            .accessibilityLabel("Ações de \(record.title)")
        }
        .padding(.vertical, 5)
        .contextMenu { actions }
    }

    @ViewBuilder
    private var actions: some View {
        Button {
            model.presentRename(record)
        } label: {
            Label("Renomear…", systemImage: "pencil")
        }
        .disabled(model.isBusy)

        Button {
            model.reveal(record)
        } label: {
            Label("Mostrar no Finder", systemImage: "folder")
        }

        Divider()

        Button(role: .destructive) {
            model.presentDelete(record)
        } label: {
            Label("Excluir…", systemImage: "trash")
        }
        .disabled(model.isBusy)
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

            HStack(spacing: 12) {
                Text(appVersion)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                SettingsLink {
                    Label("Ajustes", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Abrir Ajustes")
            }
        }
        .padding(14)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        return "Versão \(version)"
    }
}

struct SummaryPromptSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Prompt do resumo")
                .font(.title2.bold())

            Toggle(
                "Usar prompt personalizado",
                isOn: Binding(
                    get: { model.settings.usesCustomSummaryPrompt },
                    set: { model.settings.usesCustomSummaryPrompt = $0 }
                )
            )

            Text("Descreva o formato, o nível de detalhe e as informações que devem aparecer. A transcrição e o idioma são adicionados automaticamente.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(
                    get: { model.settings.customSummaryPrompt },
                    set: {
                        model.settings.customSummaryPrompt = String(
                            $0.prefix(SummaryPrompt.maximumCustomPromptCharacters)
                        )
                    }
                ))
                .font(.body.monospaced())
                .padding(6)

                if model.settings.customSummaryPrompt.isEmpty {
                    Text("Exemplo: Crie um resumo em Markdown com os principais tópicos, decisões e próximos passos. Seja breve e preserve os nomes dos participantes.")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 190)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.25))
            }
            .disabled(!model.settings.usesCustomSummaryPrompt)
            .opacity(model.settings.usesCustomSummaryPrompt ? 1 : 0.6)

            Text("\(model.settings.customSummaryPrompt.count) de \(SummaryPrompt.maximumCustomPromptCharacters) caracteres")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text("Quando desativado, o app usa o formato padrão: o que foi feito, definido e está pendente.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Limpar prompt", role: .destructive) {
                    model.settings.customSummaryPrompt = ""
                }
                .disabled(model.settings.customSummaryPrompt.isEmpty)

                Spacer()

                Button("Concluído") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 560, maxWidth: 600, minHeight: 460, idealHeight: 500)
    }
}

struct SidebarNotificationControl: View {
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
    @State private var showingCapture = false

    var body: some View {
        GeometryReader { geometry in
            let showsDetails = WorkspaceLayout.showsCaptureDetails(size: geometry.size)
            VStack(spacing: 0) {
                RecordingStrip(showDetails: { showingCapture = true }, showsDetails: showsDetails)
                Divider()
                HStack(spacing: 0) {
                    MeetingDetailView(store: model.meetingStore, selectedRecordID: model.selectedRecordID)
                    if showsDetails {
                        Divider()
                        ScrollView { CaptureDetails().padding(20) }
                            .frame(width: 300)
                    }
                }
            }
            .sheet(isPresented: $showingCapture) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Detalhes da captura").font(.headline)
                        Spacer()
                        Button("Concluído") { showingCapture = false }
                            .keyboardShortcut(.cancelAction)
                    }.padding(20)
                    Divider()
                    ScrollView { CaptureDetails().padding(20) }
                }
                .frame(width: 480, height: 460)
            }
            .onChange(of: showsDetails) { _, value in
                if value { showingCapture = false }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct RecordingStrip: View {
    @EnvironmentObject private var model: AppModel
    let showDetails: () -> Void
    let showsDetails: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                status
                Spacer(minLength: 12)
                controls
            }
            VStack(alignment: .leading, spacing: 12) {
                status
                HStack { Spacer(minLength: 0); controls }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.background)
    }

    private var status: some View {
        HStack(spacing: 12) {
            Image(systemName: model.isRecordingSession ? (model.isPaused ? "pause.circle.fill" : "record.circle.fill") : "waveform.circle")
                .font(.title)
                .foregroundStyle(model.isRecordingSession ? (model.isPaused ? Color.orange : Color.red) : brandAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.phase.title).font(.headline).fixedSize()
                Text(model.isRecordingSession ? model.recordingSourceName : (model.recordingMode == .discord ? "Captura do Discord" : "Áudio do Mac e microfone"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if model.isRecordingSession { RecordingTime() }
            if model.isBusy && !model.isRecordingSession {
                ProgressView().controlSize(.small).accessibilityLabel(model.statusDetail)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if !showsDetails {
                Button(action: showDetails) {
                    Label("Captura", systemImage: "slider.horizontal.3")
                }
                .help("Configurar origem e ver detalhes da captura")
                .accessibilityIdentifier("capture.details")
            }
            RecordingActions()
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct CaptureDetails: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Captura").font(.title3.weight(.semibold))
                Text(model.statusDetail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isRecordingSession {
                RecordingMonitor()
            } else {
                Picker("Origem", selection: $model.recordingMode) {
                    ForEach(RecordingMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .disabled(model.isBusy)
                if model.recordingMode == .discord {
                    DiscordSetupView()
                } else {
                    MicrophonePicker(manager: model.deviceManager, selection: $model.selectedMicrophoneID, disabled: model.isBusy)
                }
            }
            if model.isBusy && !model.isRecordingSession {
                ProgressView(value: model.phase == .transcribing || model.phase == .summarizing || model.phase == .publishing ? model.progress : nil)
            }
            if model.showNotificationInvitation { NotificationInvitationView() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DiscordSetupView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
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
                GeometryReader { geometry in
                    let compact = geometry.size.width < 700 || geometry.size.height < 600
                    VStack(spacing: 0) {
                    meetingHeader(record, compact: compact)
                    Divider()
                    AudioPlayerView(controller: model.playbackController, compact: geometry.size.width - 40 < 650)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    Divider()
                    MeetingDocumentsView(record: record)
                        .id(record.id)
                        .padding(compact ? 12 : 20)
                    }
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

    private func meetingHeader(_ record: MeetingRecord, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title)
                        .font(compact ? .headline : .title2.weight(.semibold))
                        .lineLimit(2)
                        .help(record.title)
                        .textSelection(.enabled)
                    Text("\(record.microphoneName) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).help(record.microphoneName)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                meetingActions(record)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { metadata(record) }
                VStack(alignment: .leading, spacing: 6) { metadata(record) }
            }
            if let error = record.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.primary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }
            if !compact {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Button { model.reveal(record) } label: { Label("Mostrar no Finder", systemImage: "folder") }
                        Button { model.requestSummary(for: record) } label: {
                            Label(model.hasSummary(record) ? "Refazer resumo" : "Gerar resumo", systemImage: "text.document")
                        }
                        .disabled(model.isBusy || !model.hasTranscript(in: record))
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()
                    EmptyView()
                }
            }
        }
        .padding(compact ? 12 : 20)
    }

    @ViewBuilder private func metadata(_ record: MeetingRecord) -> some View {
        MeetingStatusBadge(status: record.status)
        Label(model.formattedDiskUsage(for: record), systemImage: "internaldrive")
            .font(.caption).foregroundStyle(.secondary)
        discordPublicationStatus(record)
    }

    private func meetingActions(_ record: MeetingRecord) -> some View {
        Menu {
            Button("Renomear…") { model.presentRename(record) }
                .disabled(model.isBusy)
            Button("Mostrar no Finder") { model.reveal(record) }
            Button("Refazer transcrição") {
                Task { await model.retranscribe(record) }
            }
            .disabled(model.isBusy || !model.hasContent(.audio, in: record))
            Button(model.hasSummary(record) ? "Refazer resumo" : "Gerar resumo") {
                model.requestSummary(for: record)
            }
            .disabled(
                model.isBusy
                    || !model.hasTranscript(in: record)
            )
            if model.isDiscordMeeting(record) {
                let publicationState = model.discordPublicationState(for: record)
                Button(
                    discordPublicationButtonTitle(publicationState)
                ) {
                    Task { await model.publishToDiscord(record) }
                }
                .disabled(
                    model.isBusy
                        || !model.hasTranscript(in: record)
                        || !model.discordConnected
                        || publicationState == .published
                        || publicationState == .unavailable
                )
            }
            Divider()
            Button("Excluir…", role: .destructive) {
                model.presentDelete(record)
            }
            .disabled(model.isBusy)
        } label: {
            Label("Mais ações", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func discordPublicationButtonTitle(_ state: DiscordPublicationState) -> String {
        switch state {
        case .published: "Publicado no Discord"
        case .modified: "Atualizar no Discord"
        case .unpublished, .unavailable: "Publicar no Discord"
        }
    }

    private func discordPublicationButtonIcon(_ state: DiscordPublicationState) -> String {
        state == .published ? "checkmark.circle.fill" : "paperplane"
    }

    @ViewBuilder
    private func discordPublicationStatus(_ record: MeetingRecord) -> some View {
        switch model.discordPublicationState(for: record) {
        case .published:
            Label("Publicado no Discord", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .modified:
            Label("Alterações ainda não publicadas", systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .unpublished, .unavailable:
            EmptyView()
        }
    }
}

private struct MeetingStatusBadge: View {
    let status: MeetingStatus

    var body: some View {
        Label(status.title, systemImage: meetingStatusIcon(status))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
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

private enum MeetingDocumentTab: String, CaseIterable, Identifiable {
    case summary
    case transcript

    var id: String { rawValue }
    var title: String { self == .summary ? "Resumo" : "Transcrição" }
}

private struct MeetingDocumentsView: View {
    let record: MeetingRecord
    @State private var selectedTab: MeetingDocumentTab
    @EnvironmentObject private var documents: DocumentLibrary
    @EnvironmentObject private var model: AppModel

    init(record: MeetingRecord) {
        self.record = record
        _selectedTab = State(initialValue: record.summaryPath == nil ? .transcript : .summary)
    }

    var body: some View {
        VStack(spacing: 12) {
            Picker("Conteúdo da reunião", selection: Binding(
                get: { selectedTab },
                set: { tab in
                    guard !documents.hasUnsavedChanges else {
                        model.warningMessage = "Salve a edição pendente antes de trocar de documento."
                        return
                    }
                    selectedTab = tab
                }
            )) {
                ForEach(MeetingDocumentTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)

            Group {
                switch selectedTab {
                case .summary:
                    SummaryPreviewView(record: record)
                case .transcript:
                    TranscriptPreviewView(record: record)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: record.summaryPath) { _, value in
            if value != nil && !documents.hasUnsavedChanges { selectedTab = .summary }
        }
    }
}

private struct SummaryPreviewView: View {
    @EnvironmentObject private var model: AppModel
    let record: MeetingRecord

    var body: some View {
        Group {
            if let url = record.summaryURL {
                VStack(alignment: .leading, spacing: 10) {
                    if model.phase == .summarizing, model.summarizingRecordID == record.id {
                        ProgressView(value: model.progress)
                        Text(model.statusDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    EditableTextFileView(
                        url: url,
                        reloadToken: "\(url.path)-\(model.summaryRevision)",
                        unavailableTitle: "Resumo indisponível",
                        savedMessage: "Salvo automaticamente em resumo.md",
                        accessibilityLabel: "Resumo editável",
                        isDisabled: model.phase == .publishing,
                        onSave: model.meetingDocumentDidChange
                    )
                }
            } else if model.phase == .summarizing, model.summarizingRecordID == record.id {
                VStack(spacing: 12) {
                    ProgressView(value: model.progress)
                        .frame(maxWidth: 320)
                    ContentUnavailableView(
                        "Gerando resumo",
                        systemImage: "text.document",
                        description: Text(model.statusDetail)
                    )
                }
            } else {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        model.summaryUnavailableMessage == nil ? "Sem resumo" : "Resumo indisponível",
                        systemImage: "text.document",
                        description: Text(
                            model.summaryUnavailableMessage
                                ?? "Gere um resumo local com o que foi feito, definido e ainda está pendente."
                        )
                    )
                    Button("Gerar resumo") {
                        model.requestSummary(for: record)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(brandAccent)
                    .disabled(
                        model.isBusy
                            || !model.hasTranscript(in: record)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct TranscriptPreviewView: View {
    @EnvironmentObject private var model: AppModel
    let record: MeetingRecord

    var body: some View {
        Group {
            if let url = record.transcriptURL {
                EditableTextFileView(
                    url: url,
                    reloadToken: "\(url.path)-\(record.status.rawValue)",
                    unavailableTitle: "Transcrição indisponível",
                    savedMessage: "Salvo automaticamente em transcricao.txt",
                    accessibilityLabel: "Transcrição editável",
                    isDisabled: model.phase == .publishing,
                    onSave: model.meetingDocumentDidChange
                )
            } else {
                ContentUnavailableView(
                    record.status == .transcribing ? "Transcrevendo" : "Sem transcrição",
                    systemImage: record.status == .transcribing ? "waveform.badge.magnifyingglass" : "doc.text.magnifyingglass",
                    description: record.status == .transcribing ? Text("A transcrição local aparecerá aqui quando estiver pronta.") : nil
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                        primaryControls
                        secondaryControls
                    }
                } else {
                    HStack(spacing: 12) {
                        primaryControls
                        secondaryControls
                    }
                }
            } else {
                Label("Áudio indisponível", systemImage: "waveform.slash")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    private var primaryControls: some View {
        HStack(spacing: 10) {
            playbackButton
            currentTime
            positionSlider
            duration
        }
        .frame(maxWidth: .infinity)
    }

    private var secondaryControls: some View {
        HStack(spacing: 12) {
            playbackRate
            Spacer(minLength: 0)
            volume.frame(width: compact ? 150 : 100)
        }
        .frame(maxWidth: compact ? .infinity : 204)
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
        .accessibilityLabel(controller.isPlaying ? "Pausar reprodução" : "Reproduzir áudio")
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
        Picker("Velocidade de reprodução", selection: $controller.playbackRate) {
            ForEach(AudioPlaybackController.playbackRates, id: \.self) { rate in
                Text(playbackRateLabel(rate)).tag(rate)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 80, height: 28)
        .accessibilityLabel("Velocidade de reprodução")
        .accessibilityValue(playbackRateLabel(controller.playbackRate))
        .accessibilityIdentifier("playback.speed")
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
                .font(.system(.title2, design: .default, weight: .semibold))
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
        .frame(minWidth: 360, idealWidth: 460, maxWidth: 480)
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
