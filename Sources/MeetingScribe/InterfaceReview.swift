#if DEBUG
import AppKit
import AVFoundation
import SwiftUI

/// Runs only on explicit request, with temporary meetings and a separate preferences domain.
/// It never calls AppModel.initialize(), connects providers or starts a real recording.
@MainActor
enum InterfaceReview {
    static func run(output: URL) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        var failure: Error?
        DispatchQueue.main.async {
            do { try perform(output: output) } catch { failure = error }
            app.stop(nil)
            app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
        app.run()
        if let failure { throw failure }
    }

    private static func perform(output: URL) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PontoGrava-interface-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "PontoGrava.InterfaceReview.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        settings.outputFolderPath = root.path
        settings.hasCompletedOnboarding = true
        let store = MeetingStore(applicationSupportURL: root)
        let model = AppModel(settings: settings, meetingStore: store)
        let summary = """
        # Uma semana de boas conversas

        ## Decisões da equipe

        A próxima versão do **PontoGrava** vai colocar o conteúdo da reunião em primeiro lugar, com uma interface confortável em qualquer janela.

        - Melhorar a leitura de resumos e transcrições.
        - Manter os controles de gravação sempre à mão.
        - Preservar cada edição ao redimensionar a janela.

        ## Próximos passos

        1. Validar o aplicativo em telas menores.
        2. Revisar os temas claro e escuro.
        3. Compartilhar a versão para avaliação.

        ### Notas da conversa

        Consulte a [documentação de referência](https://example.com) para acompanhar os detalhes.
        """
        let audioURL = root.appendingPathComponent("audio.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000)!
        buffer.frameLength = 480_000
        memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        let audio = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        try audio.write(from: buffer)
        for index in 0..<12 {
            let folder = root.appendingPathComponent("meeting-\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let summaryURL = folder.appendingPathComponent("resumo.md")
            let transcriptURL = folder.appendingPathComponent("transcricao.txt")
            try (summary + String(repeating: "\n\nMais detalhes da reunião, com decisões e responsabilidades da equipe.", count: 30)).write(to: summaryURL, atomically: true, encoding: .utf8)
            try String(repeating: "[00:01:12] Ana: Vamos revisar a experiência de uso e organizar os próximos passos.\n\n", count: 50).write(to: transcriptURL, atomically: true, encoding: .utf8)
            store.upsert(MeetingRecord(
                id: UUID(), createdAt: Date(timeIntervalSince1970: 1_788_950_000 - Double(index * 86_400)),
                title: index == 0 ? "Planejamento da equipe · Setembro" : "Reunião de acompanhamento · \(12 - index)",
                folderPath: folder.path, audioPath: audioURL.path, transcriptPath: transcriptURL.path,
                summaryPath: summaryURL.path, duration: 325, status: .ready, errorMessage: nil,
                microphoneName: "Discord · Equipe de produto / Sala de reuniões"
            ))
        }
        model.selectedRecordID = store.records.first!.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "PontoGrava — revisão visual"
        window.isReleasedWhenClosed = false
        let documents = DocumentLibrary()
        let rootView = ContentView(documents: documents).environmentObject(model).environmentObject(settings)
        window.contentViewController = NSHostingController(rootView: rootView)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--interactive") {
            model.configureInterfaceReview(discord: false, phase: .recording)
            while window.isVisible { settle(1) }
            return
        }
        settle(1)
        let sizes = [CGSize(width: 640, height: 560), CGSize(width: 760, height: 560), CGSize(width: 900, height: 650), CGSize(width: 1280, height: 800), CGSize(width: 1440, height: 900)]
        for appearance in [AppAppearance.light, .dark] {
            settings.appearance = appearance
            window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
            for size in sizes {
                model.configureInterfaceReview(discord: true, phase: .recording)
                window.setContentSize(size)
                settle()
                try capture(window, output: output, name: "\(appearance.rawValue)-\(Int(size.width))x\(Int(size.height))")
                for identifier in ["recording.stop", "playback.speed", "document.edit"] {
                    _ = requireControl(identifier, in: window)
                }
                if size.width >= 900 {
                    let split = splitViews(in: window.contentView!).first { $0.isVertical && $0.arrangedSubviews.count >= 2 }!
                    let sidebarWidth = split.arrangedSubviews[0].frame.width
                    precondition(sidebarWidth >= 239 && sidebarWidth <= 301, "Sidebar width outside supported range: \(sidebarWidth)")
                }
                let actual = window.contentView!.bounds.size
                precondition(abs(actual.width - size.width) < 2, "Window refused requested width: \(actual) vs \(size)")
            }
        }
        // Keep the same view and model while resizing through every breakpoint.
        settings.appearance = .light
        window.appearance = NSAppearance(named: .aqua)
        model.configureInterfaceReview(discord: false, phase: .idle)
        settle()
        let document = documents.session(for: store.records.first!.summaryURL!, onSave: {})
        document.isEditing = true
        settle()
        let editor = textViews(in: window.contentView!).first { $0.isEditable }!
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("Revisão de interface\n\n", replacementRange: NSRange(location: 0, length: 0))
        settle()
        let selectedRange = editor.selectedRange()
        let editedText = editor.string
        let savedText = try String(contentsOf: store.records.first!.summaryURL!, encoding: .utf8)
        precondition(savedText == editedText, "Editing must save original text")
        model.playbackController.seek(to: 1)
        model.playbackController.togglePlayback()
        for width in stride(from: 1440, through: 640, by: -20) {
            window.setContentSize(CGSize(width: width, height: 700))
            settle(0.03)
            precondition(model.selectedRecordID == store.records.first!.id)
            precondition(textViews(in: window.contentView!).contains { $0 === editor }, "Editor identity changed on resize")
            precondition(editor.selectedRange() == selectedRange && editor.string == editedText)
            precondition(model.playbackController.isPlaying, "Playback interrupted on resize")
        }
        model.playbackController.pause()
        try capture(window, output: output, name: "editing-640")
        document.finishEditing()
        settle()
        precondition(!editor.isEditable)
        print("Verified editing, selection, document identity and playback through 41 widths")
        let scenarios: [(String, AppPhase, Bool)] = [
            ("local-recording", .recording, false), ("local-paused", .paused, false),
            ("transcribing", .transcribing, false), ("summarizing", .summarizing, false),
            ("publishing", .publishing, true), ("idle", .idle, false)
        ]
        window.setContentSize(sizes[0])
        for (name, phase, discord) in scenarios {
            model.configureInterfaceReview(discord: discord, phase: phase)
            settle()
            try capture(window, output: output, name: name)
        }
        var record = store.records.first!
        record.title = "Reunião de planejamento com um título bastante longo para verificar a quebra de texto em janelas pequenas"
        record.errorMessage = "Não foi possível concluir a transcrição. O áudio foi salvo e pode ser processado novamente."
        record.status = .failed
        store.upsert(record)
        settle()
        try capture(window, output: output, name: "long-title-error")
        record.summaryPath = nil
        record.transcriptPath = nil
        store.upsert(record)
        settle()
        try capture(window, output: output, name: "missing-documents")
        model.selectedRecordID = nil
        settle()
        try capture(window, output: output, name: "no-selection")
        for record in store.records { store.remove(record) }
        window.setContentSize(sizes[3])
        settle()
        try capture(window, output: output, name: "empty-history")
        if !CommandLine.arguments.contains("--checks-only"), let screen = window.screen {
            window.setFrame(screen.visibleFrame, display: true)
            window.toggleFullScreen(nil)
            settle(1.5)
            try capture(window, output: output, name: "full-screen")
            window.toggleFullScreen(nil)
            settle(1.5)
        }
        window.close()

        try captureSurface(AppSettingsView().environmentObject(model).environmentObject(settings), size: CGSize(width: 640, height: 560), name: "settings", output: output)
        try captureSurface(OnboardingView().environmentObject(model).environmentObject(settings), size: CGSize(width: 580, height: 520), name: "onboarding", output: output)
        model.configureInterfaceReview(discord: false, phase: .recording)
        try captureSurface(RecordingPanelView().environmentObject(model).environmentObject(settings), size: CGSize(width: 450, height: 310), name: "floating-panel", output: output)
        try captureSurface(MenuBarView().environmentObject(model).environmentObject(settings), size: CGSize(width: 360, height: 350), name: "menu-bar", output: output)
        print("Interface review completed: \(output.path)")
    }

