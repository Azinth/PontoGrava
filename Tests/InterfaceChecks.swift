import AppKit
import Foundation

@main
@MainActor
enum InterfaceChecks {
    static func main() throws {
        assert(!WorkspaceLayout.showsSidebar(width: 899))
        assert(WorkspaceLayout.showsSidebar(width: 900))
        assert(!WorkspaceLayout.showsCaptureDetails(size: CGSize(width: 959, height: 800)))
        assert(!WorkspaceLayout.showsCaptureDetails(size: CGSize(width: 960, height: 679)))
        assert(WorkspaceLayout.showsCaptureDetails(size: CGSize(width: 960, height: 680)))
        let markdown = "# Reunião\n\n## Decisões\n\n- **Publicar** a versão\n- Revisar o áudio\n\n1. Testar\n2. Entregar\n\n[Documentação](https://example.com)\n\n```swift\nlet value = 1\n```"
        let rendered = MeetingDocumentRenderer.render(markdown, markdown: true)
        assert(rendered.string.contains("Reunião\nDecisões"))
        assert(rendered.string.contains("•  Publicar a versão"))
        assert(rendered.string.contains("2.  Entregar"))
        assert(!rendered.string.contains("**"))
        let headingFont = rendered.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        assert(headingFont.pointSize == 25)
        let linkRange = (rendered.string as NSString).range(of: "Documentação")
        assert(rendered.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
        let plain = "[00:12:34] Ana: reunião com acentuação e https://example.com/" + String(repeating: "x", count: 300)
        assert(MeetingDocumentRenderer.render(plain, markdown: false).string == plain)
        assert(MeetingDocumentRenderer.render("", markdown: true).string == "")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("resumo.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        let library = DocumentLibrary()
        let session = library.session(for: url, onSave: {})
        assert(session.text == markdown && !session.isEditing)
        session.isEditing = true
        let edited = markdown + "\n\nPróximo passo: validar."
        session.update(edited)
        let saved = try String(contentsOf: url, encoding: .utf8)
        assert(saved == edited)
        session.finishEditing()
        assert(!session.isEditing && !session.hasUnsavedChanges)
        assert(library.session(for: url, onSave: {}) === session)

        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: folder, to: moved)
        session.isEditing = true
        session.update(edited + "\nRascunho preservado")
        session.finishEditing()
        session.reload()
        assert(session.saveError != nil && session.isEditing && library.hasUnsavedChanges)
        assert(session.text.hasSuffix("Rascunho preservado"))
        session.update(edited)
        assert(session.saveError == nil && !library.hasUnsavedChanges, "Undoing back to saved text clears the failure")
        session.update(edited + "\nRascunho preservado")
        try FileManager.default.moveItem(at: moved, to: folder)
        session.finishEditing()
        assert(session.saveError == nil && !session.isEditing && !library.hasUnsavedChanges)
        let recovered = try String(contentsOf: url, encoding: .utf8)
        assert(recovered == session.text)
        print("Interface checks passed: responsive boundaries, Markdown, raw text, editing and save recovery")
    }
}
