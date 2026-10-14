import AppKit
import Foundation
import Observation
import UserNotifications

/// Checks GitHub Releases for a newer Tic and surfaces it quietly: a menu-bar item while an update
/// exists, a dot on the menu-bar icon until the user has looked, and one notification banner per
/// new version. Check-only on purpose — Tic is ad-hoc signed, so a self-replacing updater
/// (Sparkle) can't be trusted; the release page is the download.
@MainActor
@Observable
final class UpdateChecker {
    struct Release: Sendable, Equatable {
        let version: String   // "0.6.0" (tag without the leading "v")
        let url: URL          // the GitHub release page
    }

    /// A release newer than the running build, if the last check found one.
    private(set) var available: Release?

    /// True while `available` hasn't been looked at yet — drives the dot on the menu-bar icon.
    /// Cleared (and remembered per version) once the menu is opened with the item in it, or the
    /// item is clicked.
    private(set) var isUnseen = false

    /// The menu item's title; also how the menu-tracking observer recognises our menu.
    var menuTitle: String? { available.map { "Update Available: v\($0.version)…" } }

    /// The running build's `CFBundleShortVersionString`. Nil under `swift run` (no bundle), which
    /// disables the checker entirely.
    let currentVersion: String?

    private nonisolated static var latestReleaseURL: URL {
        let env = Environment.current
        return URL(string: "https://api.github.com/repos/\(env.updateFeedOwner)/\(env.updateFeedRepo)/releases/latest")!
    }
    private static let interval: TimeInterval = 24 * 60 * 60
    private static let notifiedVersionKey = "updateNotifiedVersion"
    private static let seenVersionKey = "updateSeenVersion"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: @Sendable () async throws -> Release
    @ObservationIgnored private let notify: @MainActor (Release, String) async -> Void
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// The parameters exist for tests; the app uses the defaults (GitHub + a real banner).
    init(
        currentVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        defaults: UserDefaults = .standard,
        fetch: @escaping @Sendable () async throws -> Release = UpdateChecker.fetchLatest,
        notify: @escaping @MainActor (Release, String) async -> Void = UpdateChecker.postBanner
    ) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.fetch = fetch
        self.notify = notify

        // Opening the menu (and so seeing the item) counts as "seen": the dot goes once it closes.
        NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] note in
            nonisolated(unsafe) let menu = note.object as? NSMenu   // queue: .main, so this is main-actor safe
            MainActor.assumeIsolated {
                guard let self, let menu, let title = self.menuTitle,
                      menu.items.contains(where: { $0.title == title }) else { return }
                self.markSeen()
            }
        }
    }

    /// Check shortly after launch (so it never competes with restoring notes), then daily.
    func start() {
        guard currentVersion != nil else {
            NSLog("[Tic] update check disabled: no bundle version (swift run?)")
            return
        }
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    func check() async {
        guard let currentVersion else { return }
        do {
            let release = try await fetch()
            guard Self.isNewer(release.version, than: currentVersion) else {
                available = nil
                isUnseen = false
                return
            }
            available = release
            isUnseen = defaults.string(forKey: Self.seenVersionKey) != release.version
            NSLog("[Tic] update available: v\(release.version)")
            await notifyOnce(release)
        } catch {
            NSLog("[Tic] update check failed: \(error)")   // silent for the user, by design
        }
    }

    func openReleasePage() {
        guard let available else { return }
        markSeen()
        NSWorkspace.shared.open(available.url)
    }

    func markSeen() {
        guard let available else { return }
        isUnseen = false
        defaults.set(available.version, forKey: Self.seenVersionKey)
    }

    /// One banner per version, remembered in `defaults` so daily checks and relaunches never repeat it.
    private func notifyOnce(_ release: Release) async {
        guard let currentVersion, defaults.string(forKey: Self.notifiedVersionKey) != release.version else { return }
        defaults.set(release.version, forKey: Self.notifiedVersionKey)
        await notify(release, currentVersion)
    }

    // MARK: - Version compare

    /// Numeric, component-wise compare ("0.10.0" > "0.9.0"; "1.0" == "1.0.0"); a leading "v" is ignored.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private nonisolated static func components(_ version: String) -> [Int] {
        var s = Substring(version)
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        return s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    // MARK: - GitHub

    private struct LatestRelease: Decodable {   // snake_case keys: tag_name, html_url
        let tagName: String
        let htmlUrl: URL
    }

    /// `releases/latest` already excludes drafts and pre-releases.
    nonisolated static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try parse(data)
    }

    /// Decodes the `releases/latest` payload, stripping the tag's leading "v".
    nonisolated static func parse(_ data: Data) throws -> Release {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let latest = try decoder.decode(LatestRelease.self, from: data)
        var version = latest.tagName
        if version.hasPrefix("v") { version.removeFirst() }
        return Release(version: version, url: latest.htmlUrl)
    }

    // MARK: - Banner

    /// Authorization is requested here, the first time an update is actually found, so the system
    /// prompt appears with the banner that explains it. Declined → the menu item still works and
    /// we never ask again for this version. `UNUserNotificationCenter` needs a bundle id (swift run).
    static func postBanner(_ release: Release, currentVersion: String) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert])
        } catch {
            NSLog("[Tic] notification authorization failed: \(error)")
            return
        }
        guard granted else {
            NSLog("[Tic] notifications declined; the menu item still shows the update")
            return
        }

        let request = NotificationRouter.updateRequest(version: release.version, currentVersion: currentVersion)
        do {
            try await center.add(request)
        } catch {
            NSLog("[Tic] update notification failed: \(error)")
        }
    }
}
