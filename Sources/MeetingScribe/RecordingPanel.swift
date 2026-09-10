import AppKit
import SwiftUI

private let panelAccent = InterfaceStyle.accent

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
        let size = NSSize(width: 450, height: 300)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("PontoGrava").font(.headline)
                Spacer()
                RecordingTime()
                Button { model.hideRecordingPanel() } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .help("Recolher para a barra de menus")
                    .accessibilityLabel("Recolher painel de gravação")
            }
            RecordingMonitor()
            HStack { Spacer(minLength: 0); RecordingActions() }
        }
        .padding(20)
        .frame(width: 450)
        .fixedSize(horizontal: false, vertical: true)
        .background(.background)
        .tint(panelAccent)
        .preferredColorScheme(settings.appearance.colorScheme)
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
