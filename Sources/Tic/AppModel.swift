import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// App-wide coordinator. Bridges the SwiftUI menu bar scene and the AppKit window layer (which
/// otherwise can't reach each other): it owns the shared `AppDatabase` + `NoteWindowManager`,
/// streams the live list of notes for the menu bar, and exposes the high-level actions invoked
/// from the menu bar, the Dock menu, and a note's "+" button.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let database: AppDatabase
    let windows: NoteWindowManager
    let updates = UpdateChecker()
    let preferences = NotePreferences()
    @ObservationIgnored private let mcp: MCPService
    @ObservationIgnored private let hotkeys = GlobalHotkeyService()
    /// All saved notes (ascending `sortIndex`, i.e. creation order) — drives the menu bar list.
    /// Stays in sync as notes are created, renamed, or deleted.
    private(set) var notes: [Note] = []



    /// The last attempt to register the global new-note hotkey, so the settings UI can explain a
    /// conflict instead of silently doing nothing.
    private(set) var hotkeyStatus: GlobalHotkeyService.RegistrationResult = .registered

    @ObservationIgnored private var notesObservation: Task<Void, Never>?
    @ObservationIgnored private var searchWindow: NSWindow?
    @ObservationIgnored private var mcpWindow: NSWindow?
    @ObservationIgnored private var settingsWindow: NSWindow?
    private init() {
        // The DB lives in Application Support; fall back to in-memory so the app still runs if
        // that can't be opened for some reason.
        guard let db = (try? AppDatabase.makeShared()) ?? (try? AppDatabase.makeInMemory()) else {
            fatalError("Tic: unable to open a database")
        }
        self.database = db
        self.windows = NoteWindowManager(appDatabase: db)
        self.mcp = MCPService(database: db)
        NSLog("[Tic] Database ready at \(db.path)")
        mcp.onConnectionCountChange = { [weak self] count in
            Task { @MainActor in self?.mcpConnections = count }
        }
        // Window pokes the MCP tools need, hopped to the main actor (the service runs off it).
        mcp.windowActions = MCPTools.WindowActions(
            open: { [weak self] id in await self?.windows.openNoteByID(id) },
            close: { [weak self] id in await self?.windows.closeNoteByID(id) },
            setFrame: { [weak self] id, rect in await self?.windows.setFrame(id, to: rect) },
            focus: { [weak self] id in await self?.windows.focusNoteByID(id) }
        )
    }

    /// Run once after launch: open saved note panels, then start streaming the notes list.
    func bootstrap() async {
        await windows.restoreAll()
        startObservingNotes()
        applyLaunchAtLogin(launchAtLogin)   // honor the saved preference (effective when packaged)
        if mcpEnabled { applyMCPEnabled(true) }
        updates.start()
    }




    // MARK: - New-note defaults & global hotkey

    /// Pushes the current new-note defaults into the window manager (existing notes are untouched).
    func applyNewNoteDefaults() {
        windows.newNoteDefaults = preferences.newNoteDefaults
    }

    /// (Re)registers the global new-note hotkey from the saved preference, recording the result so
    /// the settings UI can surface a conflict. A conflict leaves the previous chord unregistered.
    @discardableResult
    func applyGlobalHotkey() -> GlobalHotkeyService.RegistrationResult {
        guard let shortcut = preferences.hotkey else {
            hotkeys.unregister()
            hotkeyStatus = .invalid
            return hotkeyStatus
        }
        let result = hotkeys.register(shortcut) { [weak self] in
            self?.newNoteFromHotkey()
        }
        hotkeyStatus = result
        return result
    }

    /// The global hotkey fired: create + open a note and take focus (an explicit user gesture).
    private func newNoteFromHotkey() {
        NSApp.activate(ignoringOtherApps: true)
        Task { await windows.newNote() }
    }

    private func startObservingNotes() {
        notesObservation?.cancel()
        notesObservation = Task { [weak self, database] in
            do {
                for try await list in database.observeNotes() {
                    self?.notes = list
                }
            } catch {
                NSLog("[Tic] notes observation ended: \(error)")
            }
        }
    }


    // MARK: - Categories & filtering













    // MARK: - Actions

    /// Create and open a fresh note (cascaded). Used by every "new list" surface.
    func newNote() {
        NSApp.activate()
        Task { await windows.newNote() }
    }

    /// Open a note (or bring it to front if already open) and activate the app.
    func open(_ note: Note) {
        windows.openNote(note)
        NSApp.activate()
    }

    /// Bring all open notes to the front.
    func showAll() {
        NSApp.activate()
    }

    /// Permanently delete a note (and its tasks, via the FK cascade). Removed from the list
    /// immediately so it can't be reopened during the async delete; the observation confirms.
    func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        Task { await windows.deleteNote(note) }
    }

    /// Opens the searchable "Lists" palette — a floating, centered panel that always comes to the
    /// front when called. Reuses a single instance. (A real window, so search/delete re-render
    /// reliably, unlike the menu-bar popover.)
    func openSearch() {
        if searchWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 440),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.contentView = NSHostingView(rootView: ListsSearchView())
            searchWindow = panel
        }
        guard let window = searchWindow else { return }
        centerOnActiveDisplay(window)    // centered on screen every time it's called
        window.level = .floating         // and always on top when called
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Dead-centre of the display the pointer is on. `NSWindow.center()` isn't that: it sits above
    /// centre, and on whichever display the reused panel was last shown.
    private func centerOnActiveDisplay(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        guard let area = (NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main)?.visibleFrame
        else { return }
        window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
    }

    /// Closes the Lists palette (Escape / pick a list / its close button).
    func dismissSearch() {
        searchWindow?.orderOut(nil)
    }

    /// Opens the "AI Agents (MCP)" setup window (the toggle + per-client install snippets). A single
    /// reused, centered, floating panel — same treatment as the Lists palette.
    func openMCPSetup() {
        if mcpWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.contentView = NSHostingView(rootView: MCPSetupView())
            mcpWindow = panel
        }
        guard let window = mcpWindow else { return }
        centerOnActiveDisplay(window)
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func dismissMCPSetup() {
        mcpWindow?.orderOut(nil)
    }

    /// Opens the Preferences window (new-note defaults + global hotkey). A single reused, centered,
    /// floating panel — same treatment as the Lists palette and MCP setup.
    func openSettings() {
        if settingsWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.contentView = NSHostingView(rootView: SettingsView())
            settingsWindow = panel
        }
        guard let window = settingsWindow else { return }
        centerOnActiveDisplay(window)
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func dismissSettings() {
        settingsWindow?.orderOut(nil)
    }



    // MARK: - MCP (AI agents)

    private static let mcpEnabledKey = "mcpEnabled"

    /// Whether AI agents may drive Tic over MCP. Off by default and remembered; the socket exists
    /// only while this is on, so a client spawning `Tic --mcp` meanwhile fails fast with a hint.
    private(set) var mcpEnabled: Bool = UserDefaults.standard.bool(forKey: AppModel.mcpEnabledKey)

    /// Agents connected right now (the MCP window's status line).
    private(set) var mcpConnections = 0

    var mcpSocketPath: String { mcp.socketPath }

    func setMCPEnabled(_ enabled: Bool) {
        mcpEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.mcpEnabledKey)
        applyMCPEnabled(enabled)
    }

    private func applyMCPEnabled(_ enabled: Bool) {
        guard enabled else { return mcp.stop() }
        do {
            try mcp.start()
            NSLog("[Tic] MCP listening at \(mcp.socketPath)")
        } catch {
            NSLog("[Tic] MCP failed to start: \(error)")
            mcpEnabled = false
        }
    }

    // MARK: - Launch at login

    private static let launchAtLoginKey = "launchAtLogin"

    /// The user's "open at login" preference (drives the menu checkmark). Stored & @Observable so
    /// the menu updates the tick live; persisted so it survives relaunch. The actual `SMAppService`
    /// registration only takes effect for a packaged `.app` (a bare `swift run` executable can't
    /// be a login item).
    private(set) var launchAtLogin: Bool = UserDefaults.standard.bool(forKey: AppModel.launchAtLoginKey)

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled   // @Observable → the menu checkmark updates immediately
        UserDefaults.standard.set(enabled, forKey: Self.launchAtLoginKey)
        applyLaunchAtLogin(enabled)
    }

    /// Reconciles the actual login-item registration with the saved preference.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            switch (enabled, SMAppService.mainApp.status) {
            case (true, let status) where status != .enabled:
                try SMAppService.mainApp.register()
            case (false, .enabled):
                try SMAppService.mainApp.unregister()
            default:
                break
            }
        } catch {
            NSLog("[Tic] Launch at Login \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }
}
