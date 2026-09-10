import SwiftUI

struct RecordingActions: View {
    @EnvironmentObject private var model: AppModel
    var abbreviated = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actions }
            VStack(alignment: .trailing, spacing: 8) { actions }
        }
        .controlSize(.large)
    }

    @ViewBuilder private var actions: some View {
        if model.isRecordingSession {
            if model.canPauseRecording {
                Button {
                    model.isPaused ? model.resumeRecording() : model.pauseRecording()
                } label: {
                    Label(model.isPaused ? "Continuar" : "Pausar", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("recording.pause")
            }
            Button(role: .destructive) {
                Task { await model.stopRecording() }
            } label: {
                Label(abbreviated ? "Parar" : "Parar e transcrever", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityLabel("Parar e transcrever")
            .accessibilityIdentifier("recording.stop")
        } else if model.phase == .idle {
            Button {
                Task { await model.beginRecording() }
            } label: {
                Label(model.recordingMode == .discord ? "Gravar canal" : "Iniciar gravação", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(InterfaceStyle.accent)
            .disabled(!model.canBeginRecording)
            .accessibilityIdentifier("recording.start")
        }
    }
}

struct RecordingMonitor: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(model.isPaused ? "Gravação pausada" : model.recordingSourceName,
                  systemImage: model.isPaused ? "pause.circle.fill" : "waveform")
                .font(.headline)
                .lineLimit(2)
                .help(model.recordingSourceName)
            LiveWaveformView(
                level: model.isDiscordRecording ? model.discordAudioLevel : max(model.systemAudioLevel, model.microphoneAudioLevel),
                isPaused: model.isPaused
            )
            .frame(height: 56)
            if model.isDiscordRecording {
                Label(model.discordParticipants.isEmpty ? "Aguardando participantes…" : model.discordParticipants.joined(separator: ", "),
                      systemImage: "person.2")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    SourceLevelView(title: "Sistema", level: model.systemAudioLevel)
                    SourceLevelView(title: "Microfone", level: model.microphoneAudioLevel)
                }
            }
        }
    }
}

struct RecordingTime: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(TranscriptFormatter.timestamp(model.recordedDuration(at: context.date)))
                .font(.system(.headline, design: .monospaced))
                .foregroundStyle(model.isPaused ? Color.orange : Color.primary)
                .fixedSize()
                .accessibilityLabel("Duração: \(TranscriptFormatter.timestamp(model.recordedDuration(at: context.date)))")
        }
    }
}
