import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var combinedLevel: Float {
        model.isDiscordRecording
            ? model.discordAudioLevel
            : max(model.systemAudioLevel, model.microphoneAudioLevel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    Label("Abrir", systemImage: "macwindow")
                }

                Button {
                    openWindow(id: "history")
                } label: {
                    Label("Histórico", systemImage: "clock.arrow.circlepath")
                }

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Sair")
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(width: 340)
    }

    private var recordingMonitor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Circle()
                    .fill(model.isPaused ? .orange : .red)
                    .frame(width: 9, height: 9)
                Text(model.isPaused ? "Gravação pausada" : "Gravando")
                    .font(.headline)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(TranscriptFormatter.timestamp(model.recordedDuration(at: context.date)))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(model.isPaused ? .orange : .red)
                }
            }

            Text(model.recordingSourceName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            LiveWaveformView(level: combinedLevel, isPaused: model.isPaused)
                .frame(height: 52)

            if model.isDiscordRecording {
                Text(
                    model.discordParticipants.isEmpty
                        ? "Aguardando participantes…"
                        : model.discordParticipants.joined(separator: ", ")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            } else {
                VStack(spacing: 8) {
                    SourceLevelView(title: "Sistema", level: model.systemAudioLevel)
                    SourceLevelView(title: "Microfone", level: model.microphoneAudioLevel)
                }
            }

            HStack(spacing: 10) {
                if model.isPaused {
                    Button {
                        model.resumeRecording()
                    } label: {
                        Label("Continuar", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                } else if model.canPauseRecording {
                    Button {
                        model.pauseRecording()
                    } label: {
                        Label("Pausar", systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button(role: .destructive) {
                    Task { await model.stopRecording() }
                } label: {
                    Label("Parar", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
    }

    private var idleActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PontoGrava")
                .font(.headline)
            Text(model.recordingMode == .discord ? model.discordConnectionDetail : "Microfone: \(model.selectedMicrophoneName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button {
                Task { await model.beginRecording() }
            } label: {
                Label("Iniciar gravação", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!model.canBeginRecording)

            HStack(spacing: 8) {
                Button {
                    model.presentImportPanel()
                } label: {
                    Label("Importar", systemImage: "square.and.arrow.down")
                }
                .disabled(model.isBusy)

                Button {
                    model.openOutputFolder()
                } label: {
                    Label("Pasta", systemImage: "folder")
                }
            }
            .buttonStyle(.bordered)
        }
    }
}
