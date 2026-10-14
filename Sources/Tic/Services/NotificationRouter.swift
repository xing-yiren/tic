import AppKit
import Foundation
import UserNotifications

/// The single place that owns notification *conventions* — category ids, identifier namespaces,
/// payload keys, and action ids — for both the update banner and task reminders. Centralising them
/// means the update notification keeps its exact behaviour while task reminders slot in beside it,
/// and a click/action is dispatched by `kind` so adding a notification type is one switch case.
enum NotificationRouter {
    // MARK: - Categories
    static let updateCategory = "tic.update"
    static let reminderCategory = "tic.reminder"

    // MARK: - Actions (task reminders)
    static let actionOpen = "tic.reminder.open"
    static let actionDone = "tic.reminder.done"
    static let actionSnooze = "tic.reminder.snooze"

    // MARK: - Identifier namespaces
    static func reminderIdentifier(taskID: UUID) -> String { "tic.reminder.\(taskID.uuidString)" }
    static func updateIdentifier(version: String) -> String { "tic.update.\(version)" }

    /// The task id encoded in a reminder identifier, if it is one.
    static func taskID(fromReminderIdentifier id: String) -> UUID? {
        let prefix = "tic.reminder."
        guard id.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(id.dropFirst(prefix.count)))
    }

    // MARK: - Payload
    enum Kind: String { case update, reminder }
    static let keyKind = "tic.kind"
    static let keyTaskID = "tic.taskID"
    static let keyNoteID = "tic.noteID"
    static let keyRevision = "tic.revision"

    /// Registers the categories/actions with the system. Safe to call repeatedly (idempotent).
    static func registerCategories() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let open = UNNotificationAction(identifier: actionOpen, title: "Open Note")
        let done = UNNotificationAction(identifier: actionDone, title: "Complete")
        let snooze = UNNotificationAction(identifier: actionSnooze, title: "Snooze 10 min")
        let reminder = UNNotificationCategory(
            identifier: reminderCategory, actions: [open, done, snooze],
            intentIdentifiers: [], options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([reminder])
    }

    /// Builds a reminder notification request (identifier is the stable per-task name; the current
    /// revision rides in the payload so a stale tap can be rejected).
    static func reminderRequest(
        taskID: UUID, noteID: UUID, title: String, body: String,
        fireAt: Date, revision: Int, immediate: Bool
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = reminderCategory
        content.userInfo = [
            keyKind: Kind.reminder.rawValue,
            keyTaskID: taskID.uuidString,
            keyNoteID: noteID.uuidString,
            keyRevision: revision,
        ]
        content.sound = .default
        // A definite time-based trigger lets the system deliver it even after the app quits; an
        // "immediate" (already-overdue) reminder fires right away with no trigger.
        let trigger: UNNotificationTrigger? = immediate
            ? nil
            : UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: fireAt), repeats: false)
        return UNNotificationRequest(identifier: reminderIdentifier(taskID: taskID), content: content, trigger: trigger)
    }

    /// Builds the update-available banner. Same copy as always; the identifier now comes from the
/// shared namespace and the payload carries `kind`, so the router can dispatch its click (up to
/// now the update was told apart by an identifier prefix, which this keeps as a fallback).
    static func updateRequest(version: String, currentVersion: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Tic v\(version) is available"
        content.body = "You're on v\(currentVersion). Click to see what's new and download."
        content.userInfo = [keyKind: Kind.update.rawValue]
        content.sound = .default
        return UNNotificationRequest(
            identifier: updateIdentifier(version: version), content: content, trigger: nil)
    }

    static func kind(of request: UNNotificationRequest) -> Kind? {
        if let raw = request.content.userInfo[keyKind] as? String { return Kind(rawValue: raw) }
        return request.identifier.hasPrefix("tic.update.") ? .update : nil
    }
}

/// The `UNUserNotificationCenterDelegate`: presents banners even while Tic is frontmost, and routes a
/// click / action to the right handler by notification kind. Owned by `AppDelegate`.
@MainActor
final class NotificationRouterDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// The task id + revision the tapped reminder carried (nil when not a reminder).
    var onOpenTask: ((UUID, UUID, Int) -> Void)?     // (taskID, noteID, revision)
    var onCompleteTask: ((UUID, Int) -> Void)?       // (taskID, revision)
    var onSnoozeTask: ((UUID, Int) -> Void)?
    var onOpenUpdate: (() -> Void)?

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        // Extract plain values here (the UNNotification types aren't Sendable) before hopping.
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let kindRaw = userInfo[NotificationRouter.keyKind] as? String
        let taskID = (userInfo[NotificationRouter.keyTaskID] as? String).flatMap(UUID.init(uuidString:))
        let noteID = (userInfo[NotificationRouter.keyNoteID] as? String).flatMap(UUID.init(uuidString:))
        let revision = userInfo[NotificationRouter.keyRevision] as? Int

        await MainActor.run {
            let kind = kindRaw.flatMap(NotificationRouter.Kind.init(rawValue:))
                ?? (identifier.hasPrefix("tic.update.") ? .update : nil)
            switch kind {
            case .update:
                onOpenUpdate?()
            case .reminder:
                guard let taskID, let noteID, let revision else { return }
                switch action {
                case NotificationRouter.actionDone:   onCompleteTask?(taskID, revision)
                case NotificationRouter.actionSnooze: onSnoozeTask?(taskID, revision)
                default:                              onOpenTask?(taskID, noteID, revision)
                }
            case nil:
                break
            }
        }
    }
}
