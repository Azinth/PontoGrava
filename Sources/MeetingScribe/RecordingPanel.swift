import AppKit
import SwiftUI

private let panelAccent = InterfaceStyle.accent

@MainActor
final class RecordingPanelController: NSObject, NSWindowDelegate {
    static let shared = RecordingPanelController()

    private var panel: NSPanel?

    func show(model: AppModel) {
        if panel == nil {
            let created = makePanel(model: model)
            position(created)
            panel = created
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func makePanel(model: AppModel) -> NSPanel {
        let size = NSSize(width: 300, height: 44)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "PontoGrava"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.canHide = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.delegate = self
        panel.contentViewController = NSHostingController(
            rootView: RecordingPanelView()
                .environmentObject(model)
                .environmentObject(model.settings)
        )
        if let view = panel.contentViewController?.view { panel.setContentSize(view.fittingSize) }
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
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            RecordingGlyph(level: model.liveAudioLevel, isPaused: model.isPaused)
            RecordingTime()
            Spacer(minLength: 0)
            if model.canPauseRecording {
                Button {
                    Task { await model.togglePause() }
                } label: { Image(systemName: model.isPaused ? "play.fill" : "pause.fill") }
                    .help(model.isPaused ? "Continuar" : "Pausar")
                    .accessibilityLabel(model.isPaused ? "Continuar gravação" : "Pausar gravação")
            }
            Button(role: .destructive) {
                Task { await model.stopRecording() }
            } label: { Image(systemName: "stop.fill").foregroundStyle(.red) }
                .help("Parar e transcrever")
                .accessibilityLabel("Parar e transcrever")
            Button {
                NSApplication.shared.unhide(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                if !NSApplication.shared.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                    openWindow(id: "main")
                }
            } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Abrir o PontoGrava")
                .accessibilityLabel("Expandir")
            Button { model.hideRecordingPanel() } label: { Image(systemName: "minus") }
                .help("Minimizar para a barra de menus")
                .accessibilityLabel("Minimizar para a barra de menus")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(width: 300, height: 44)
        .background(.regularMaterial, in: Capsule())
        .contentShape(Capsule())
        .gesture(WindowDragGesture())
        .tint(panelAccent)
        .preferredColorScheme(settings.appearance.colorScheme)
    }
}

/// The app icon in miniature: a dot followed by bars that follow the live audio level.
struct RecordingGlyph: View {
    let level: Float
    let isPaused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pattern: [CGFloat] = [0.4, 0.75, 1, 0.65, 0.4]

    var body: some View {
        let color: Color = isPaused ? .orange : .red
        let scale = isPaused ? 0.45 : 0.45 + 0.55 * CGFloat(min(1, max(0, level)))
        HStack(spacing: 2.5) {
            Circle().fill(color).frame(width: 10, height: 10).padding(.trailing, 2)
            ForEach(pattern.indices, id: \.self) { index in
                Capsule().fill(color).frame(width: 2.5, height: 20 * pattern[index] * scale)
            }
        }
        .frame(height: 20)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}

struct LiveWaveformView: View {
    let level: Float
    let isPaused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pattern: [CGFloat] = [0.42, 0.72, 0.55, 0.9, 0.64, 1, 0.78, 0.48, 0.86, 0.58, 0.95, 0.68, 0.44, 0.8, 0.52, 0.7, 0.46]

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 5) {
                ForEach(pattern.indices, id: \.self) { index in
                    let activeLevel = isPaused ? 0.16 : max(0.08, CGFloat(level))
                    Capsule()
                        .fill(isPaused ? Color.orange : Color.red)
                        .frame(
                            width: max(1, (geometry.size.width - CGFloat(pattern.count - 1) * 5) / CGFloat(pattern.count)),
                            height: max(7, geometry.size.height * pattern[index] * activeLevel)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
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
                        .frame(width: geometry.size.width * CGFloat(min(1, max(0, level))))
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nível de \(title)")
        .accessibilityValue("\(Int(min(1, max(0, level)) * 100)) por cento")
    }
}
