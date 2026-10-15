import AppKit
import UserNotifications

/// App lifecycle owner. As a plain SwiftPM executable (no .app bundle yet) we must explicitly
/// adopt a regular activation policy so Tic gets a Dock icon and can take foreground focus.
/// All real state lives in `AppModel.shared`; this just sequences launch and the Dock menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var newNoteKeyMonitor: Any?
    private let notificationRouter = NotificationRouterDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task { await AppModel.shared.bootstrap() }
        installNewNoteShortcut()
        installReminderObservers()
        // Update banners + task reminders share one router delegate. `current()` throws without a
        // bundle id (swift run), so both are guarded.
        if Bundle.main.bundleIdentifier != nil {
            NotificationRouter.registerCategories()
            wireNotificationRouter()
            UNUserNotificationCenter.current().delegate = notificationRouter
        }
    }

    /// Points the router's callbacks at the app's reminder/window actions.
    private func wireNotificationRouter() {
        notificationRouter.onOpenUpdate = { [weak self] in
            self?.handleUpdateTap()
        }
        notificationRouter.onOpenTask = { [weak self] taskID, noteID, revision in
            Task { @MainActor in await self?.handleReminderOpen(taskID: taskID, noteID: noteID, revision: revision) }
        }
        notificationRouter.onCompleteTask = { [weak self] taskID, revision in
            Task { @MainActor in await self?.handleReminderComplete(taskID: taskID, revision: revision) }
        }
        notificationRouter.onSnoozeTask = { [weak self] taskID, revision in
            Task { @MainActor in await self?.handleReminderSnooze(taskID: taskID, revision: revision) }
        }
    }

    /// Reconcile reminders when the display wakes (a laptop may have slept through a fire time) and
    /// when the timezone changes (a stored instant now maps to a different local wall-clock).
    private func installReminderObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppModel.shared.reconcileReminders() }
        }
        NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AppModel.shared.reconcileReminders() }
        }
    }

    // MARK: - Notification actions

    private func handleUpdateTap() {
        AppModel.shared.updates.openReleasePage()
    }

    /// "Open Note" (or a plain tap). The payload is re-read against the DB: a reminder whose task was
    /// completed/removed, or whose revision is stale, is ignored rather than opening stale UI.
    private func handleReminderOpen(taskID: UUID, noteID: UUID, revision: Int) async {
        await validateAndAct(taskID: taskID, revision: revision) { _ in
            await AppModel.shared.windows.focusNoteByID(noteID)
        }
    }

    private func handleReminderComplete(taskID: UUID, revision: Int) async {
        await validateAndAct(taskID: taskID, revision: revision) { task in
            await AppModel.shared.completeTaskFromReminder(taskID: task.id)
        }
    }

    private func handleReminderSnooze(taskID: UUID, revision: Int) async {
        await validateAndAct(taskID: taskID, revision: revision) { _ in
            await AppModel.shared.reminders.snooze(taskID: taskID)
        }
    }

    /// Runs `action` only when the reminder's task still exists, is unfinished, and the notification's
    /// revision still matches the current one — so an old notification can't revive a done/deleted task
    /// or a rescheduled one.
    private func validateAndAct(
        taskID: UUID, revision: Int, _ action: (TaskItem) async -> Void
    ) async {
        guard let task = try? await AppModel.shared.database.task(id: taskID), !task.isDone else { return }
        if let reminder = try? await AppModel.shared.database.reminder(taskID: taskID),
           reminder.revision != revision {
            return   // superseded by a newer change
        }
        await action(task)
    }

    /// ⌘N → New Note, ⌘O → Overview while Tic is the active app. A menu-style `MenuBarExtra`
    /// button's `keyboardShortcut` only fires while that menu is open, so we dispatch these
    /// ourselves via a local key monitor (fires whenever any Tic window is key).
    private func installNewNoteShortcut() {
        newNoteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Membership test (not == .command) so Caps Lock / Fn in the flags don't break it,
            // and case-insensitive so "N"/"O" under Caps Lock still match.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command),
                  !flags.contains(.shift), !flags.contains(.option), !flags.contains(.control) else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "n":
                Task { @MainActor in AppModel.shared.newNote() }
                return nil   // consume
            case "o":
                Task { @MainActor in AppModel.shared.openOverview() }
                return nil   // consume
            default:
                return event
            }
        }
    }

    /// Click the Dock icon with no notes on screen → open the Overview, so the app never looks
    /// dead after every note was closed and there's one obvious place to pick what to bring back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if AppModel.shared.windows.openCount == 0 { AppModel.shared.openOverview() }
        return true
    }

    /// Right-click the Dock icon → New List, Overview.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let newItem = NSMenuItem(title: "New List", action: #selector(newListFromDock), keyEquivalent: "")
        newItem.target = self
        menu.addItem(newItem)
        let overviewItem = NSMenuItem(title: "Overview", action: #selector(overviewFromDock), keyEquivalent: "")
        overviewItem.target = self
        menu.addItem(overviewItem)
        return menu
    }

    @objc private func newListFromDock() {
        AppModel.shared.newNote()
    }

    @objc private func overviewFromDock() {
        AppModel.shared.openOverview()
    }
}

// Notification presentation + click/action routing is owned by `NotificationRouterDelegate`
// (services/NotificationRouter.swift), shared by the update banner and task reminders.
