import AppKit
import SwiftUI

enum InterfaceStyle {
    static let accent = Color(nsColor: NSColor(name: "PontoGravaCopper") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1, green: 0.62, blue: 0.46, alpha: 1)
            : NSColor(red: 0.65, green: 0.25, blue: 0.13, alpha: 1)
    })
    static let readerWidth: CGFloat = 800
}

enum WorkspaceLayout {
    static let minimumSize = CGSize(width: 640, height: 560)
    static func showsSidebar(width: CGFloat) -> Bool { width >= 900 }
    static func showsCaptureDetails(size: CGSize) -> Bool {
        size.width >= 960 && size.height >= 680
    }
}
