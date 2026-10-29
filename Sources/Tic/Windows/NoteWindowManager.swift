import AppKit
import SwiftUI

/// Owns the live `NotePanel`s — one per note — and keeps their on-screen frames in sync with
/// the database. Acts as each panel's window delegate.
@MainActor
final class NoteWindowManager: NSObject, NSWindowDelegate {
    private let appDatabase: AppDatabase
    private var panels: [UUID: NotePanel] = [:]
    private var controllers: [UUID: NoteController] = [:]

    /// The open notes' controllers (development test hooks read the list state through them).
    var openControllers: [NoteController] { Array(controllers.values) }
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
        observeOtherAppsFullScreen()
        observeClicksOutsideTic()
        observeSystemInterruptions()
    }

    // MARK: - Full-screen Spaces of other apps

    /// The displays another app is currently filling with a full-screen Space, in global
    /// coordinates. Unpinned notes *on those displays* are kept off the screen while it does — see
    /// `applyFullScreenPolicy`.
    ///
    /// Per display, not global: a full-screen app on the second monitor must not take the notes on
    /// the first one off the screen — they are on a different Space, and the user is looking at them.
    private(set) var fullScreenDisplays: [CGRect] = []

    /// Whether some other app currently has a window in full screen (on any display).
    var otherAppIsFullScreen: Bool { !fullScreenDisplays.isEmpty }

    /// Notes taken off the screen by the full-screen policy (as opposed to by the category filter).
    private(set) var hiddenForFullScreen: Set<UUID> = []

    /// Whether `id`'s note is off screen because another app is full screen.
    func isHiddenForFullScreen(_ id: UUID) -> Bool { hiddenForFullScreen.contains(id) }

    /// Notes the user deliberately summoned while another app was full screen (Tic's icon, or a list
    /// picked from the menu / Overview / the Lists palette). They stay visible — and editable — in
    /// that full-screen Space, above the full-screen app's content, instead of being taken off screen
    /// again by the policy a moment later. The user's next move is what ends it: clicking back into
    /// the full-screen app, or switching away from Tic (an app activating, or a Space change on the
    /// note's display). See `NotePanel.userSummoned`.
    private(set) var summonedWhileFullScreen: Set<UUID> = []

    /// Whether Tic itself is what the user is looking at — its menu was just opened, or a note (not
    /// the full-screen app) is being edited.
    var userIsInTic: Bool {
        NSApp.isActive || panels.values.contains { $0.isKeyWindow }
    }

    /// Lets go of every summoned note. Called as soon as the user goes back to the full-screen app.
    func releaseSummonedNotes() {
        guard !summonedWhileFullScreen.isEmpty else { return }
        let released = summonedWhileFullScreen
        summonedWhileFullScreen.removeAll()
        for id in released {
            panels[id]?.userSummoned = false
        }
        for id in released { panels[id]?.restToNormalLevelIfUnpinned() }
        // Back into the hands of the policy: anything on a full-screen display goes off screen now,
        // so it comes back by itself when the user returns to the desktop.
        applyFullScreenPolicy()
    }

    /// Called by every surface the user uses to bring Tic forward (menu bar, Overview, palette).
    /// Notes on a full-screen display are shown over it from here on — the user asked for exactly
    /// what is on screen.
    ///
    /// Only does anything while another app is full screen. Call it *before* activating the app
    /// (see `AppModel.noteUserReachedForTic`): activating first switches away from the full-screen
    /// Space; activating after keeps the user on it and lets the summoned note take the keyboard.
    func noteUserShow() {
        guard otherAppIsFullScreen else { return }
        markSummoned(onFullScreenDisplaysOnly: true)
    }

    /// When the click that summoned the notes was the Dock icon, the app has been brought forward
    /// but *not* the full-screen Space: macOS shows Tic's ordinary Space instead, so the full-screen
    /// app — and the notes that were just put over it — are not on screen at all.
    ///
    /// The fix is the same trick a pinned note uses to follow another app into full screen
    /// (`NotePanel.joinFullScreenSpace`): re-assert the panel while the full-screen Space is current
    /// and it is ordered *onto that Space*. Deferred a tick so the summon's ordering has landed.
    ///
    /// It says nothing about the Space itself: if macOS has already switched to the desktop (a Dock
    /// click spends a moment activating), the full-screen Space is no longer the current one and a
    /// re-assert can't bring it back — that has to be caught before anything activates Tic, at the
    /// Dock click itself (`NoteWindowManager.activateReturningToFullScreen`).
    ///
    /// `TIC_FS_DEBUG=1` logs which Space each display is on, and what Tic was called for, so a
    /// report of "it still jumps to the desktop" can be diagnosed from the log alone.
    func returnToSummonedFullScreenSpace() {
        let summoned = panels.values.filter { summonedWhileFullScreen.contains($0.noteID) }
        guard !summoned.isEmpty else { return }
        // What it is working against, so a log that is reported after the fact
        // (`TIC_FS_DEBUG=1` makes the 1 Hz sweep print too) can be read without guessing.
        let spaceTypes = Self.currentSpaceTypes()
            .map { "\($0.type)\($0.isFullScreen ? "f" : "")" }.joined(separator: ",")
        let active = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        NSLog("[Tic] dockClick: full=\(fullScreenDisplays.count) types=[\(spaceTypes)] "
              + "active=\(active) summoned=\(summoned.count)")
        // Captured by value: `weak` on an array is pointless, and the panels themselves are held by
        // the manager's `panels`, not by this closure.
        NSApp.activate()
        DispatchQueue.main.async {
            for panel in summoned where panel.userSummoned {
                if panel.isPinned { panel.joinFullScreenSpace() } else { panel.showAsUserCanvas() }
            }
        }
        NSLog("[Tic] dockClick: re-showed \(summoned.count) summoned note(s)")
    }

    /// Brings Tic forward from its Dock icon, in a way that can land back on the full-screen Space
    /// the click left.
    ///
    /// Two steps, because neither one alone is enough:
    /// 1. Activate *without* the app-raising prompt. The Dock's own route goes through asking the
    ///    window server to bring Tic forward, and with nothing of Tic's on the full-screen Space yet
    ///    that switches the display to Tic's ordinary desktop Space. A plain `activate()` on a
    ///    non-activating app is how this app already puts a pinned note into a full-screen Space
    ///    (`NotePanel.joinFullScreenSpace`, and `focusNoteByID`'s `activate(ignoringOtherApps: true)`
    ///    comment), so the Space the user is looking at should survive it.
    /// 2. Then re-assert the summoned notes, which orders them onto whichever Space is current —
    ///    putting Tic's windows on the full-screen Space rather than switching away from it.
    func activateReturningToFullScreen() {
        NSApp.activate()
        returnToSummonedFullScreenSpace()
    }

    /// Whether the notes a summon put on the full-screen Space are still wanted.
    ///
    /// Only two things end a summon, and both mean the user has truly gone back to the full-screen
    /// app: that app activating (see `releaseSummonedNotesIfUserLeftTic`), and the Space changing
    /// (see the observer in `observeOtherAppsFullScreen`). Keys and clicks inside Tic must not end
    /// it — the whole point is that the summoned note is *edited* while the app stays behind it; an
    /// earlier key monitor released the notes on the first keystroke typed into the note.

    /// Flags the unpinned notes on full-screen displays as summoned: the user asked to see what is
    /// on Tic right now, so those notes ride above the full-screen app until the user goes back to it.
    private func markSummoned(onFullScreenDisplaysOnly onlyOnFullScreen: Bool) {
        for (id, panel) in panels
        where !panel.isPinned && !hiddenByFilter.contains(id)
            && (!onlyOnFullScreen || isOnFullScreenDisplay(panel)) {
            summon(panel)
        }
    }

    /// One panel, onto the full-screen Space it sits on: gate open, above the app, editable.
    private func summon(_ panel: NotePanel) {
        panel.userSummoned = true
        summonedWhileFullScreen.insert(panel.noteID)
        hiddenForFullScreen.remove(panel.noteID)
        panel.applyFullScreenSuppression(false)
        panel.showAsUserCanvas()
    }

    /// The user picked one particular list (Recent, Overview, palette, Dock). If it sits on a
    /// full-screen display, it joins that Space above the full-screen app — visible and editable —
    /// rather than being held off screen by the policy.
    func summon(_ note: Note) {
        guard let panel = panels[note.id] else { return }
        if isOnFullScreenDisplay(panel) && !panel.isPinned {
            summon(panel)
        }
        markSummoned(onFullScreenDisplaysOnly: true)
    }

    /// Injection point for tests: replaces the live query, so the policy can be exercised without a
    /// real full-screen Space. `nil` = ask the system. Returns the full-screen displays (empty =
    /// none).
    internal var fullScreenProbe: (() -> [CGRect])?

    /// Injection point for tests: the displays this manager considers, in place of `NSScreen.screens`.
    internal var screenProbe: (() -> [CGRect])?

    /// Injection point for tests: a note's frame, in place of the live window's. A window server
    /// constrains a window to the displays actually attached (a test machine with one screen would
    /// clamp a note "on the second display" into the first), so the policy is exercised on the
    /// frames a test says the notes have.
    internal var panelFrameProbe: ((NotePanel) -> CGRect)?

    /// A note's frame as the policy sees it.
    func frame(of panel: NotePanel) -> CGRect {
        panelFrameProbe?(panel) ?? panel.frame
    }

    /// Injection point for tests: what each display's current Space is, without a real window server
    /// (`nil` = ask it).
    internal var spaceProbe: (() -> ScreenSpaces)?

    /// Re-evaluates the full-screen policy once a second (see `observeOtherAppsFullScreen`).
    private var fullScreenPoll: Timer?

    /// Watches for another app going (or coming back from) full screen: on app activation, on any
    /// window entering/leaving full screen, and once a second — a Space can change on a second
    /// display without the active app changing, and no notification covers every case.
    private func observeOtherAppsFullScreen() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                       as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in
                self?.releaseSummonedNotesIfUserLeftTic(activatedPID: pid)
                self?.applyFullScreenPolicy()
            }
        }
        // Drag on a desktop Space, or swipe to another one: the user has moved on from the notes
        // they summoned, even though no app activated.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.releaseSummonedNotes() }
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.applyFullScreenPolicy() }
            }
        }
        fullScreenPoll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyFullScreenPolicy() }
        }
    }

    /// Watches for the moments the window server may have dropped our panels — display sleep, the
    /// screen locking, the session becoming active again, the app returning to the foreground.
    ///
    /// A non-activating panel ordered out by the system (as sleep/lock do) is not ordered back by
    /// anything: Tic is not the active app, so nothing asks it to re-show. Without this the notes
    /// simply stay gone after the display wakes, which reads as "the notes disappear after a while".
    private func observeSystemInterruptions() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reshowLostNotes() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reshowLostNotes() }
        }
    }

    /// Watches for the user clicking somewhere that is not Tic.
    ///
    /// Going back to the full-screen app does not always come as an app activation: when Tic only
    /// holds non-activating panels, a click into the app behind them can be spent on making that
    /// app active again, so `didActivateApplicationNotification` fires late (or, after the notes
    /// took the keyboard, not at all) and the summoned notes stay on screen. The click itself is
    /// the reliable signal — it reached no window of ours, so the user is working in the app the
    /// notes cover.
    ///
    /// A *global* monitor (not local): clicks in Tic's own windows must never end a summon, and
    /// those are exactly the ones it doesn't see.
    private func observeClicksOutsideTic() {
        let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.otherAppClicked() }
        }
        // Held for the app's lifetime (see the property): a released monitor token stops delivering.
        outsideClickMonitor = monitor
    }

    /// The global mouse monitor. It lives as long as the app, and the manager does, so it is never
    /// removed — and `deinit` (nonisolated, and the token isn't Sendable) deliberately has nothing
    /// to do.
    private var outsideClickMonitor: Any?

    /// A click landed on another app. Tic itself activating is the manager's business, but while
    /// notes are summoned over a full-screen app, a click anywhere off Tic means the user has gone
    /// back to that app — the summon ends and the notes come off screen.
    func otherAppClicked() {
        releaseSummonedNotes()
    }

    /// Puts back on screen any note that should be shown but is not: the panel exists, no filter and
    /// no full-screen Space is holding it off, yet the window is ordered out.
    ///
    /// Deliberately conservative — it only re-orders a panel the system dropped, never one the user
    /// or a policy hid, and never raises anything (the note goes back where it belongs, in the
    /// background, exactly as on launch).
    func reshowLostNotes() {
        for (id, panel) in panels
        where !hiddenByFilter.contains(id) && !hiddenForFullScreen.contains(id)
            && !isOnFullScreenDisplay(panel) && panel.wasOrderedOut {
            panel.showInBackground(raise: false)
        }
    }

    /// Keeps unpinned notes out of another app's full-screen Space: hidden while it's up, back on
    /// their Space afterwards. Pinned notes are unaffected — being always visible is what the pin is
    /// for.
    ///
    /// The rule is *per display*: a note is only taken off screen if it sits on a display another app
    /// is filling with a full-screen Space. A full-screen app on the second monitor leaves the notes
    /// on the first one alone — they are on a different Space, and the user is looking at them.
    ///
    /// Idempotent, and safe to call at any moment: a panel put on screen *while* another app is full
    /// screen (opened by the user, by an agent, or restored) is taken off again here, not just at the
    /// moment the full-screen Space appears.
    /// Set `TIC_FS_DEBUG=1` to log what the full-screen policy sees and does on every sweep.
    static let fullScreenDebug = ProcessInfo.processInfo.environment["TIC_FS_DEBUG"] != nil

    /// One line per note: what the full-screen policy currently sees (for `TIC_FS_DEBUG` and the
    /// development test hooks).
    func debugState() -> String {
        let screenSpaces = currentScreenSpaces()
        let types = Self.currentSpaceTypes().map { "\(Int($0.frame.minX)):\($0.type)\($0.isFullScreen ? "f" : "")" }
            .joined(separator: ",")
        return "types=[\(types)] " + panels.values.map { panel -> String in
            let id = panel.noteID.uuidString.prefix(4)
            let display = display(of: panel).map { d in
                "desktop=\(screenSpaces?.showsDesktopSpace(d) == true ? 1 : 0)"
            } ?? "-"
            let f = frame(of: panel)
            return "\(id) [\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))] "
                + "pin=\(panel.isPinned ? 1 : 0) sup=\(panel.suppressedByFullScreen ? 1 : 0) "
                + "sum=\(panel.userSummoned ? 1 : 0) vis=\(panel.isVisible ? 1 : 0) "
                + "ord=\(panel.wasOrderedOut ? 1 : 0) onfs=\(isOnFullScreenDisplay(panel) ? 1 : 0) "
                + "lvl=\(panel.level.rawValue) \(display)"
        }.joined(separator: " | ")
    }

    func applyFullScreenPolicy() {
        setFullScreenDisplays(currentFullScreenDisplays())
        enforceFullScreenPolicy()
        if Self.fullScreenDebug {
            let state = debugState()
            NSLog("[FS] screens=\(displays().map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" }) full=\(fullScreenDisplays.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" }) %@",
                  state as NSString)
        }
        // The same once-a-second sweep notices a panel the system dropped (sleep, lock, a Space
        // switch): those events have no notification we can rely on, and a note that silently stayed
        // off screen is the one failure the user is sure to see.
        reshowLostNotes()
        // And a note that is no longer pinned, but is still on the full-screen Space (or on a desktop
        // Space the user has left), comes back to the desktop.
        moveToDesktopSpace()
    }

    /// Follows the user across Spaces. Unpinned notes belong to the ordinary desktop, so they live on
    /// the desktop's Space — not on another app's full-screen one, and not on a desktop Space the
    /// user has navigated away from.
    ///
    /// This matters most for a note *just unpinned while its display was full screen*: it has never
    /// been shown on an ordinary Space, so it knows no desktop to go back to. Unpinning it there
    /// leaves it on the full-screen Space (where the old rules don't apply to it any more) until
    /// something moves it — and the moment the user leaves that Space, it is off screen for good.
    ///
    /// Cheap enough for the once-a-second sweep: only panels that are on a full-screen display or
    /// not on the active Space do any work.
    func moveToDesktopSpace() {
        guard let screenSpaces = currentScreenSpaces() else { return }
        for (id, panel) in panels
        where !panel.isPinned && !panel.userSummoned && !hiddenByFilter.contains(id)
            && !hiddenForFullScreen.contains(id) {
            guard panel.wasOrderedOut, let display = display(of: panel) else { continue }
            // Not pinned, and the display is not on an ordinary desktop Space (another app's
            // full-screen Space, or a desktop Space the user has left): re-showing it now orders it
            // onto the Space that *is* current — the way this app shows any of its windows.
            if !screenSpaces.showsDesktopSpace(display) {
                panel.showInBackground(raise: false)
            }
        }
    }

    /// The display a panel mostly lies on, from this manager's point of view.
    private func display(of panel: NotePanel) -> CGRect? {
        let area = Self.area(of: frame(of: panel))
        guard area > 0 else { return nil }
        // The display the note covers most of. A note straddling two displays exactly in half has no
        // majority, so fall back to the first one it actually overlaps (rather than "none"), which
        // keeps it on a Space instead of making it belong nowhere.
        let displays = displays()
        if let majority = displays.first(where: { Self.intersectionArea(frame(of: panel), $0) > area * 0.5 }) {
            return majority
        }
        return displays.first { Self.intersectionArea(frame(of: panel), $0) > 0 }
    }

    /// The live query: the displays another app is showing a full-screen Space on right now.
    private func currentFullScreenDisplays() -> [CGRect] {
        if let probe = fullScreenProbe { return probe() }
        return queryFullScreenDisplays()
    }

    /// The displays notes may live on.
    func displays() -> [CGRect] {
        if let probe = screenProbe { return probe() }
        return Self.screens().map(\.frame)
    }

    /// Takes every unpinned panel *on a full-screen display* off screen — including panels shown
    /// since the last sweep (opened by the user, by an agent, or restored), and one **just unpinned**
    /// there (it was on the Space because the pin allowed it; the pin going away must take it off
    /// now, not on the next Space change). Panels remain live (controllers, text, `isOpen`); only the
    /// window is ordered out.
    func enforceFullScreenPolicy() {
        // Deliberately not gated on `otherAppIsFullScreen`: the full-screen Space may be *Tic's own*
        // (the user full-screens one of our windows — easy to do from the palette, and VS Code's
        // quick-open/command palettes front Tic while leaving their own Space up). Nothing else
        // re-hides the notes in that case, so an unpinned note kept sitting over Tic's full-screen
        // window, and — because its Space covers the desktop — looked "stuck" over the other app's
        // after that app came back.
        for (id, panel) in panels
        where !panel.isPinned && !panel.userSummoned && !hiddenByFilter.contains(id)
            && isOnFullScreenDisplay(panel) {

            hiddenForFullScreen.insert(id)
            // Idempotent: takes the panel off screen if it is still on it.
            panel.applyFullScreenSuppression(true)
        }
    }

    /// Whether the panel sits on a display another app is filling with a full-screen Space.
    ///
    /// Measured against the *note's* own area: a note belongs to the display it mostly lies on, not
    /// to the display that happens to be the biggest one it overlaps.
    func isOnFullScreenDisplay(_ panel: NotePanel) -> Bool {
        let panelArea = Self.area(of: frame(of: panel))
        guard panelArea > 0 else { return false }
        let fullScreen: [CGRect] = fullScreenDisplays
        return fullScreen.contains { (display: CGRect) -> Bool in
            // Mostly on it — or, with no majority (a note straddling the seam), partly on it and the
            // only display it overlaps at all.
            let overlap = Self.intersectionArea(frame(of: panel), display)
            if overlap > panelArea * 0.5 { return true }
            return overlap > 0 && fullScreen.count == 1 && self.display(of: panel) == display
        }
    }

    /// The frame of the display another app is currently filling with a full-screen window, if any.
    /// Accessibility's answer wins; the geometric guess is the fallback when nothing could be read.
    private func fullScreenDisplay() -> CGRect? {
        accessibilityScreenFullScreenDisplay() ?? geometricallyFullScreenDisplay()
    }

    /// Applies a new "another app is full screen" state. Split out so it can be exercised without a
    /// real full-screen Space.
    ///
    /// Leaving full screen is a two-step: the probe that first says "desktop" only re-opens the
    /// panels' gate, and the notes come back when the *next* probe agrees. A full-screen Space can
    /// report itself as an ordinary one for a tick while it's still animating (or while the system
    /// rolls back an attempted switch), and a note restored on that tick would sit over the
    /// full-screen app.
    private func setFullScreenDisplays(_ displays: [CGRect]) {
        // Whatever "full screen" means here, it can't have arrived *silently*: on every tick this
        // manager re-orders every unpinned note off screen, which would turn a note the user closed
        // back into one on screen when the full-screen app goes away. If the panel is gone, that
        // note's place is not ours to restore.
        restoreOnlyPanelsStillOpen()
        let isFullScreen = !displays.isEmpty
        let displaysChanged = displays != fullScreenDisplays
        fullScreenDisplays = displays

        // The panels' own gate, for shows that don't route through this manager, and the hold on the
        // notes that sit on a full-screen display.
        updatePanelSuppression()
        enforceFullScreenPolicy()
        updatePanelSuppression()

        if isFullScreen {
            // A pinned note was shown while its display was an ordinary desktop, and the app went
            // full screen over it: it stays on the desktop's Space unless it is put on the
            // full-screen one now. Pinned notes want to be seen there — that is what the pin is for.
            //
            // Done once per note per full-screen visit (`raisedPinned`), not on every sweep: doing
            // it unconditionally re-ordered and re-raised each pinned note once a second, which
            // made a pinned note flicker while an app was full screen.
            for panel in panels.values
            where panel.isPinned && self.isOnFullScreenDisplay(panel)
                && raisedPinned.insert(panel.noteID).inserted {
                panel.showInBackground(raise: false)
            }
            // Everything in the window list is now above the app's newly-made full-screen window.
            // Notes that were already up (pinned ones) must reclaim the top, or a note shown later
            // covers them.
            if displaysChanged { bringPinnedNotesToFront() }
        } else {
            raisedPinned.removeAll()
        }

        if isFullScreen {
            // The full-screen app may have moved to *another* display: the notes it left behind are
            // free again, and must not stay off screen for good.
            restoreNotesOffFullScreenDisplays()
            // Leaving and re-entering full screen cancels the pending restore (see below).
            pendingRestore = false
            return
        }
        if displaysChanged {
            // Leaving full screen: the notes stay off screen for now. They come back on the next
            // sweep, once a fresh probe agrees the full-screen Space is really gone (see below).
            pendingRestore = true
            return
        }
        // Unchanged, and nothing full screen: a fresh probe confirms it — put the notes back.
        guard pendingRestore else { return }
        pendingRestore = false
        restoreNotes()
    }

    /// Another app came to the front: if it isn't Tic, the user has gone back to it, so the notes
    /// they summoned over it step back out of the way. (Tic activating itself — a menu opening, a
    /// note clicked — is not "leaving".)
    private func releaseSummonedNotesIfUserLeftTic(activatedPID: pid_t?) {
        guard !summonedWhileFullScreen.isEmpty, let activatedPID else { return }
        guard activatedPID != ProcessInfo.processInfo.processIdentifier else { return }
        releaseSummonedNotes()
    }

    /// Puts the pinned notes back on top of everything else this app shows, in a stable order.
    private func bringPinnedNotesToFront() {
        for panel in panels.values.sorted(by: { $0.noteID.uuidString < $1.noteID.uuidString })
        where panel.isPinned {
            panel.raiseRegardless()
            panel.joinFullScreenSpace()
        }
    }

    /// The pinned notes already put onto the full-screen Space during this visit. A note leaves the
    /// set when it is pinned/unpinned, shown again, or the full screen goes away, so it can be put
    /// back when that happens — but not once a second while nothing changes.
    private var raisedPinned: Set<UUID> = []

    /// Whether the last sweep saw the full-screen Space go away and is waiting for a second,
    /// agreeing reading before it puts the notes back.
    private var pendingRestore = false

    /// Each panel's own gate, per panel: only the notes on a full-screen display are held off the
    /// screen — a note on the other display is untouched.
    private func updatePanelSuppression() {
        // Only the notes the policy actually holds off screen. A pinned note is never suppressed —
        // it belongs on the full-screen Space — and passing it through here made the two sides
        // fight: the sweep suppressed it, the pinned-note pass re-showed it, once a second, and the
        // note visibly flickered.
        for panel in panels.values where !panel.userSummoned {
            panel.applyFullScreenSuppression(shouldSuppress(panel))
        }
    }

    /// Whether the full-screen policy holds this note off screen: it is unpinned, not summoned, and
    /// sits on the display an app is filling with a full-screen Space. A pinned note is never held —
    /// being seen over the full-screen app is what the pin is for.
    private func shouldSuppress(_ panel: NotePanel) -> Bool {
        !panel.isPinned && !panel.userSummoned && isOnFullScreenDisplay(panel)
    }

    /// Drops from the restore set any note whose panel has since closed (the user's X, a category
    /// change). The closed note keeps its own "not open" record; it must not be re-shown by a sweep.
    private func restoreOnlyPanelsStillOpen() {
        raisedPinned.formIntersection(panels.keys)
        guard !hiddenForFullScreen.isEmpty else { return }
        hiddenForFullScreen.formIntersection(panels.keys)
    }

    /// Puts back the notes the full-screen policy took off screen, each at the level its pin calls for.
    private func restoreNotes() {
        let restore = hiddenForFullScreen
        hiddenForFullScreen.removeAll()
        for id in restore where panels[id] != nil && !hiddenByFilter.contains(id) {
            panels[id]?.applyFullScreenSuppression(false)
            panels[id]?.showInBackground(raise: false)
        }
    }

    /// Puts back the notes that are no longer behind a full-screen Space — the full-screen app moved
    /// to another display, or it left the display the note was on.
    private func restoreNotesOffFullScreenDisplays() {
        guard !hiddenForFullScreen.isEmpty else { return }
        for id in hiddenForFullScreen {
            guard let panel = panels[id], !isOnFullScreenDisplay(panel) else { continue }
            hiddenForFullScreen.remove(id)
            panel.applyFullScreenSuppression(false)
            panel.showInBackground(raise: false)
        }
    }

    /// Clears the "already put on the full-screen Space" bookkeeping. Used by tests, which register
    /// bare panels and so never run the `onApplyBehavior` that does this in the app.
    internal func forgetRaisedPinnedForTesting() {
        raisedPinned.removeAll()
    }

    /// Adds an already-built panel to the managed set. Used by tests; `openNote` is the production
    /// entry point.
    internal func register(_ panel: NotePanel) {
        panels[panel.noteID] = panel
    }

    /// Marks notes as hidden by the category filter (the state a real filter change sets up).
    internal func hideByFilterForTesting(_ ids: Set<UUID>) {
        hiddenByFilter.formUnion(ids)
    }

    /// Drops a closed panel from the managed set, the way `windowWillClose` does in the app. Used by
    /// tests, which register panels without a controller behind them.
    internal func unregisterForTesting(_ id: UUID) {
        panels[id] = nil
    }

    /// Ask the system (via Accessibility) which display another app's full-screen window fills.
    ///
    /// `AXFullScreen` is the authoritative flag — window bounds can't tell a full-screen window from
    /// one merely sized to the display (VS Code reports the same bounds either way, and a singular
    /// app's focused window isn't necessarily the full-screen one).
    ///
    /// Candidates are the apps with a layer-0 window in the on-screen window list — a window that
    /// isn't on screen is never full screen, and other Spaces' windows can be missing from
    /// `AXWindows`. Each app's windows are then checked: `AXFullScreen` on, and a frame covering
    /// (90% of) one of our displays — the app may be full screen on any display, not the focused one.
    ///
    /// Returns `nil` when nothing could be read (no Accessibility permission, typically), so the
    /// caller can fall back to `geometricallyFullScreenDisplay`. `.zero` says "full screen, but its
    /// window wasn't in the on-screen list — display unknown", which only counts as an answer when
    /// nothing at all could be read.
    private func accessibilityScreenFullScreenDisplay() -> CGRect? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let screens = displays().map { (frame: $0, visibleFrame: $0) }
        // Apps with at least one layer-0 window in the current Space, front to back.
        var candidates: [pid_t] = []
        var seen = Set<pid_t>()
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  (info[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  seen.insert(pid).inserted
            else { continue }
            candidates.append(pid)
        }
        var readableWindows = 0
        var unreadableApps = 0
        for candidate in candidates {
            let element = AXUIElementCreateApplication(candidate)
            var windows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows)
                    == .success, let windows = windows as? [AXUIElement] else {
                unreadableApps += 1
                continue
            }
            for window in windows {
                var position: CFTypeRef?, size: CFTypeRef?, flag: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position)
                        == .success,
                      AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size)
                        == .success,
                      AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &flag)
                        == .success, let isFullScreen = flag as? Bool
                else { continue }
                readableWindows += 1
                var origin = CGPoint.zero, extent = CGSize.zero
                AXValueGetValue(position as! AXValue, .cgPoint, &origin)
                AXValueGetValue(size as! AXValue, .cgSize, &extent)
                let frame = CGRect(origin: origin, size: extent)
                guard isFullScreen else { continue }
                if let display = screens.first(where: {
                    Self.intersectionArea(frame, $0.frame) >= Self.area(of: $0.frame) * 0.9
                })?.frame {
                    return display
                }
            }
        }
        // Nothing readable: no permission, or every app refused — the geometric guess is all we have.
        guard readableWindows > 0 || unreadableApps == 0 else { return nil }
        return .zero
    }

    private static func screens() -> [(frame: CGRect, visibleFrame: CGRect)] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID else { return nil }
            return (frame: CGDisplayBounds(number), visibleFrame: screen.visibleFrame)
        }
    }

    /// The display a full-screen app is filling, if any — asked of the window server, which knows
    /// each display's current Space. Window bounds can't substitute for it: on a display with no
    /// menu-bar/Dock reserves a maximised window fills the frame exactly like a full-screen one.
    private func geometricallyFullScreenDisplay() -> CGRect? {
        queryFullScreenDisplays().first
    }

    /// The displays another app is filling with a full-screen Space right now — one window-server
    /// query, safe to run every second. An unreadable snapshot (e.g. while the display sleeps) yields
    /// nothing, which the caller must not mistake for "the full-screen Space is gone".
    func queryFullScreenDisplays() -> [CGRect] {
        guard let screenSpaces = Self.screenSpaces() else { return [] }
        let displays = displays()
        return displays.filter(screenSpaces.showsFullScreenApp)
    }

    /// "Is this display showing a full-screen app's Space?" from the window server, for the
    /// geometric fallback. `nil` = couldn't read.
    ///
    /// A full-screen Space is a Space of its own: its display's current Space is marked `type: 4` and
    /// names the window (`fs_wid`) and app (`pid`) filling it. A maximised window leaves its display
    /// on the ordinary Space (`type: 0`) — the very distinction window bounds can't make.
    struct ScreenSpaces {
        /// Whether `display` is currently showing a full-screen app's Space.
        var showsFullScreenApp: (CGRect) -> Bool
        /// Whether `display` is currently on one of the user's ordinary desktop Spaces.
        var showsDesktopSpace: (CGRect) -> Bool
    }

    /// What each display's current Space is, honouring the tests' stand-in when there is one.
    private func currentScreenSpaces() -> ScreenSpaces? {
        spaceProbe?() ?? Self.screenSpaces()
    }

    /// Every display's current Space type, straight from the window server (debug logging only).
    private static func currentSpaceTypes() -> [(frame: CGRect, type: Int, isFullScreen: Bool)] {
        guard let connect = SkyLight.connect, let copySpaces = SkyLight.copySpaces,
              let displays = copySpaces(connect()) as? [[String: Any]]
        else { return [] }
        return displays.compactMap { display in
            guard let space = display["Current Space"] as? [String: Any],
                  let type = (space["type"] as? NSNumber)?.intValue,
                  let uuid = display["Display Identifier"] as? String,
                  let frame = displayFrame(uuid: uuid)
            else { return nil }
            return (frame, type, type == 4 && space["fs_wid"] != nil)
        }
    }

    static func screenSpaces() -> ScreenSpaces? {
        guard let connect = SkyLight.connect, let copySpaces = SkyLight.copySpaces,
              let displays = copySpaces(connect()) as? [[String: Any]]
        else { return nil }
        // Per display: its frame and the type of the Space showing on it right now.
        let current: [(frame: CGRect, type: Int, isFullScreen: Bool)] = displays.compactMap { display in
            guard let space = display["Current Space"] as? [String: Any],
                  let type = (space["type"] as? NSNumber)?.intValue,
                  let uuid = display["Display Identifier"] as? String,
                  let frame = Self.displayFrame(uuid: uuid)
            else { return nil }
            return (frame, type, type == 4 && space["fs_wid"] != nil)
        }
        return ScreenSpaces(
            showsFullScreenApp: { display in
                current.contains { $0.isFullScreen && $0.frame.equalTo(display) }
            },
            // `type: 0` is an ordinary desktop Space; anything else (full screen, or a transitional
            // state we can't name) is not.
            showsDesktopSpace: { display in
                current.contains { $0.type == 0 && $0.frame.equalTo(display) }
            }
        )
    }

    /// The frame of the display whose window-server UUID is `uuid` (NSScreen's device description
    /// carries the same publisher/name as `display=<UUID>`).
    private static func displayFrame(uuid: String) -> CGRect? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID,
                  let cfUUID = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
            else { return false }
            return (CFUUIDCreateString(nil, cfUUID) as String?) == uuid
        }.map { screen -> CGRect in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID else { return screen.frame }
            return CGDisplayBounds(number)
        }
    }

    /// The private window-server query this needs, resolved at runtime; missing on another macOS,
    /// in which case `screenSpaces` returns `nil`.
    private enum SkyLight {
        typealias Connect = @convention(c) () -> Int32
        typealias CopySpaces = @convention(c) (Int32) -> CFArray?

        nonisolated(unsafe) static let coreGraphics = dlopen(nil, RTLD_LAZY)
        nonisolated(unsafe) static let framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

        static func load<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _ type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }

        static let connect: Connect? = load(coreGraphics, "CGSMainConnectionID", Connect.self)
        static let copySpaces: CopySpaces? = load(framework, "SLSCopyManagedDisplaySpaces", CopySpaces.self)
    }

    nonisolated private static func area(of rect: CGRect) -> CGFloat { rect.width * rect.height }
    nonisolated private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    // MARK: - Opening notes

    /// Opens a floating panel for every note that was on screen at last quit (called at launch).
    func restoreAll() async {
        do {
            let notes = try await appDatabase.openNotes()
            // Launch: show, don't steal focus — or raise the notes over whatever was frontmost.
            for note in notes { openNote(note, makeKey: false, raise: false) }
            NSLog("[Tic] restored \(notes.count) note panel(s)")
        } catch {
            NSLog("[Tic] restoreAll failed: \(error)")
        }
    }

    /// Shows the panel for a note, creating it if necessary. `makeKey` brings it to key (so an
    /// interactive open from the menu bar focuses the note and dismisses the .window popover);
    /// pass `false` for launch restore so we don't yank focus. Anything short of `makeKey` is a
    /// *background* surface: it shows the note but never raises it above what the user is working in
    /// (`raise: false`).
    @discardableResult
    func openNote(_ note: Note, makeKey: Bool = true, raise: Bool = true) -> NotePanel {
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
                existing.showInBackground(raise: raise)
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
        // A note opened while another app is full screen stays off screen — but only if it is on the
        // display that is full screen (see `isOnFullScreenDisplay`), and never if it is pinned: a
        // pinned note belongs on that Space.
        panel.applyFullScreenSuppression(shouldSuppress(panel))
        savedFrames[note.id] = CGRect(x: note.frameX, y: note.frameY, width: note.frameW, height: note.frameH)

        // Live-window side effects. Weak captures so the closures never keep the panel alive
        // past close (windowWillClose nils the controller, releasing them).
        controller.onApplyBehavior = { [weak self, weak panel] floatOnTop, showOnAllSpaces in
            panel?.apply(floatOnTop: floatOnTop, showOnAllSpaces: showOnAllSpaces)
            // Pinning (or unpinning) is a new "this note belongs on the full-screen Space" event:
            // forget the visit's bookkeeping so the policy below puts a just-pinned note there.
            if let id = panel?.noteID { self?.raisedPinned.remove(id) }
        }
        controller.onWindowBehaviorChanged = { [weak self] in self?.applyFullScreenPolicy() }
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
        // Opened while another app is in full screen: an unpinned note must stay out of sight until
        // that Space goes away (its panel still exists — closing it would remember "closed").
        applyFullScreenPolicy()
        if makeKey {
            panel.makeKeyAndOrderFront(nil)   // become key → the menu bar popover resigns/dismisses
        } else {
            // Launch restore / background surfacing: show, don't raise above other apps.
            panel.showInBackground(raise: raise)
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

    /// Puts a note back on screen at the level its pin calls for. Going through the manager (rather
    /// than each caller ordering the panel itself) keeps the note out of another app's full-screen
    /// Space: the panel declines to show while the full-screen policy holds it off.
    private func show(_ panel: NotePanel, raise: Bool) {
        panel.level = panel.isPinned ? .floating : .normal
        panel.showInBackground(raise: raise)
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
                        // Restore at its saved spot, without focusing — and without raising it above
                        // whatever the user is working in.
                        show(panel, raise: false)
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
            panel = openNote(note, makeKey: false, raise: false)
        }
        // If the filter is hiding this note, reveal it (its category joins the visible set). This is a
        // *surfacing*, not a focus grab — restore it without activating.
        if hiddenByFilter.contains(id) {
            if let note = try? await appDatabase.note(id: id) { revealNote(withCategory: note.categoryID) }
            hiddenByFilter.remove(id)
        }
        panel.showInBackground(raise: false)
    }

    /// Brings a note fully to the foreground: activates Tic and makes the note key, so it lands in
    /// front and ready to type in. The explicit "jump to this note" (the `focus_note` MCP tool),
    /// stronger than `openNoteByID` — this one does take focus.
    func focusNoteByID(_ id: UUID) async {
        let panel: NotePanel
        if let existing = panels[id] {
            panel = existing
        } else if let note = try? await appDatabase.note(id: id) {
            panel = openNote(note, makeKey: false, raise: false)
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
        panel.raiseRegardless()   // an explicit focus request outranks being unpinned
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
