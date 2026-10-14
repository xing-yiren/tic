import Foundation
import GRDB

/// A resource attached to a note: a local file or folder (a plain folder or a code repo is still a
/// directory), or a web URL. Stored as a *reference* — never a copy — so removing a link never touches
/// the original file. A macOS bookmark (when available) survives moves/renames; the plain path is kept
/// for display and as a fallback for re-location.
struct ResourceLink: Identifiable, Equatable, Codable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case file
        case directory
        case repository
        case web

        var displayName: String {
            switch self {
            case .file:       return "File"
            case .directory:  return "Folder"
            case .repository: return "Repository"
            case .web:        return "Web link"
            }
        }

        var symbolName: String {
            switch self {
            case .file:       return "doc"
            case .directory:  return "folder"
            case .repository: return "chevron.left.forwardslash.chevron.right"
            case .web:        return "link"
            }
        }
    }

    var id: UUID
    var noteID: UUID
    var kind: Kind
    /// User-facing name (editable), defaulting to the file/folder name or the URL host.
    var label: String
    /// The URL string: a `file://…` URL for local resources, an `http(s)://…` for web.
    var url: String
    /// Security-scoped / bookmarks data for local resources (nil for web links).
    var bookmarkData: Data?
    var sortIndex: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        noteID: UUID,
        kind: Kind,
        label: String,
        url: String,
        bookmarkData: Data? = nil,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.noteID = noteID
        self.kind = kind
        self.label = label
        self.url = url
        self.bookmarkData = bookmarkData
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isLocal: Bool { kind != .web }

    /// The file URL for local resources.
    var fileURL: URL? { isLocal ? URL(string: url) : nil }

    /// The web URL, only when it's a valid http(s) link.
    var webURL: URL? {
        guard kind == .web, let url = URL(string: url) else { return nil }
        return url
    }
}

extension ResourceLink: FetchableRecord, PersistableRecord {
    static let databaseTableName = "resource"

    enum Columns {
        static let id = Column("id")
        static let noteID = Column("noteID")
        static let sortIndex = Column("sortIndex")
    }
}
