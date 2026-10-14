import AppKit
import Foundation

/// Opens and resolves note resources (files, folders, repos, web links). Kept AppKit-free at the
/// model layer — only this service touches `NSWorkspace` / bookmarks.
///
/// Bookmarks are created **without** the security-scoped option: reading a bookmark you made for a
/// file you already had access to needs no entitlement, and Tic is not sandboxed. This keeps the
/// common case (a document in the user's home) simple, while still surviving a move/rename.
enum ResourceAccessService {
    enum ResolveOutcome: Equatable {
        case resolved(URL)      // the resource exists and is usable
        case missing            // the bookmark resolved but the file is gone
        case unresolved         // the bookmark/path could not be resolved at all
    }

    /// Creates bookmark data for a local URL (nil on failure — a path is always kept as a fallback).
    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Best-effort classification of a local file URL: a directory that looks like a git repo is a
    /// `.repository`, any other directory is `.directory`, everything else is `.file`.
    static func kind(for url: URL) -> ResourceLink.Kind {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else { return .file }
        let git = url.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: git.path) ? .repository : .directory
    }

    /// Resolves a stored resource to a live URL, using its bookmark first (survives moves) and the
    /// plain path as a fallback.
    static func resolve(url: String, bookmarkData: Data?, kind: ResourceLink.Kind) -> ResolveOutcome {
        if kind == .web {
            guard let u = URL(string: url) else { return .unresolved }
            return .resolved(u)
        }
        if let bookmarkData {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                if FileManager.default.fileExists(atPath: resolved.path) { return .resolved(resolved) }
                return .missing
            }
        }
        guard let fallback = URL(string: url) else { return .unresolved }
        if FileManager.default.fileExists(atPath: fallback.path) { return .resolved(fallback) }
        return FileManager.default.fileExists(atPath: fallback.path) ? .resolved(fallback) : .missing
    }

    /// Opens a resource with its default application (web links go to the browser, folders to Finder,
    /// files to their handler). Never runs shell commands or repo scripts.
    @discardableResult
    static func open(url: String, bookmarkData: Data?, kind: ResourceLink.Kind) -> ResolveOutcome {
        let outcome = resolve(url: url, bookmarkData: bookmarkData, kind: kind)
        guard case .resolved(let resolved) = outcome else { return outcome }
        if kind == .web {
            NSWorkspace.shared.open(resolved)
        } else {
            NSWorkspace.shared.open(resolved)
        }
        return outcome
    }

    /// Reveals a local resource in Finder (no-op for web links).
    @discardableResult
    static func revealInFinder(url: String, bookmarkData: Data?) -> ResolveOutcome {
        let outcome = resolve(url: url, bookmarkData: bookmarkData, kind: .file)
        guard case .resolved(let resolved) = outcome else { return outcome }
        NSWorkspace.shared.activateFileViewerSelecting([resolved])
        return outcome
    }

    /// Copies a web link to the pasteboard.
    static func copyLink(_ url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
}
