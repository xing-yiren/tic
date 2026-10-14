import Foundation

/// Resolves which "flavour" of Tic is running and where its data lives.
///
/// The single rule: **a development build never touches the real Tic data.** The release app keeps
/// its historical locations (`~/Library/Application Support/Tic/`, bundle id `com.kasvith.tic`, the
/// GitHub release feed). A dev build — a `swift run`, or a bundle whose id isn't the release id —
/// is redirected to a parallel world (`…/TicDev/`, bundle id `com.kasvith.tic.dev`, a local update
/// feed), so the two can run side by side without clobbering each other's database, MCP socket, or
/// preferences.
enum Environment: Sendable {
    case release
    case development

    /// A build is "release" only when it is a packaged bundle carrying the exact release id. A bare
    /// `swift run` executable has no bundle id and is therefore always development.
    static let current: Environment =
        Bundle.main.bundleIdentifier == releaseBundleIdentifier ? .release : .development

    static let releaseBundleIdentifier = "com.kasvith.tic"
    static let developmentBundleIdentifier = "com.kasvith.tic.dev"

    /// This build's bundle id (dev builds get their own so notifications, TCC prompts, and the
    /// `defaults` domain don't collide with the release app).
    var bundleIdentifier: String {
        switch self {
        case .release:     return Self.releaseBundleIdentifier
        case .development: return Self.developmentBundleIdentifier
        }
    }

    /// The `Application Support` subfolder holding the database, MCP socket, and backups.
    var supportDirectoryName: String {
        switch self {
        case .release:     return "Tic"
        case .development: return "TicDev"
        }
    }

    var isDevelopment: Bool { self == .development }

    /// The repo the update checker should watch. Development builds must **not** treat upstream Tic
    /// releases as their own updates, so they point at a distinct (currently unreleased) feed and
    /// simply find nothing.
    var updateFeedOwner: String { isDevelopment ? "xing-yiren" : "kasvith" }
    var updateFeedRepo: String { isDevelopment ? "tic-dev" : "tic" }
}
