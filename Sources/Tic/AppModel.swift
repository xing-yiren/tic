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
    /// Task deadlines/reminders reconciliation (M4). Created in `bootstrap`.
    @ObservationIgnored private(set) var reminders: ReminderCoordinator!

    /// All saved notes (ascending `sortIndex`, i.e. creation order) — drives the menu bar list.
    /// Stays in sync as notes are created, renamed, or deleted.
    private(set) var notes: [Note] = []

    /// All categories (ascending `sortIndex`) — drives the menu bar / pickers.
    private(set) var categories: [Category] = []

    /// Which categories the desktop is showing. Persisted so the selection survives relaunch. "Hide
    /// All" is a separate *session* toggle owned by the window manager.
    private(set) var categoryFilter: CategoryFilter

    /// The last attempt to register the global new-note hotkey, so the settings UI can explain a
    /// conflict instead of silently doing nothing.
    private(set) var hotkeyStatus: GlobalHotkeyService.RegistrationResult = .registered

    @ObservationIgnored private var notesObservation: Task<Void, Never>?
    @ObservationIgnored private var categoriesObservation: Task<Void, Never>?
    @ObservationIgnored private var searchWindow: NSWindow?
    @ObservationIgnored private var mcpWindow: NSWindow?
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var categoriesWindow: NSWindow?
    @ObservationIgnored private var overviewWindow: NSWindow?

    private init() {
        // The DB lives in Application Support; fall back to in-memory so the app still runs if
        // that can't be opened for some reason.
        guard let db = (try? AppDatabase.makeShared()) ?? (try? AppDatabase.makeInMemory()) else {
            fatalError("Tic: unable to open a database")
        }
        self.database = db
        self.windows = NoteWindowManager(appDatabase: db)
        self.mcp = MCPService(database: db)
        self.categoryFilter = CategoryFilterStore.load()
        let coordinator = ReminderCoordinator(database: db)
        coordinator.onOpenNote = { [weak self] id in
            Task { await self?.windows.focusNoteByID(id) }
        }
        self.reminders = coordinator
        NSLog("[Tic] Database ready at \(db.path) (\(Environment.current))")
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
        // MCP-created notes share the UI's defaults and target category (the plan's one-creation-rule).
        mcp.newNotePolicy = { [weak self] in
            await MainActor.run {
                guard let self else { return MCPTools.NewNotePolicy() }
                return MCPTools.NewNotePolicy(
                    defaults: self.preferences.newNoteDefaults,
                    categoryID: self.defaultNewNoteCategoryID()
                )
            }
        }
        mcp.onRemindersChanged = { [weak self] in
            Task { @MainActor in self?.reconcileReminders() }
        }
    }

    /// Run once after launch: open saved note panels, then start streaming the notes list.
    func bootstrap() async {
        windows.newNoteDefaults = preferences.newNoteDefaults
        windows.onRemindersChanged = { [weak self] in self?.reconcileReminders() }
        windows.categoryFilter = categoryFilter
        windows.newNoteCategoryID = { [weak self] in self?.defaultNewNoteCategoryID() }
        await windows.restoreAll()
        await windows.reconcileVisibility()   // apply the persisted filter to the restored panels
        startObservingNotes()
        startObservingCategories()
        applyLaunchAtLogin(launchAtLogin)   // honor the saved preference (effective when packaged)
        applyGlobalHotkey()
        if mcpEnabled { applyMCPEnabled(true) }
        updates.start()
        // Reconcile reminders on launch (the system may have delivered or missed some while we quit).
        Task { await reminders?.reconcile() }
    }

    /// Re-run reminder reconciliation — after any task/reminder change, on wake, or on a timezone
    /// change. Cheap and idempotent.
    func reconcileReminders() {
        Task { await reminders?.reconcile() }
    }

    /// Completes a task from a notification's "Complete" action, reusing the same cascade the UI and
    /// MCP use, then reschedules (the reminder is cancelled because the task is done).
    func completeTaskFromReminder(taskID: UUID) async {
        do {
            guard let task = try await database.task(id: taskID), !task.isDone else { return }
            let all = try await database.tasks(noteId: task.noteId)
            let toggled = TaskOutline.applyingToggle(all, toggling: taskID, now: Date())
            try await database.updateTaskCompletion(TaskOutline.completionChanges(from: all, to: toggled))
            await reminders?.reconcile()
        } catch {
            NSLog("[Tic] completeTaskFromReminder failed: \(error)")
        }
    }

    /// The category a newly created note should land in: the single selected category when exactly
    /// one is chosen (and uncategorised isn't also in the set), else uncategorised.
    private func defaultNewNoteCategoryID() -> UUID? {
        guard categoryFilter.mode == .selected else { return nil }
        if categoryFilter.categoryIDs.count == 1, !categoryFilter.includesUncategorized {
            return categoryFilter.categoryIDs.first
        }
        return nil
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

    private func startObservingCategories() {
        categoriesObservation?.cancel()
        categoriesObservation = Task { [weak self, database] in
            do {
                for try await list in database.observeCategories() {
                    self?.categories = list
                    self?.pruneFilter()
                }
            } catch {
                NSLog("[Tic] categories observation ended: \(error)")
            }
        }
    }

    // MARK: - Categories & filtering

    /// Drops category ids that no longer exist from the persisted filter (e.g. a category deleted in
    /// another build/instance), and re-reconciles if anything changed.
    private func pruneFilter() {
        let live = Set(categories.map(\.id))
        var filter = categoryFilter
        let before = filter.categoryIDs
        filter.categoryIDs.formIntersection(live)
        guard filter.categoryIDs != before else { return }
        setCategoryFilter(filter)
    }

    /// Applies and persists a new category filter, reconciling the live panels.
    func setCategoryFilter(_ filter: CategoryFilter) {
        categoryFilter = filter
        windows.categoryFilter = filter
        CategoryFilterStore.save(filter)
        Task { await windows.reconcileVisibility() }
    }

    /// Toggles one category in the visible set. Selecting from `.all` starts a fresh selection with
    /// just that category; the last deselection leaves an empty (show-nothing) selection.
    func toggleCategoryVisibility(_ id: UUID) {
        var filter = categoryFilter
        if filter.mode == .all {
            filter.mode = .selected
            filter.categoryIDs = [id]
            filter.includesUncategorized = false
        } else if filter.categoryIDs.contains(id) {
            filter.categoryIDs.remove(id)
        } else {
            filter.categoryIDs.insert(id)
        }
        setCategoryFilter(filter)
    }

    /// Toggles "Uncategorised" as a visible option.
    func toggleUncategorizedVisibility() {
        var filter = categoryFilter
        if filter.mode == .all {
            filter.mode = .selected
            filter.categoryIDs = []
            filter.includesUncategorized = true
        } else {
            filter.includesUncategorized.toggle()
        }
        setCategoryFilter(filter)
    }

    /// Show every category (no restriction).
    func showAllCategories() { setCategoryFilter(.all) }

    /// Session-only "hide everything". Not persisted.
    func setHideAll(_ hidden: Bool) { Task { await windows.setTemporarilyHideAll(hidden) } }

    var hideAllActive: Bool { windows.temporarilyHideAll }

    /// Creates a category and reveals it (so a note created into it right after is visible).
    @discardableResult
    func createCategory(name: String) async throws -> Category {
        let category = try await database.createCategory(name: name)
        // New categories start visible if we're in a restrictive filter — otherwise the note the user
        // creates next could silently land off-screen.
        if categoryFilter.mode == .selected { categoryFilter.categoryIDs.insert(category.id); setCategoryFilter(categoryFilter) }
        return category
    }

    func renameCategory(id: UUID, name: String) async throws {
        try await database.renameCategory(id: id, name: name)
    }

    func reorderCategories(_ orderedIDs: [UUID]) async throws {
        try await database.reorderCategories(orderedIDs)
    }

    /// Deletes a category (its notes fall back to uncategorised) and drops it from the filter.
    func deleteCategory(id: UUID) async {
        do {
            _ = try await database.deleteCategory(id: id)
            var filter = categoryFilter
            filter.removeCategory(id)
            setCategoryFilter(filter)
            await windows.reconcileVisibility()
        } catch {
            NSLog("[Tic] deleteCategory failed: \(error)")
        }
    }

    /// Assigns a note to a category (nil = uncategorised) and re-reconciles visibility, so moving a
    /// note to a hidden category drops it from view and moving it back restores it.
    func setCategory(_ categoryID: UUID?, for note: Note) async {
        do {
            try await database.updateNoteCategory(id: note.id, categoryID: categoryID)
            await windows.reconcileVisibility()
        } catch {
            NSLog("[Tic] setCategory failed: \(error)")
        }
    }

    // MARK: - Actions

    /// Create and open a fresh note (cascaded). Used by every "new list" surface — the menu bar, the
    /// Dock menu, a note's "+" button, and the global hotkey all funnel here, so they share one
    /// creation strategy (defaults + category + focus).
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
        windows.showAll()
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

    /// Opens the Categories management window (create / rename / reorder / delete).
    func openCategories() {
        if categoriesWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
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
            panel.contentView = NSHostingView(rootView: CategoryManagementView())
            categoriesWindow = panel
        }
        guard let window = categoriesWindow else { return }
        centerOnActiveDisplay(window)
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func dismissCategories() {
        categoriesWindow?.orderOut(nil)
    }

    /// Opens the Overview window: every list grouped by category, with switches to put individual
    /// lists on (or off) the desktop. A single reused, centered, floating panel like the others.
    func openOverview() {
        if overviewWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
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
            panel.contentView = NSHostingView(rootView: OverviewView())
            overviewWindow = panel
        }
        guard let window = overviewWindow else { return }
        centerOnActiveDisplay(window)
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Closes the Overview window (Escape / its Done button).
    func dismissOverview() {
        overviewWindow?.orderOut(nil)
    }

    /// Puts a note on the desktop or takes it off — the Overview's per-list switch. Routes through
    /// the same `isOpen` open/close path the menu bar and the header X use, so a note switched on
    /// here and left alone is restored at launch exactly as it is now.
    func setOnDesktop(_ note: Note, visible: Bool) {
        Task {
            if visible {
                await windows.openNoteByID(note.id)
            } else {
                await windows.closeNoteByID(note.id)
            }
        }
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
