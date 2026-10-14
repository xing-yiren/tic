import Foundation
import Observation

/// UserDefaults-backed, app-wide preferences for how *new* notes behave. These are defaults only —
/// each note keeps its own `floatOnTop` / `showOnAllSpaces`, and changing a default never rewrites
/// existing notes (the design's "old notes are not batch-rewritten" rule).
///
/// `@Observable` so the Settings window and menu update live; every setter persists immediately.
@MainActor
@Observable
final class NotePreferences {
    private let defaults: UserDefaults

    /// New notes float above other windows by default (the core "stays on top" experience).
    var defaultFloatOnTop: Bool { didSet { defaults.set(defaultFloatOnTop, forKey: Key.floatOnTop) } }
    /// New notes appear on every Space by default.
    var defaultShowOnAllSpaces: Bool { didSet { defaults.set(defaultShowOnAllSpaces, forKey: Key.allSpaces) } }

    /// The global "new note" hotkey (⌘⇧N out of the box). `nil` means the feature is off.
    var hotkey: HotkeyShortcut? { didSet { persistHotkey() } }

    private enum Key {
        static let floatOnTop = "newNoteFloatOnTop"
        static let allSpaces = "newNoteShowOnAllSpaces"
        static let hotkeyKeyCode = "globalHotkeyKeyCode"
        static let hotkeyModifiers = "globalHotkeyModifiers"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Register the "on" defaults so a fresh install floats + spans Spaces out of the box.
        defaults.register(defaults: [
            Key.floatOnTop: true,
            Key.allSpaces: true,
        ])
        self.defaultFloatOnTop = defaults.bool(forKey: Key.floatOnTop)
        self.defaultShowOnAllSpaces = defaults.bool(forKey: Key.allSpaces)
        if let keyCode = defaults.object(forKey: Key.hotkeyKeyCode) as? Int {
            let mods = defaults.integer(forKey: Key.hotkeyModifiers)
            self.hotkey = HotkeyShortcut(keyCode: UInt32(keyCode), carbonModifiers: UInt32(mods))
        } else {
            self.hotkey = .default
        }
    }

    /// The defaults a freshly created note should inherit.
    var newNoteDefaults: NewNoteDefaults {
        NewNoteDefaults(floatOnTop: defaultFloatOnTop, showOnAllSpaces: defaultShowOnAllSpaces)
    }

    private func persistHotkey() {
        if let hotkey {
            defaults.set(Int(hotkey.keyCode), forKey: Key.hotkeyKeyCode)
            defaults.set(Int(hotkey.carbonModifiers), forKey: Key.hotkeyModifiers)
        } else {
            defaults.removeObject(forKey: Key.hotkeyKeyCode)
            defaults.removeObject(forKey: Key.hotkeyModifiers)
        }
    }
}

/// The window-behaviour a new note inherits. A small value type so `NoteWindowManager` and the MCP
/// tools can take it without importing the preferences store.
struct NewNoteDefaults: Sendable, Equatable {
    var floatOnTop: Bool
    var showOnAllSpaces: Bool

    static let `default` = NewNoteDefaults(floatOnTop: true, showOnAllSpaces: true)
}
