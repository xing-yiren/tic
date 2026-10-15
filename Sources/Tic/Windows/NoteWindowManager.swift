import AppKit
import SwiftUI

/// Owns the live `NotePanel`s — one per note — and keeps their on-screen frames in sync with
/// the database. Acts as each panel's window delegate.
@MainActor
final class NoteWindowManager: NSObject, NSWindowDelegate {
    private let appDatabase: AppDatabase
    private var panels: [UUID: NotePanel] = [:]
    private var controllers: [UUID: NoteController] = [:]
    private var pendingFrameSaves: [UUID: Task<Void, Never>] = [:]
    /// Height a note had before it was rolled up, so it restores to the right size on expand.
    private var expandedHeights: [UUID: CGFloat] = [:]
    /// Each open note's frame as saved in the DB — the last spot the user chose. Only user drags and
    /// resizes update it; a placement we or macOS make (display unplugged, launch rescue) never does,
    /// so a note parked on the laptop at home still returns to its monitor at the office.
    private var savedFrames: [UUID: CGRect] = [:]
    /// True while `place` moves a panel, so its own `windowDidMove` isn't persisted.
    private var placing = false
    /// Frame saves are dropped until this instant after a display change: macOS moves windows off a
    /// vanished display at about the same time as the notification, in either order.
    private var suppressSavesUntil = Date.distantPast
    /// The one image window, reused for whichever image was opened last.
    private var imageWindow: NSWindow?
    /// The note whose image the image window is showing, so closing that note closes it too.
    private var imageWindowNoteID: UUID?

    /// Window behaviour a freshly created note inherits (float-on-top / all-Spaces defaults). Set by
    /// `AppModel` from `NotePreferences`; changing it never rewrites existing notes.
    var newNoteDefaults: NewNoteDefaults = .default

    /// Assigned a new note's category on creation (the currently-selected single category, or nil for
    /// uncategorised). Set by `AppModel` in M2; a no-op until then.
    var newNoteCategoryID: () -> UUID? = { nil }

    /// Called before a note is surfaced so a filtered-out note can be un-hidden first (M2). Returns
    /// true when the note was hidden by the filter and has now been revealed.
    var onWillReveal: ((UUID) -> Bool)?

    /// Fired when a task's deadline/reminder changes, so the app can reconcile system notifications.
    var onRemindersChanged: (() -> Void)?

    /// Notes currently hidden by the category filter (M2). Empty until categories land.
    private(set) var hiddenByFilter: Set<UUID> = []

    /// The category filter the desktop is honouring. Drives which open notes have a visible panel.
    var categoryFilter: CategoryFilter = .all

    /// Session-only "hide everything" (the menu's Hide All). Never persisted — cleared on relaunch, and
    /// deliberately separate from each note's `isOpen` so it can't be mistaken for a user close.
    private(set) var temporarilyHideAll = false

    /// A note is "on screen" if it has a panel and isn't merely order-out'd by the filter.
    func isOnScreen(_ id: UUID) -> Bool { panels[id] != nil && !hiddenByFilter.contains(id) }

    /// Notes whose panels exist (used by the menu bar's "visible" list in M2).
    var openNoteIDs: [UUID] { Array(panels.keys) }

