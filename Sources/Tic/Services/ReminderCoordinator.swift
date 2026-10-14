import AppKit
import Foundation
import UserNotifications

/// Reconciles the database (the source of *intent*) with the system's pending notification requests
/// (the actual state). On every change — a reminder set/cleared, a task completed/deleted, launch,
/// wake, or timezone change — it recomputes the expected set and makes the system match: adds
/// requests for unfinished, future reminders; removes requests that no longer belong; and posts
/// already-overdue reminders **once** (tracked by revision), so a missed one isn't repeated on every
/// launch.
///
/// It is deliberately injectable (clock + notification client) so all of this is testable without a
/// real notification centre or a signed bundle.
@MainActor
@Observable
final class ReminderCoordinator {
    enum Availability: Equatable {
        case unknown
        case available
        case denied
        case unavailable   // no bundle id (swift run)

        var canSchedule: Bool { self == .available }
    }

    private(set) var availability: Availability = .unknown

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let client: NotificationClient
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Asks the window layer to open a note (the "Open Note" action).
    @ObservationIgnored var onOpenNote: ((UUID) -> Void)?

    /// How long a "Snooze" action defers the reminder.
    static let snoozeInterval: TimeInterval = 10 * 60

    init(
        database: AppDatabase,
        client: NotificationClient? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.client = client ?? (Bundle.main.bundleIdentifier != nil
            ? SystemNotificationClient() : DisabledNotificationClient())
        self.now = now
    }

    /// A cheap identifier of scheduling state for tests.
    func pendingIdentifiers() async -> [String] { await client.pendingIdentifiers() }

    /// Recomputes and applies the expected notification set. Idempotent — safe to call on launch,
    /// wake, timezone change, or after any task/reminder edit.
    func reconcile() async {
        await refreshAvailability()
        guard availability.canSchedule else { return }
        do {
            let candidates = try await database.pendingReminders(now: now())
            let current = now()
            let pending = Set(await client.pendingIdentifiers())
            let delivered = Set(await client.deliveredIdentifiers())

            var expectedIdentifiers: Set<String> = []
            for candidate in candidates {
                let identifier = NotificationRouter.reminderIdentifier(taskID: candidate.taskID)
                if candidate.remindAt > current {
                    // Future: ensure a pending request exists (idempotent — same id replaces).
                    expectedIdentifiers.insert(identifier)
                    if !pending.contains(identifier) {
                        await schedule(candidate, immediate: false)
                    }
                } else {
                    // Due already. Deliver once per revision: if neither pending nor already delivered
                    // under this revision, post it now (a missed reminder) and acknowledge it.
                    let alreadyHandled = candidate.acknowledgedRevision == candidate.revision
                    if !alreadyHandled && !delivered.contains(identifier) {
                        await schedule(candidate, immediate: true)
                        try? await database.acknowledgeReminder(taskID: candidate.taskID, revision: candidate.revision)
                    }
                }
            }
            // Remove pending reminders that are no longer expected (cleared / completed / cancelled).
            let stale = pending.filter { $0.hasPrefix("tic.reminder.") && !expectedIdentifiers.contains($0) }
            if !stale.isEmpty { await client.removePending(identifiers: Array(stale)) }
        } catch {
            NSLog("[Tic] reminder reconcile failed: \(error)")
        }
    }

    private func schedule(_ candidate: ReminderCandidate, immediate: Bool) async {
        let title = candidate.text.isEmpty ? "Task reminder" : candidate.text
        let body = immediate ? "This reminder was due earlier." : "It's time."
        let request = NotificationRouter.reminderRequest(
            taskID: candidate.taskID, noteID: candidate.noteID,
            title: title, body: body,
            fireAt: candidate.remindAt, revision: candidate.revision, immediate: immediate
        )
        do {
            try await client.add(request)
        } catch {
            NSLog("[Tic] scheduling reminder failed: \(error)")
        }
    }

    // MARK: - Actions

    /// The user tapped "Snooze": push the reminder out and reschedule (revision bumps so any stale
    /// tap can't re-fire).
    func snooze(taskID: UUID) async {
        let fireAt = now().addingTimeInterval(Self.snoozeInterval)
        _ = try? await database.setReminder(taskID: taskID, remindAt: fireAt)
        await reconcile()
    }

    /// A reminder-triggered open: surface the note (the caller decides focus policy).
    func open(taskID: UUID, noteID: UUID) {
        onOpenNote?(noteID)
    }

    // MARK: - Authorization

    private func refreshAvailability() async {
        // With no bundle id (a bare `swift run`) the centre can't be used at all, so report
        // "unavailable" rather than a misleading "denied". Otherwise ask the (injectable) client.
        guard !(client is DisabledNotificationClient) else { availability = .unavailable; return }
        let status = await client.authorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral: availability = .available
        case .denied:                               availability = .denied
        default:                                    availability = .unknown
        }
    }

    /// Requests authorization the first time a reminder is actually set, so the system prompt appears
    /// in context. Returns whether scheduling is now possible.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let status = await client.authorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            availability = .available
            return true
        case .denied:
            availability = .denied
            return false
        default:
            let granted = await client.requestAuthorization()
            availability = granted ? .available : .denied
            return granted
        }
    }
}
