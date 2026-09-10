import AppKit
import Combine
import SwiftUI

@MainActor
final class DocumentLibrary: ObservableObject {
    @Published private(set) var hasUnsavedChanges = false
    private var sessions: [URL: DocumentSession] = [:]

    func session(for url: URL, onSave: @escaping () -> Void) -> DocumentSession {
        if let session = sessions[url] { return session }
        sessions = sessions.filter { $0.value.hasUnsavedChanges || $0.key.deletingLastPathComponent() == url.deletingLastPathComponent() }
        let session = DocumentSession(url: url, onSave: onSave)
        session.onStateChange = { [weak self] in
            guard let self else { return }
            hasUnsavedChanges = sessions.values.contains { $0.hasUnsavedChanges }
        }
        sessions[url] = session
        return session
    }
    func retryPendingChanges() -> Bool {
        for session in sessions.values where session.hasUnsavedChanges { session.save() }
        return !hasUnsavedChanges
    }

    func discardPendingChanges() {
        for session in sessions.values where session.hasUnsavedChanges { session.discardChanges() }
    }

}

@MainActor
final class DocumentSession: ObservableObject {
    let url: URL
    @Published private(set) var text = ""
    @Published private(set) var loadError: String?
    @Published private(set) var saveError: String?
    @Published var isEditing = false
    var onStateChange: (() -> Void)?
    private var savedText = ""
    private let onSave: () -> Void
    private var notificationTask: Task<Void, Never>?
    var hasUnsavedChanges: Bool { text != savedText }

    init(url: URL, onSave: @escaping () -> Void = {}) {
        self.url = url
        self.onSave = onSave
        reload()
    }

    func reload() {
        guard !hasUnsavedChanges else { return }
        do {
            let value = try String(contentsOf: url, encoding: .utf8)
            savedText = value
            text = value
            loadError = nil
        } catch { loadError = error.localizedDescription }
    }

    func update(_ value: String) {
        guard value != text else { return }
        text = value
        save()
    }

    @discardableResult func save() -> Bool {
        guard hasUnsavedChanges else {
            saveError = nil
            onStateChange?()
            return true
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            savedText = text
            saveError = nil
            notificationTask?.cancel()
            notificationTask = Task { [onSave] in
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                onSave()
            }
            onStateChange?()
            return true
        } catch {
            saveError = error.localizedDescription
            onStateChange?()
            return false
        }
    }

    func finishEditing() {
        if save() { isEditing = false }
    }

    func discardChanges() {
        text = savedText
        saveError = nil
        isEditing = false
        onStateChange?()
    }
}

/// Foundation provides Markdown structure; AppKit provides selection, wrapping and links.
/// The source file is never rewritten by formatting the reading view.
enum MeetingDocumentRenderer {
    static func render(_ source: String, markdown: Bool) -> NSAttributedString {
        let bodyFont = NSFont.systemFont(ofSize: 15)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.paragraphSpacing = 12
        let base: [NSAttributedString.Key: Any] = [
            .font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ]
        guard markdown, let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            let result = NSMutableAttributedString(string: source, attributes: base)
            let expression = try? NSRegularExpression(pattern: #"\[?\b\d{2}:\d{2}(?::\d{2})?\b\]?"#)
            for match in expression?.matches(in: source, range: NSRange(location: 0, length: result.length)) ?? [] {
                result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium), range: match.range)
            }
            return result
        }
        let result = NSMutableAttributedString(string: "")
        var previousBlock: Int?
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            var attributes = base
            let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
            var font = bodyFont
            var prefix = ""
            var listDepth = 0
            var ordered = false
            for component in components {
                if case .orderedList = component.kind { ordered = true }
                switch component.kind {
                case .unorderedList, .orderedList: listDepth += 1
                default: break
                }
            }
            for component in components {
                switch component.kind {
                case .header(let level):
                    font = .systemFont(ofSize: level == 1 ? 25 : (level == 2 ? 20 : 17), weight: .semibold)
                    style.paragraphSpacingBefore = 14
                    style.paragraphSpacing = 10
                case .listItem(let ordinal):
                    prefix = ordered ? "\(ordinal).  " : "•  "
                    style.firstLineHeadIndent = CGFloat(max(0, listDepth - 1)) * 20
                    style.headIndent = style.firstLineHeadIndent + 22
                    style.paragraphSpacing = 7
                case .codeBlock:
                    font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                    attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.08)
                case .blockQuote:
                    style.headIndent = 16
                    style.firstLineHeadIndent = 16
                    attributes[.foregroundColor] = NSColor.secondaryLabelColor
                default: break
                }
            }
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { font = .monospacedSystemFont(ofSize: 13, weight: .regular) }
                if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link, ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                attributes[.link] = link
            }
            attributes[.font] = font
            attributes[.paragraphStyle] = style
            if block != previousBlock {
                if result.length > 0 { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
                if !prefix.isEmpty { result.append(NSAttributedString(string: prefix, attributes: attributes)) }
                previousBlock = block
            }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result.length == 0 && !source.isEmpty ? NSAttributedString(string: source, attributes: base) : result
    }
}

struct EditableTextFileView: View {
    @EnvironmentObject private var documents: DocumentLibrary
    let url: URL
    let reloadToken: String
    let unavailableTitle: String
    let savedMessage: String
    let accessibilityLabel: String
    let isDisabled: Bool
    let onSave: () -> Void

    var body: some View {
        DocumentEditor(session: documents.session(for: url, onSave: onSave),
                       unavailableTitle: unavailableTitle, accessibilityLabel: accessibilityLabel,
                       isDisabled: isDisabled)
            .onChange(of: reloadToken) { _, _ in documents.session(for: url, onSave: onSave).reload() }
    }
}