    init(appDatabase: AppDatabase) {
        self.appDatabase = appDatabase
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    // MARK: - Opening notes

    /// Opens a floating panel for every note that was on screen at last quit (called at launch).
    func restoreAll() async {
        do {
            let notes = try await appDatabase.openNotes()
            for note in notes { openNote(note, makeKey: false) }   // launch: show, don't steal focus
            NSLog("[Tic] restored \(notes.count) note panel(s)")
        } catch {
            NSLog("[Tic] restoreAll failed: \(error)")
        }
    }

    /// Shows the panel for a note, creating it if necessary. `makeKey` brings it to key (so an
    /// interactive open from the menu bar focuses the note and dismisses the .window popover);
    /// pass `false` for launch restore so we don't yank focus.
    @discardableResult
    func openNote(_ note: Note, makeKey: Bool = true) -> NotePanel {
        if let existing = panels[note.id] {
            // A note already on screen: only an explicit, interactive open (makeKey) should pull it
            // forward and focus it. A background restore / MCP surface (makeKey: false) must NOT yank
            // focus from whatever app the user is in — previously this branch always made it key.
            if makeKey {
                hiddenByFilter.remove(note.id)
                existing.makeKeyAndOrderFront(nil)
            } else if hiddenByFilter.contains(note.id) {
                // Revealed by an explicit request while filtered out — restore it without focusing.
                hiddenByFilter.remove(note.id)
                existing.orderFront(nil)
            }
            return existing
        }
        if !note.isOpen {
            Task { [appDatabase] in try? await appDatabase.updateNoteOpen(id: note.id, isOpen: true) }
        }
        let controller = NoteController(note: note, database: appDatabase)
        controllers[note.id] = controller
        controller.start()

        let panel = NotePanel(note: note, content: AnyView(NoteView(controller: controller)))
        panels[note.id] = panel
        savedFrames[note.id] = CGRect(x: note.frameX, y: note.frameY, width: note.frameW, height: note.frameH)

        // Live-window side effects. Weak captures so the closures never keep the panel alive
        // past close (windowWillClose nils the controller, releasing them).
        controller.onApplyBehavior = { [weak panel] floatOnTop, showOnAllSpaces in
            panel?.apply(floatOnTop: floatOnTop, showOnAllSpaces: showOnAllSpaces)
        }
        controller.onClose = { [weak panel, appDatabase] in
            // Only the user's X marks a note closed (quit doesn't), so launch restores what was visible.
            Task { try? await appDatabase.updateNoteOpen(id: note.id, isOpen: false) }
            panel?.close()   // triggers windowWillClose → teardown; does NOT delete the note
        }
        controller.onSetCollapsed = { [weak self, weak panel] collapsed in
            guard let self, let panel else { return }
            self.setCollapsed(panel, collapsed: collapsed, animate: true)
        }
        controller.onNewNote = { [weak self] in
            Task { await self?.newNote() }
        }
        controller.onRemindersChanged = { [weak self] in self?.onRemindersChanged?() }
        controller.onSetCategory = { [weak self] categoryID in
            Task { [weak self] in
                guard let self else { return }
                try? await self.appDatabase.updateNoteCategory(id: note.id, categoryID: categoryID)
                // Re-reconcile: moving a note into a hidden category removes it from view; moving it
                // back restores it. Also reveal it if the new category is filtered out (a direct user
                // choice shouldn't make the note vanish without a trace).
                if let categoryID, self.categoryFilter.hides(categoryID: categoryID) {
                    self.revealNote(withCategory: categoryID)
                }
                await self.reconcileVisibility()
            }
        }
        controller.onOpenImage = { [weak self, weak controller, weak panel] taskId in
            guard let self, let controller, let panel else { return }
            self.showImageWindow(controller: controller, taskId: taskId, from: panel)
        }
        panel.onPasteImage = { [weak controller] data in
            controller?.stageImage(data)
        }

        place(panel)
        if makeKey {
            panel.makeKeyAndOrderFront(nil)   // become key → the menu bar popover resigns/dismisses
        } else {
            panel.orderFront(nil)
        }

        // A note saved in the rolled-up state opens rolled up (keeping its expanded height).
        if note.isCollapsed {
            setCollapsed(panel, collapsed: true, animate: false)
        }
        panel.delegate = self   // only now: the placement and roll-up above aren't user moves to persist
        // If the current filter excludes this note, drop it from view right away. The panel (and its
        // controller, position, collapse state, and `isOpen`) all stay — the filter only hides it.
        if applyFilterVisibility(to: panel, note: note, makeKey: makeKey) {
            return panel
        }
        return panel
    }

    /// Applies the current filter (and the Hide-All toggle) to one panel. Returns true when the panel
    /// was hidden (so the caller skips making it key). A restore (making a hidden note visible again)
    /// is presented without stealing focus — `openNote(makeKey: true)` is the explicit "I want it".
    @discardableResult
    private func applyFilterVisibility(to panel: NotePanel, note: Note, makeKey: Bool) -> Bool {
        let shouldShow = !temporarilyHideAll && !categoryFilter.hides(categoryID: note.categoryID)
        if shouldShow, hiddenByFilter.remove(note.id) != nil {
            panel.orderFront(nil)
        }
        if !shouldShow {
            hiddenByFilter.insert(note.id)
            panel.orderOut(nil)
            return true
        }
        return false
    }

    // MARK: - Category filter / visibility coordination

    /// Switches the active category filter and reconciles every live panel: matching notes come back,
    /// non-matching ones are order-out'd (keeping `isOpen` untouched). Applies silently — no focus.
    func applyCategoryFilter(_ filter: CategoryFilter) async {
        categoryFilter = filter
        await reconcileVisibility()
    }

    /// Sets the session-only "hide everything" toggle. Restoring re-shows exactly the notes that were
    /// on screen and match the filter — never a note the user had closed (`isOpen == false`).
    func setTemporarilyHideAll(_ hidden: Bool) async {
        guard hidden != temporarilyHideAll else { return }
        temporarilyHideAll = hidden
        await reconcileVisibility()
    }

    /// Brings a note into view for an explicit open: if the filter hid it, add its category to the
    /// visible set and make it visible. Returns true when the filter was adjusted.
    @discardableResult
    func revealNote(withCategory categoryID: UUID?) -> Bool {
        guard categoryFilter.hides(categoryID: categoryID) else { return false }
        var filter = categoryFilter
        filter.reveal(categoryID: categoryID)
        categoryFilter = filter
        return true
    }

    /// Recomputes which open notes should be on screen and order-fronts / order-outs panels to match.
    /// This is the single chokepoint: restore, filter changes, category edits, and MCP open/focus all
    /// route here rather than mutating `isOpen`. Only the *visible* set of panels is touched.
    func reconcileVisibility() async {
        do {
            let visible = try await appDatabase.openNotes(matching: categoryFilter)
            let visibleIDs = Set(visible.map(\.id))
            for (id, panel) in panels {
                let shouldShow = !temporarilyHideAll && visibleIDs.contains(id)
                if shouldShow {
                    if hiddenByFilter.remove(id) != nil {
                        panel.orderFront(nil)   // restore at its saved spot, without focusing
                    }
                } else {
                    hiddenByFilter.insert(id)
                    panel.orderOut(nil)
                }
            }
        } catch {
            NSLog("[Tic] reconcileVisibility failed: \(error)")
        }
    }

    /// Creates a fresh note (cascaded so it doesn't sit exactly on top of the last) and opens it.
    /// The DB assigns a unique, monotonic `sortIndex`; the cascade offset derives from that index
    /// (not the open-panel count), so placement and ordering stay stable after closes/deletes.
    /// The new note inherits the app-wide float/all-Spaces defaults and the current single selected
    /// category, and (like the plan's "actively created notes get focus") drops the caret in the title.
    func newNote() async {
        do {
            let defaults = newNoteDefaults
            var fresh = Note(
                color: NoteColor.allCases.randomElement() ?? .yellow,
                floatOnTop: defaults.floatOnTop,
                showOnAllSpaces: defaults.showOnAllSpaces
            )
            fresh.categoryID = newNoteCategoryID()
            let inserted = try await appDatabase.insertNewNote(fresh)
            let step = Double(inserted.sortIndex % 8) * 28
            var note = inserted
            note.frameX = 180 + step
            note.frameY = 320 - step
            try? await appDatabase.updateNoteFrame(
                id: note.id, x: note.frameX, y: note.frameY,
                width: note.frameW, height: note.frameH
            )
            let panel = openNote(note)
            // Actively created → take focus and let the user start typing the title right away.
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            controllers[note.id]?.requestTitleFocus()
        } catch {
            NSLog("[Tic] newNote failed: \(error)")
        }
    }

    /// Brings every *visible* open note to the front (menu-bar "Show All"). Filter-hidden notes are
    /// skipped — "Show All" fronts what's already on the desktop; it doesn't bypass the filter.
    func showAll() {
        for (id, panel) in panels where !hiddenByFilter.contains(id) { panel.orderFront(nil) }
    }

    /// Permanently deletes a note: closes its window if open (existing teardown), then removes
    /// the row (its tasks go with it via the FK cascade).
    func deleteNote(_ note: Note) async {
        do {
            try await appDatabase.deleteNote(id: note.id)
            hiddenByFilter.remove(note.id)
            panels[note.id]?.close()   // only tear down once the row is actually gone
        } catch {
            NSLog("[Tic] deleteNote failed: \(error)")
        }
    }

    /// Rolls a panel up to just its title bar (or back to its expanded height), keeping the top
    /// edge fixed. While collapsed the height is locked so it can't be resized into a sliver.
    private func setCollapsed(_ panel: NotePanel, collapsed: Bool, animate: Bool) {
        let id = panel.noteID
        let current = panel.frame
        let collapsedHeight = NoteLayout.collapsedHeight

        let targetHeight: CGFloat
        if collapsed {
            if current.height > collapsedHeight { expandedHeights[id] = current.height }
            targetHeight = collapsedHeight
            panel.minSize = NSSize(width: panel.minSize.width, height: collapsedHeight)
            panel.maxSize = NSSize(width: .greatestFiniteMagnitude, height: collapsedHeight)
        } else {
            targetHeight = expandedHeights[id] ?? max(current.height, 240)
            expandedHeights[id] = nil
            panel.minSize = NSSize(width: panel.minSize.width, height: 160)
            panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }

        let top = current.origin.y + current.height
        let newFrame = NSRect(
            x: current.origin.x, y: top - targetHeight,
            width: current.width, height: targetHeight
        )
        panel.setFrame(newFrame, display: true, animate: animate)
    }

    /// Puts a panel where its saved frame says, as long as some connected display shows it; otherwise
    /// parks it on the main display (nearest edge, same size). Runs at open and on every display
    /// change, so unplugging a monitor parks its notes and plugging it back returns them to the exact
    /// spot. Frames are global coordinates spanning all displays (as Stickies stores them), and this
    /// never persists: the saved frame stays the user's.
    private func place(_ panel: NotePanel) {
        guard let saved = savedFrames[panel.noteID], let main = NSScreen.main else { return }
        let target = Self.placement(for: saved, screens: NSScreen.screens.map(\.visibleFrame), main: main.visibleFrame)
        // Keep the live size (a rolled-up note sits at its collapsed height); align the top-left corner.
        placing = true
        panel.setFrameOrigin(NSPoint(x: target.minX, y: target.maxY - panel.frame.height))
        placing = false
    }

    /// `saved` itself when at least an 80×80 corner lies on one of `screens`; else `saved` shifted the
    /// shortest distance that fits it on `main` (a note taller than the screen keeps its top edge on).
    nonisolated static func placement(for saved: CGRect, screens: [CGRect], main: CGRect) -> CGRect {
        if isVisible(saved, onAnyOf: screens) { return saved }
        var frame = saved
        frame.origin.x = min(max(saved.minX, main.minX), main.maxX - saved.width)
        frame.origin.y = min(max(saved.minY, main.minY), main.maxY - saved.height)
        return frame
    }

    /// A display was plugged in, unplugged, or rearranged. macOS shoves windows off a vanished display
    /// onto a remaining one, which must not be saved as the user's choice: drop the moves it caused
    /// (already pending or still to come) and re-place every note from its saved frame.
    @objc private func screensDidChange() {
        // ponytail: a 2s blanket, since macOS moves windows within the same reconfiguration; a user drag
        // inside it is dropped — make it precise if that ever shows.
        suppressSavesUntil = Date().addingTimeInterval(2)
        for task in pendingFrameSaves.values { task.cancel() }
        pendingFrameSaves.removeAll()
        for panel in panels.values { place(panel) }
    }

    /// True when at least an 80×80 corner of `frame` lies on one of `screens` (enough to grab).
    nonisolated static func isVisible(_ frame: CGRect, onAnyOf screens: [CGRect]) -> Bool {
        screens.contains { screen in
            let overlap = screen.intersection(frame)
            return overlap.width >= 80 && overlap.height >= 80
        }
    }

    // MARK: - Image window

    /// Shows a task's image in the image window, creating the window on first use. It takes the note's
    /// window level, so it opens above a float-on-top note, and activates the app so it comes up in front.
    private func showImageWindow(controller: NoteController, taskId: UUID, from panel: NotePanel) {
        let window = imageWindow ?? ImageWindow()
        imageWindow = window
        imageWindowNoteID = controller.noteID
        let text = controller.tasks.first(where: { $0.id == taskId })?.text ?? ""
        window.title = text.split(separator: "\n").first.map(String.init) ?? "Image"
        window.contentView = NSHostingView(
            rootView: ImageViewer(controller: controller, taskId: taskId) { [weak window] in window?.close() }
        )
        window.level = panel.level
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    var openCount: Int { panels.count }

    // MARK: - Actions for external writers (MCP)

    /// Surfaces a note's panel, opening it from the DB if it wasn't on screen. Used when an agent
    /// creates a note or writes to a closed one — so the user sees the work. Uses
    /// `orderFrontRegardless` so a `.normal`-level note appears above other apps even while Tic is in
    /// the background, but does **not** activate Tic — the user's keyboard focus stays where it was.
    func openNoteByID(_ id: UUID) async {
        let panel: NotePanel
        if let existing = panels[id] {
            panel = existing
        } else {
            guard let note = try? await appDatabase.note(id: id) else { return }
            panel = openNote(note, makeKey: false)
        }
        // If the filter is hiding this note, reveal it (its category joins the visible set). This is a
        // *surfacing*, not a focus grab — restore it without activating.
        if hiddenByFilter.contains(id) {
            if let note = try? await appDatabase.note(id: id) { revealNote(withCategory: note.categoryID) }
            hiddenByFilter.remove(id)
        }
        panel.orderFrontRegardless()
    }

    /// Brings a note fully to the foreground: activates Tic and makes the note key, so it lands in
    /// front and ready to type in. The explicit "jump to this note" (the `focus_note` MCP tool),
    /// stronger than `openNoteByID` — this one does take focus.
    func focusNoteByID(_ id: UUID) async {
        let panel: NotePanel
        if let existing = panels[id] {
            panel = existing
        } else if let note = try? await appDatabase.note(id: id) {
            panel = openNote(note, makeKey: false)
        } else {
            return
        }
        // An explicit open honours the plan's rule: adjust the filter so the note is visible first.
        if hiddenByFilter.contains(id), let note = try? await appDatabase.note(id: id) {
            revealNote(withCategory: note.categoryID)
            hiddenByFilter.remove(id)
        }
        // A background app's plain activate() is refused by macOS focus-stealing prevention, so use
        // the assertive form (deprecated on 14 but still the only thing that reliably pulls focus
        // forward from another app). This is opt-in (focus_note / focus:true), never a plain write.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    /// Hides a note's panel (the agent equivalent of the header X): marks it closed and closes the
    /// window if it's open. A no-op beyond the DB write when nothing is on screen.
    func closeNoteByID(_ id: UUID) async {
        try? await appDatabase.updateNoteOpen(id: id, isOpen: false)
        panels[id]?.close()   // → windowWillClose tears down the controller/panel
    }

    /// Moves/resizes a note. If its panel is live, set the frame (the debounced save persists it,
    /// exactly like a user drag); otherwise persist the frame so `place` uses it when next opened.
    func setFrame(_ id: UUID, to rect: CGRect) async {
        if let panel = panels[id] {
            panel.setFrame(rect, display: true, animate: false)   // fires didMove/didResize → save
        } else {
            savedFrames[id] = rect
            try? await appDatabase.updateNoteFrame(
                id: id, x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height
            )
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) { scheduleFrameSave(notification) }
    func windowDidResize(_ notification: Notification) { scheduleFrameSave(notification) }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NotePanel else { return }
        if imageWindowNoteID == panel.noteID { imageWindow?.close() }
        pendingFrameSaves[panel.noteID]?.cancel()
        pendingFrameSaves[panel.noteID] = nil
        expandedHeights[panel.noteID] = nil
        savedFrames[panel.noteID] = nil
        hiddenByFilter.remove(panel.noteID)
        controllers[panel.noteID]?.stop()
        controllers[panel.noteID] = nil
        panels[panel.noteID] = nil
    }

    /// Debounced frame persistence — drag/resize fire continuously, so we save only after the
    /// gesture settles (300ms idle).
    private func scheduleFrameSave(_ notification: Notification) {
        guard let panel = notification.object as? NotePanel else { return }
        // Not a user move: our own placement, or macOS relocating windows around a display change.
        if placing || Date() < suppressSavesUntil { return }
        let id = panel.noteID
        let live = panel.frame

        // While rolled up, the window is at its collapsed height. Still persist position/width,
        // but keep the EXPANDED height in the DB and reconstruct the expanded top (collapse keeps
        // the top edge fixed) — otherwise a move/resize done while collapsed is lost on relaunch.
        let collapsed = controllers[id]?.note.isCollapsed == true
        let height = collapsed ? (expandedHeights[id] ?? live.height) : live.height
        let x = live.origin.x
        let y = collapsed ? (live.maxY - height) : live.origin.y
        let width = live.width
        savedFrames[id] = CGRect(x: x, y: y, width: width, height: height)

        pendingFrameSaves[id]?.cancel()
        pendingFrameSaves[id] = Task { [appDatabase] in
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            try? await appDatabase.updateNoteFrame(id: id, x: x, y: y, width: width, height: height)
        }
    }
}
