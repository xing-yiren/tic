import Foundation
import GRDB

// MARK: - Resources

extension AppDatabase {
    enum ResourceError: LocalizedError, Equatable {
        case emptyLabel
        case unsupportedURL(String)
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .emptyLabel:            return "A resource needs a name."
            case .unsupportedURL(let u): return "Unsupported resource URL: \(u)"
            case .missing(let id):       return "No resource with id \(id)"
            }
        }
    }

    /// Validates and normalises a resource URL. Only `file:` (local) and `http`/`https` (web) are
    /// accepted — notably **no** `file:` for web or arbitrary schemes, so a remote/MCP caller can't
    /// smuggle in something that would be handed to the shell or an arbitrary handler.
    static func validatedResourceURL(_ raw: String) -> (url: String, kind: ResourceLink.Kind)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        guard let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            guard url.host?.isEmpty == false else { return nil }
            return (url.absoluteString, .web)
        case "file":
            return (url.absoluteString, .file)   // refined to directory/repository by the caller
        default:
            return nil
        }
    }

    func resources(noteID: UUID) async throws -> [ResourceLink] {
        try await dbQueue.read { db in
            try ResourceLink
                .filter(ResourceLink.Columns.noteID == noteID)
                .order(ResourceLink.Columns.sortIndex)
                .fetchAll(db)
        }
    }

    func resource(id: UUID) async throws -> ResourceLink? {
        try await dbQueue.read { db in try ResourceLink.filter(ResourceLink.Columns.id == id).fetchOne(db) }
    }

    /// Adds a resource to the end of a note's list. `kind` may be refined by the caller (a directory
    /// can be recorded as `.repository`); the URL is validated here so UI and MCP share one rule.
    @discardableResult
    func addResource(
        noteID: UUID, url rawURL: String, kind: ResourceLink.Kind?, label rawLabel: String?,
        bookmarkData: Data? = nil
    ) async throws -> ResourceLink {
        guard let (normalized, detected) = Self.validatedResourceURL(rawURL) else {
            throw ResourceError.unsupportedURL(rawURL)
        }
        let kind = kind ?? detected
        guard kind != .web || detected == .web else { throw ResourceError.unsupportedURL(rawURL) }
        let label = (rawLabel?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.defaultLabel(for: normalized, kind: kind)
        return try await dbQueue.write { db in
            let maxIndex = try Int.fetchOne(
                db, sql: "SELECT MAX(sortIndex) FROM resource WHERE noteID = ?", arguments: [noteID]
            ) ?? -1
            var resource = ResourceLink(
                noteID: noteID, kind: kind, label: label, url: normalized,
                bookmarkData: bookmarkData, sortIndex: maxIndex + 1
            )
            try resource.insert(db)
            return resource
        }
    }

    /// A sensible default name: the file/folder leaf name, or the URL host for web links.
    static func defaultLabel(for url: String, kind: ResourceLink.Kind) -> String {
        guard let parsed = URL(string: url) else { return url }
        if kind == .web { return parsed.host ?? url }
        let leaf = parsed.lastPathComponent
        return leaf.isEmpty ? (parsed.path.isEmpty ? url : parsed.path) : leaf
    }

    /// Targeted rename — only the label column, so it can't disturb the URL or ordering.
    func renameResource(id: UUID, label raw: String) async throws {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw ResourceError.emptyLabel }
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE resource SET label = ?, updatedAt = ? WHERE id = ?", arguments: [label, Date(), id])
        }
    }

    /// Re-points a moved/renamed resource at a new location, refreshing its bookmark. Used by the
    /// "Relocate" action when a bookmark can no longer be resolved.
    func relocateResource(id: UUID, to url: String, kind: ResourceLink.Kind, bookmarkData: Data?) async throws {
        guard let (normalized, _) = Self.validatedResourceURL(url) else { throw ResourceError.unsupportedURL(url) }
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE resource SET url = ?, kind = ?, bookmarkData = ?, updatedAt = ? WHERE id = ?",
                arguments: [normalized, kind.rawValue, bookmarkData, Date(), id]
            )
        }
    }

    /// Removes a link. The original file/folder is **never** touched (we only stored a reference).
    func deleteResource(id: UUID) async throws {
        try await dbQueue.write { db in
            _ = try ResourceLink.filter(ResourceLink.Columns.id == id).deleteAll(db)
        }
    }

    func reorderResources(_ orderedIDs: [UUID]) async throws {
        try await dbQueue.write { db in
            for (index, id) in orderedIDs.enumerated() {
                try db.execute(sql: "UPDATE resource SET sortIndex = ?, updatedAt = ? WHERE id = ?", arguments: [index, Date(), id])
            }
        }
    }

    /// Emits a note's ordered resources whenever they change. Deliberately never selects the bookmark
    /// blob (mirrors `observeTaskImageCrops`) — bookmarks are read only when a resource is opened, so
    /// re-rendering the resource list never drags the blobs along.
    func observeResources(noteID: UUID) -> AsyncValueObservation<[ResourceSummary]> {
        ValueObservation
            .tracking { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, noteID, kind, label, url, sortIndex, createdAt, updatedAt
                    FROM resource WHERE noteID = ? ORDER BY sortIndex
                    """, arguments: [noteID])
                return try rows.map { try ResourceSummary(row: $0) }
            }
            .values(in: dbQueue)
    }

    /// The stored bookmark for a resource (read on demand, never via an observation).
    func resourceBookmark(id: UUID) async throws -> Data? {
        try await dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT bookmarkData FROM resource WHERE id = ?", arguments: [id])
        }
    }

    /// A note's resources including bookmarks — a one-shot for `get_note`/MCP, not an observation.
    func resourcesWithBookmarks(noteID: UUID) async throws -> [ResourceLink] {
        try await resources(noteID: noteID)
    }
}

/// A resource without its bookmark blob — what the live list observation carries. Bookmark data is
/// fetched separately (`resourceBookmark(id:)`) only when a link is actually opened/relocated.
struct ResourceSummary: Identifiable, Equatable, Sendable {
    var id: UUID
    var noteID: UUID
    var kind: ResourceLink.Kind
    var label: String
    var url: String
    var sortIndex: Int
    var createdAt: Date
    var updatedAt: Date

    init(row: Row) throws {
        let kindRaw: String = row["kind"]
        guard let kind = ResourceLink.Kind(rawValue: kindRaw) else {
            throw DatabaseError(message: "Unknown resource kind: \(kindRaw)")
        }
        self.id = row["id"]
        self.noteID = row["noteID"]
        self.kind = kind
        self.label = row["label"]
        self.url = row["url"]
        self.sortIndex = row["sortIndex"]
        self.createdAt = row["createdAt"]
        self.updatedAt = row["updatedAt"]
    }

    var isLocal: Bool { kind != .web }
    var fileURL: URL? { isLocal ? URL(string: url) : nil }
    var webURL: URL? { kind == .web ? URL(string: url) : nil }

    /// The `ResourceLink` shape (bookmark-less) so shared display/open code can take one type.
    var link: ResourceLink {
        ResourceLink(
            id: id, noteID: noteID, kind: kind, label: label, url: url,
            bookmarkData: nil, sortIndex: sortIndex, createdAt: createdAt, updatedAt: updatedAt
        )
    }
}