private struct DocumentEditor: View {
    @ObservedObject var session: DocumentSession
    let unavailableTitle: String
    let accessibilityLabel: String
    let isDisabled: Bool
    @State private var copied = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { status; Spacer(minLength: 12); actions }
                VStack(alignment: .leading, spacing: 8) { actions; status }
            }
            if let error = session.loadError {
                ContentUnavailableView(unavailableTitle, systemImage: "exclamationmark.triangle", description: Text(error))
                Button("Tentar novamente") { session.reload() }
            } else {
                NativeDocumentTextView(session: session, isDisabled: isDisabled, accessibilityLabel: accessibilityLabel)
                    .frame(maxWidth: InterfaceStyle.readerWidth, maxHeight: .infinity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: contrast == .increased ? 1.5 : 0.5) }
            }
            if let error = session.saveError {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sua edição permanece aqui. \(error)").font(.callout)
                    Button("Tentar salvar novamente") { session.save() }
                }
                .padding(10)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var status: some View {
        Label(session.saveError == nil ? (session.isEditing ? "Alterações salvas automaticamente" : "Pronto para leitura") : "Não foi possível salvar",
              systemImage: session.saveError == nil ? (session.isEditing ? "checkmark.circle" : "doc.text") : "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(session.saveError == nil ? Color.secondary : Color.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.text, forType: .string)
                copied = true
            } label: { Label(copied ? "Copiado" : "Copiar texto", systemImage: copied ? "checkmark" : "doc.on.doc") }
                .disabled(session.text.isEmpty)
            Button {
                if session.isEditing { session.finishEditing() } else { session.isEditing = true }
            } label: {
                Label(session.isEditing ? "Concluir edição" : "Editar", systemImage: session.isEditing ? "checkmark" : "pencil")
            }
            .disabled(isDisabled || session.loadError != nil)
            .accessibilityIdentifier("document.edit")
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .onChange(of: session.text) { _, _ in copied = false }
    }
}

struct NativeDocumentTextView: NSViewRepresentable {
    @ObservedObject var session: DocumentSession
    let isDisabled: Bool
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        let textView = scroll.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityIdentifier("document.text")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let textView = scroll.documentView as! NSTextView
        let coordinator = context.coordinator
        textView.isEditable = session.isEditing && !isDisabled
        textView.isSelectable = true
        guard coordinator.source != session.text || coordinator.editing != session.isEditing else { return }
        let selection = textView.selectedRange()
        let origin = scroll.contentView.bounds.origin
        coordinator.updating = true
        if session.isEditing {
            textView.textStorage?.setAttributedString(NSAttributedString(string: session.text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: NSColor.labelColor
            ]))
        } else {
            textView.textStorage?.setAttributedString(MeetingDocumentRenderer.render(session.text, markdown: session.url.pathExtension == "md"))
        }
        coordinator.source = session.text
        coordinator.editing = session.isEditing
        textView.setSelectedRange(NSRange(location: min(selection.location, textView.string.utf16.count), length: 0))
        scroll.contentView.scroll(to: origin)
        coordinator.updating = false
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: DocumentSession
        var source: String?
        var editing: Bool?
        var updating = false
        init(session: DocumentSession) { self.session = session }
        func textDidChange(_ notification: Notification) {
            guard !updating, let textView = notification.object as? NSTextView else { return }
            source = textView.string
            session.update(textView.string)
        }
    }
}

/// Keeps the native SwiftUI delegates while adding a close/quit guard for failed writes.
struct UnsavedDocumentProtection: NSViewRepresentable {
    let documents: DocumentLibrary

    func makeCoordinator() -> Coordinator { Coordinator(documents: documents) }
    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.attach = { [weak coordinator = context.coordinator] window in coordinator?.attach(to: window) }
        return view
    }
    func updateNSView(_ view: AttachmentView, context: Context) {}
    static func dismantleNSView(_ view: AttachmentView, coordinator: Coordinator) { coordinator.detach() }

    final class AttachmentView: NSView {
        var attach: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach?(window) }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        let documents: DocumentLibrary
        weak var window: NSWindow?
        weak var windowDelegate: NSWindowDelegate?
        init(documents: DocumentLibrary) { self.documents = documents }

        @MainActor func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            detach()
            self.window = window
            windowDelegate = window.delegate
            DocumentApplicationDelegate.libraries.add(documents)
            window.delegate = self
        }

        func detach() {
            if window?.delegate === self { window?.delegate = windowDelegate }
            window = nil
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || windowDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if windowDelegate?.responds(to: selector) == true { return windowDelegate }
            return super.forwardingTarget(for: selector)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            documents.resolvePendingChanges() && (windowDelegate?.windowShouldClose?(sender) ?? true)
        }

    }
}

@MainActor
final class DocumentApplicationDelegate: NSObject, NSApplicationDelegate {
    static let libraries = NSHashTable<DocumentLibrary>.weakObjects()
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for library in Self.libraries.allObjects {
            if !library.resolvePendingChanges() { return .terminateCancel }
        }
        return .terminateNow
    }
}

extension DocumentLibrary {
    func resolvePendingChanges() -> Bool {
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Sua edição ainda não foi salva"
        alert.informativeText = "Volte ao documento para continuar ou tente salvar novamente antes de fechar."
        alert.addButton(withTitle: "Voltar à edição")
        alert.addButton(withTitle: "Tentar salvar")
        alert.addButton(withTitle: "Descartar edição").hasDestructiveAction = true
        switch alert.runModal() {
        case .alertSecondButtonReturn: return retryPendingChanges()
        case .alertThirdButtonReturn: discardPendingChanges(); return true
        default: return false
        }
    }
}
