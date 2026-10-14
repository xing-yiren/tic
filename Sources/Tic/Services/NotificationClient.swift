import Foundation
import UserNotifications

/// The slice of `UNUserNotificationCenter` the reminder coordinator needs — abstracted so tests can
/// drive scheduling without a real notification centre (which requires a signed bundle).
protocol NotificationClient: Sendable {
    /// Requests (once) the authorization needed to show reminders. Returns whether it's granted.
    func requestAuthorization() async -> Bool
    /// The current authorization status, without prompting.
    func authorizationStatus() async -> UNAuthorizationStatus
    /// Adds/replaces a pending notification request (same identifier replaces).
    func add(_ request: UNNotificationRequest) async throws
    /// Cancels pending notifications with the given identifiers.
    func removePending(identifiers: [String]) async
    /// The identifiers of currently pending requests.
    func pendingIdentifiers() async -> [String]
    /// The identifiers of already-delivered notifications.
    func deliveredIdentifiers() async -> [String]
}

/// The real client, over `UNUserNotificationCenter`. Needs a bundle id; under `swift run` the centre
/// returns an error and `requestAuthorization` resolves false, which the coordinator surfaces as
/// "unavailable" rather than crashing.
struct SystemNotificationClient: NotificationClient {
    private var center: UNUserNotificationCenter { .current() }

    func requestAuthorization() async -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }

    func removePending(identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func deliveredIdentifiers() async -> [String] {
        await center.deliveredNotifications().map(\.request.identifier)
    }
}

/// Nominal placeholder when there is no bundle id (a bare `swift run`): does nothing and reports
/// notifications as unavailable, so the app degrades instead of crashing.
struct DisabledNotificationClient: NotificationClient {
    func requestAuthorization() async -> Bool { false }
    func authorizationStatus() async -> UNAuthorizationStatus { .denied }
    func add(_ request: UNNotificationRequest) async throws {}
    func removePending(identifiers: [String]) async {}
    func pendingIdentifiers() async -> [String] { [] }
    func deliveredIdentifiers() async -> [String] { [] }
}
