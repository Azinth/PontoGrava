import AppKit
import SwiftUI

private let panelAccent = Color(red: 0.79, green: 0.35, blue: 0.21)

@MainActor
final class RecordingPanelController: NSObject, NSWindowDelegate {
    static let shared = RecordingPanelController()

    private var panel: NSPanel?

    func show(model: AppModel) {
        if panel == nil {
            panel = makePanel(model: model)
        }
        guard let panel else { return }
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func makePanel(model: AppModel) -> NSPanel {
        let size = NSSize(width: 450, height: 270)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "PontoGrava"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.contentViewController = NSHostingController(
            rootView: RecordingPanelView().environmentObject(model)
        )
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        let frame = panel.frame
        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.maxX - frame.width - 22,
                y: visibleFrame.maxY - frame.height - 22
            )
        )
    }
}

struct RecordingPanelView: View {
    @EnvironmentObject private var model: AppModel

    private var combinedLevel: Float {
        max(model.systemAudioLevel, model.microphoneAudioLevel)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: model.isPaused ? "pause.circle.fill" : "record.circle.fill")
                    .font(.title2)
                    .foregroundStyle(model.isPaused ? .orange : .red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isPaused ? "Gravação pausada" : "Gravando reunião")
                        .font(.system(.headline, design: .serif, weight: .semibold))
                    Text(model.selectedMicrophoneName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(TranscriptFormatter.timestamp(model.recordedDuration(at: context.date)))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(model.isPaused ? .orange : .primary)
                }
                Button {
                    model.hideRecordingPanel()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .help("Recolher para a barra de menus")
            }

            LiveWaveformView(level: combinedLevel, isPaused: model.isPaused)
                .frame(height: 64)
                .padding(.horizontal, 8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                SourceLevelView(title: "Sistema", level: model.systemAudioLevel)
                SourceLevelView(title: "Microfone", level: model.microphoneAudioLevel)
            }

            HStack(spacing: 10) {
                if model.isPaused {
                    Button {
                        model.resumeRecording()
                    } label: {
                        Label("Continuar", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                } else {
                    Button {
                        model.pauseRecording()
                    } label: {
                        Label("Pausar", systemImage: "pause.fill")
                    }
                    .buttonStyle(.bordered)
                }

                Button(role: .destructive) {
                    Task { await model.stopRecording() }
                } label: {
                    Label("Parar e transcrever", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 450, height: 270)
        .background(.regularMaterial)
        .tint(panelAccent)
    }
}

struct LiveWaveformView: View {
    let level: Float
    let isPaused: Bool

    private let pattern: [CGFloat] = [0.42, 0.72, 0.55, 0.9, 0.64, 1, 0.78, 0.48, 0.86, 0.58, 0.95, 0.68, 0.44, 0.8, 0.52, 0.7, 0.46]

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 5) {
                ForEach(pattern.indices, id: \.self) { index in
                    let activeLevel = isPaused ? 0.16 : max(0.08, CGFloat(level))
                    Capsule()
                        .fill(isPaused ? Color.orange : Color.red)
                        .frame(
                            width: max(4, (geometry.size.width - 80) / CGFloat(pattern.count)),
                            height: max(7, geometry.size.height * pattern[index] * activeLevel)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.12), value: level)
        }
        .accessibilityLabel(isPaused ? "Gravação pausada" : "Nível de áudio da gravação")
    }
}

struct SourceLevelView: View {
    let title: String
    let level: Float

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(level > 0.78 ? Color.orange : Color.red.opacity(0.82))
                        .frame(width: geometry.size.width * CGFloat(level))
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
        .frame(maxWidth: .infinity)
    }
}
