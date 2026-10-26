import SwiftUI
import AppKit

/// The app's SwiftUI scenes. There is no window here: every visible surface (notes, Overview, the
/// Lists palette, Preferences) is an AppKit window owned by `AppModel`. The menu-bar item is also
/// AppKit (`MenuBarController`, installed by `AppDelegate`), because a `.menu`-style `MenuBarExtra`
/// can't do submenus or context menus.
struct TicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// The status-bar icon: a template-rendered menu-bar glyph (bundled via SPM resources), falling
/// back to an SF Symbol if the resource can't be found. A small dot marks an update the user
/// hasn't looked at yet. The dot is drawn *into* the image: the status item renders only the
/// label's image, so a SwiftUI overlay never shows. Shared with `MenuBarController`, which draws
/// the same glyph into its `NSStatusItem`.
enum MenuBarLabel {
    /// The icon for the current update state (`badged` = an unseen update).
    static func image(badged: Bool) -> NSImage? {
        let rendered = badged ? badgedIcon : icon
        return rendered ?? NSImage(systemSymbolName: badged ? "checklist.checked" : "checklist",
                                   accessibilityDescription: "Tic")
    }

    static let glyph: NSImage? = {
        guard let url = menuBarIconURL() else { return nil }
        return NSImage(contentsOf: url)
    }()
    static let icon = glyph.map { compose($0, dot: false) }
    static let badgedIcon = glyph.map { compose($0, dot: true) }

    /// 20×18 template image: the 18pt glyph plus (optionally) a 6pt dot at the top-right, with a
    /// knocked-out ring so it reads as a badge. Both variants share a size so nothing shifts.
    static func compose(_ glyph: NSImage, dot: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            glyph.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            if dot {
                let dot = NSRect(x: 14, y: 11, width: 6, height: 6)
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func menuBarIconURL() -> URL? {
        let fileManager = FileManager.default
        let fileName = "MenuBarIcon.png"
        let resourceBundleName = "Tic_Tic.bundle"
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()

        var candidates: [URL] = []

        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png") {
            candidates.append(url)
        }

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(fileName))
        }

        for baseURL in [Bundle.main.bundleURL, Bundle.main.resourceURL, executableDirectory].compactMap({ $0 }) {
            candidates.append(baseURL.appendingPathComponent(resourceBundleName).appendingPathComponent(fileName))
        }

        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }
}
