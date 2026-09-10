import SwiftUI

private let menuAccent = InterfaceStyle.accent

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: model.isRecordingSession ? "record.circle.fill" : "waveform.circle.fill")
                    .font(.title2)
                    .foregroundStyle(model.isRecordingSession ? .red : menuAccent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PontoGrava")
                        .font(.headline)
                    Text(model.phase.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isRecordingSession {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(menuDuration(model.recordedDuration(at: context.date)))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(model.isPaused ? .orange : .red)
                    }
                }
            }

            if model.isRecordingSession {
                recordingMonitor
            } else {
                idleActions
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    openWindow(id: "main")
                } label: {
                    Label("Abrir app", systemImage: "macwindow")
                }

                Button {
                    if model.selectedRecordID == nil {
                        model.selectedRecordID = model.records.first?.id
                    }
                    openWindow(id: "main")
                } label: {
                    Label("Reuniões", systemImage: "clock.arrow.circlepath")
                }

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Sair")
                .accessibilityLabel("Sair do PontoGrava")
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(width: 360)
        .tint(menuAccent)
        .preferredColorScheme(settings.appearance.colorScheme)
    }

    private var recordingMonitor: some View {
        VStack(alignment: .leading, spacing: 16) {
            RecordingMonitor()
            HStack { Spacer(minLength: 0); RecordingActions(abbreviated: true) }
        }
    }

    private var idleActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Origem da gravação", selection: $model.recordingMode) {
                ForEach(RecordingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(model.isBusy)
            .accessibilityLabel("Origem da gravação")

            Text(model.recordingMode == .discord ? model.discordConnectionDetail : "Microfone: \(model.selectedMicrophoneName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if model.recordingMode == .discord && model.discordConnected {
                VStack(spacing: 8) {
                    Picker("Servidor", selection: Binding(
                        get: { model.selectedDiscordGuildID },
                        set: { id in Task { await model.selectDiscordGuild(id) } }
                    )) {
                        Text("Selecione o servidor").tag(Optional<String>.none)
                        ForEach(model.discordGuilds) { guild in
                            Text(guild.name).tag(Optional(guild.id))
                        }
                    }

                    Picker("Canal", selection: $model.selectedDiscordChannelID) {
                        Text("Selecione o canal").tag(Optional<String>.none)
                        ForEach(model.discordChannels) { channel in
                            Text("#\(channel.name)").tag(Optional(channel.id))
                        }
                    }
                }
                .disabled(model.isBusy)
            }

            RecordingActions()

            HStack(spacing: 8) {
                Button {
                    model.presentImportPanel()
                } label: {
                    Label("Importar", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.isBusy)

                Button {
                    model.openOutputFolder()
                } label: {
                    Label("Pasta", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

private func menuDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    if seconds >= 3_600 {
        return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
