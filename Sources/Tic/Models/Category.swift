import Foundation
import GRDB

/// A user-defined label a note can belong to. Ordered by `sortIndex` for a stable list. A category
/// with no notes is allowed; deleting one never deletes its notes (they become uncategorised).
struct Category: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var name: String
    var sortIndex: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Category: FetchableRecord, PersistableRecord {
    static let databaseTableName = "category"

    enum Columns {
        static let id = Column("id")
        static let name = Column("name")
        static let sortIndex = Column("sortIndex")
    }
}