    private static func accessibilityElements(_ element: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 30 else { return [] }
        let children = element.responds(to: NSSelectorFromString("accessibilityChildren"))
            ? (element.value(forKey: "accessibilityChildren") as? [NSObject] ?? []) : []
        return [element] + children.flatMap { accessibilityElements($0, depth: depth + 1) }
    }

    @discardableResult private static func requireControl(_ identifier: String, in window: NSWindow) -> NSObject {
        let matches = accessibilityElements(window).filter {
            $0.responds(to: NSSelectorFromString("accessibilityIdentifier")) && $0.value(forKey: "accessibilityIdentifier") as? String == identifier
        }
        guard let match = matches.first(where: {
            guard let frame = ($0.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else { return false }
            return !frame.isEmpty && window.frame.insetBy(dx: -1, dy: -1).contains(frame)
        }) else { fatalError("Control missing or clipped: \(identifier); matches: \(matches)") }
        return match
    }

    private static func splitViews(in view: NSView) -> [NSSplitView] {
        (view as? NSSplitView).map { [$0] } ?? view.subviews.flatMap { splitViews(in: $0) }
    }

    private static func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }

    private static func captureSurface<V: View>(_ view: V, size: CGSize, name: String, output: URL) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        settle()
        try capture(window, output: output, name: name)
        window.close()
    }

    private static func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func capture(_ window: NSWindow, output: URL, name: String) throws {
        if CommandLine.arguments.contains("--checks-only") { return }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        settle()
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.appendingPathComponent("\(name).png").path]
        try capture.run()
        capture.waitUntilExit()
        guard capture.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        print("Captured \(name)")
    }
}
#endif
