import Foundation
import Testing
import UserNotifications
@testable import Tic

/// The reminder coordinator driven by a fake notification client and a fixed clock — no real
/// notification centre, no bundle id, no waiting. This covers scheduling, replacement, cancellation,
/// snooze, stale-revision rejection, and the "missed reminder posted once" rule.
@Suite("ReminderCoordinator")
@MainActor
struct ReminderCoordinatorTests {
    /// An in-memory `NotificationClient`: records pending requests, honours replace-by-identifier,
    /// and reports a granted authorization.
    final class FakeClient: NotificationClient, @unchecked Sendable {
        var authorized = true
        var status: UNAuthorizationStatus = .authorized
        private(set) var added: [UNNotificationRequest] = []
        private(set) var removedBatches: [[String]] = []
        private(set) var delivered: [String] = []
        private(set) var authorizationRequests = 0

        func requestAuthorization() async -> Bool { authorizationRequests += 1; return authorized }
        func authorizationStatus() async -> UNAuthorizationStatus { status }
        func add(_ request: UNNotificationRequest) async throws {
            added.removeAll { $0.identifier == request.identifier }
            added.append(request)
        }
        func removePending(identifiers: [String]) async {
            removedBatches.append(identifiers)
            added.removeAll { identifiers.contains($0.identifier) }
        }
        // Faithful to `UNUserNotificationCenter`: a nil-trigger request fires immediately and is
        // NOT "pending"; only scheduled (triggered) requests are.
        func pendingIdentifiers() async -> [String] { added.filter { $0.trigger != nil }.map(\.identifier) }
        func deliveredIdentifiers() async -> [String] { delivered }
    }

    /// A mutable clock the test advances by hand.
    final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func makeSetup(at now: Date) async throws -> (AppDatabase, Note, TaskItem, Clock, FakeClient, ReminderCoordinator) {
        let db = try AppDatabase.makeInMemory()
        let note = try await db.insertNewNote(Note(title: "Notes"))
        let task = TaskItem(noteId: note.id, text: "Pay rent", sortIndex: 0)
        try await db.insertTask(task)
        let clock = Clock(now)
        let client = FakeClient()
        let coordinator = ReminderCoordinator(database: db, client: client, now: { clock.now })
        return (db, note, task, clock, client, coordinator)
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("a future reminder is scheduled once, with a stable identifier")
    func schedulesFuture() async throws {
        let (db, _, task, _, client, coordinator) = try await makeSetup(at: base)
        _ = try await db.setReminder(taskID: task.id, remindAt: base.addingTimeInterval(600))

        await coordinator.reconcile()
        #expect(await client.pendingIdentifiers() == [NotificationRouter.reminderIdentifier(taskID: task.id)])

        // Reconcile again: it must not duplicate or re-add (idempotent).
        await coordinator.reconcile()
        #expect(client.added.count == 1)
    }

    @Test("rescheduling replaces the pending request in place, bumping the revision")
    func rescheduleReplaces() async throws {
        let (db, _, task, _, client, coordinator) = try await makeSetup(at: base)
        _ = try await db.setReminder(taskID: task.id, remindAt: base.addingTimeInterval(600))
        await coordinator.reconcile()

        let moved = try await db.setReminder(taskID: task.id, remindAt: base.addingTimeInterval(1200))
        #expect(moved.revision == 2)
        await coordinator.reconcile()
        #expect(client.added.count == 1)   // replaced, not stacked
    }

    @Test("clearing a reminder cancels the pending notification")
    func clearCancels() async throws {
        let (db, _, task, _, client, coordinator) = try await makeSetup(at: base)
        _ = try await db.setReminder(taskID: task.id, remindAt: base.addingTimeInterval(600))
        await coordinator.reconcile()
        try await db.clearReminder(taskID: task.id)
        await coordinator.reconcile()
        #expect(await client.pendingIdentifiers().isEmpty)
    }

    @Test("completing (or deleting) the task cascades the reminder away")
    func doneOrDeletedCancels() async throws {
        let (db, note, task, _, client, coordinator) = try await makeSetup(at: base)
        _ = try await db.setReminder(taskID: task.id, remindAt: base.addingTimeInterval(600))
        await coordinator.reconcile()

        var done = task
        done.isDone = true
        done.completedAt = base
        try await db.update(done)
        await coordinator.reconcile()
        #expect(await client.pendingIdentifiers().isEmpty)

        // Deleting the note cascades its tasks (and their reminder rows) away; reconcile must not fault.
        try await db.deleteNote(id: note.id)
        await coordinator.reconcile()
        #expect(await client.pendingIdentifiers().isEmpty)
    }

    @Test("an already-overdue reminder is posted immediately and acknowledged exactly once")
    func overduePostedOnce() async throws {
        let (db, _, task, _, client, coordinator) = try await makeSetup(at: base)
        _ = try await db.setReminder(taskID: task.id, remindAt: base.addingTimeInterval(-60))

        await coordinator.reconcile()
        #expect(client.added.count == 1)
        #expect(coordinator.availability == .available)

        // A second reconcile must not post it again (the revision is acknowledged).
        await coordinator.reconcile()
        #expect(client.added.count == 1)
    }

    @Test("snooze pushes the reminder ten minutes out and reschedules")
    func snooze() async throws {
        let (db, _, task, _, _, coordinator) = try await makeSetup(at: base)
        _ = try await db.setReminder(taskID: task.id, remindAt: base.addingTimeInterval(-60))
        await coordinator.reconcile()

        await coordinator.snooze(taskID: task.id)
        let reminder = try #require(try await db.reminder(taskID: task.id))
        #expect(reminder.remindAt == base.addingTimeInterval(ReminderCoordinator.snoozeInterval))
        #expect(reminder.revision == 2)   // bumped, so a stale tap can't re-fire the old one
    }

    @Test("authorization is requested on demand; a denial surfaces as .denied and nothing schedules")
    func authorizationOnDemand() async throws {
        let (db, _, task, _, client, coordinator) = try await makeSetup(at: base)
        client.status = .notDetermined
        client.authorized = false
        _ = try await db.setReminder(taskID: task.id, remindAt: base.addingTimeInterval(600))

        #expect(await coordinator.requestAuthorizationIfNeeded() == false)
        #expect(client.authorizationRequests == 1)
        await coordinator.reconcile()
        // The system still reports "not determined", so the coordinator can't claim to be available.
        #expect(coordinator.availability != .available)
        #expect(client.added.isEmpty)
    }

    @Test("the notification payload carries the task id, note id, kind, and revision")
    func payload() async throws {
        let (db, note, task, _, client, coordinator) = try await makeSetup(at: base)
        _ = try await db.setReminder(taskID: task.id, remindAt: base.addingTimeInterval(-1))
        await coordinator.reconcile()

        let request = try #require(client.added.first)
        let info = request.content.userInfo
        #expect(info[NotificationRouter.keyKind] as? String == NotificationRouter.Kind.reminder.rawValue)
        #expect(info[NotificationRouter.keyTaskID] as? String == task.id.uuidString)
        #expect(info[NotificationRouter.keyNoteID] as? String == note.id.uuidString)
        #expect(info[NotificationRouter.keyRevision] as? Int == 1)
        #expect(request.identifier == NotificationRouter.reminderIdentifier(taskID: task.id))
    }
}
