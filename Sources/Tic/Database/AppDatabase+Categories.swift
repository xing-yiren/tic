import Foundation
import GRDB

// MARK: - Categories

extension AppDatabase {
    /// A category name is validated the same way everywhere (UI and MCP): trimmed, non-empty, and
    /// unique case-insensitively. Returns the trimmed name or throws a typed error.
    enum CategoryError: LocalizedError, Equatable {
        case emptyName
        case duplicateName(String)

        var errorDescription: String? {
            switch self {
            case .emptyName:            return "A category needs a name."
            case .duplicateName(let n): return "A category named “\(n)” already exists."
            }
        }
    }

    /// Trims and validates a category name against the existing set (optionally excluding one id, for
    /// renames). Callers should use this before insert/rename so UI and MCP can't diverge.
    func validateCategoryName(_ raw: String, excluding id: UUID? = nil) async throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CategoryError.emptyName }
        let clash = try await dbQueue.read { db in
            var request = Category.filter(Category.Columns.name.collating(.nocase) == name)
            if let id { request = request.filter(Category.Columns.id != id) }
            return try request.fetchCount(db) > 0
        }
        if clash { throw CategoryError.duplicateName(name) }
        return name
    }

    func allCategories() async throws -> [Category] {
        try await dbQueue.read { db in
            try Category.order(Category.Columns.sortIndex).fetchAll(db)
        }
    }

    /// Creates a category at the end of the order. The name is validated (trimmed, non-empty, unique).
    @discardableResult
    func createCategory(name raw: String) async throws -> Category {
        let name = try await validateCategoryName(raw)
        return try await dbQueue.write { db in
            let maxIndex = try Int.fetchOne(db, sql: "SELECT MAX(sortIndex) FROM category") ?? -1
            var category = Category(name: name)
            category.sortIndex = maxIndex + 1
            try category.insert(db)
            return category
        }
    }

    /// Renames a category (validated). Only the `name` column is written, so it can't clobber order.
    func renameCategory(id: UUID, name raw: String) async throws {
        let name = try await validateCategoryName(raw, excluding: id)
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE category SET name = ?, updatedAt = ? WHERE id = ?",
                arguments: [name, Date(), id]
            )
        }
    }

    /// Reorders categories to match `orderedIDs`. Ids not present are left untouched.
    func reorderCategories(_ orderedIDs: [UUID]) async throws {
        try await dbQueue.write { db in
            for (index, id) in orderedIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE category SET sortIndex = ?, updatedAt = ? WHERE id = ?",
                    arguments: [index, Date(), id]
                )
            }
        }
    }

    /// Deletes a category. Its notes are moved back to Uncategorised by the FK `ON DELETE SET NULL`,
    /// so nothing is lost. Returns the notes that were affected (so the caller can restore them to
    /// view if the filter changes).
    @discardableResult
    func deleteCategory(id: UUID) async throws -> [UUID] {
        try await dbQueue.write { db in
            let affected = try UUID.fetchAll(
                db, sql: "SELECT id FROM note WHERE categoryID = ?", arguments: [id]
            )
            _ = try Category.filter(Category.Columns.id == id).deleteAll(db)
            return affected
        }
    }

    /// The number of notes in each category (for the management UI), keyed by category id.
    func noteCountsByCategory() async throws -> [UUID: Int] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT categoryID, COUNT(*) AS n FROM note WHERE categoryID IS NOT NULL GROUP BY categoryID"
            )
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["categoryID"] as UUID, $0["n"] as Int) })
        }
    }

    /// Targeted write of just a note's category, so assigning a category can't clobber a concurrent
    /// title/flag/frame edit.
    func updateNoteCategory(id: UUID, categoryID: UUID?) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE note SET categoryID = ?, updatedAt = ? WHERE id = ?",
                arguments: [categoryID, Date(), id]
            )
        }
    }

    /// Emits the ordered categories whenever the table changes (the menu bar + pickers observe this).
    func observeCategories() -> AsyncValueObservation<[Category]> {
        ValueObservation
            .tracking { db in try Category.order(Category.Columns.sortIndex).fetchAll(db) }
            .values(in: dbQueue)
    }

    /// The ids of notes that are open (on screen) and belong to any of `categoryIDs` — used to decide
    /// which panels to reveal when a filter changes. Fetched in one query rather than per note.
    func openNoteIDs(in categories: Set<UUID>, includingUncategorized: Bool) async throws -> Set<UUID> {
        try await dbQueue.read { db in
            var conditions = ["isOpen = 1"]
            var arguments: [DatabaseValueConvertible] = []
            if categories.isEmpty {
                guard includingUncategorized else { return [] }
                conditions.append("categoryID IS NULL")
            } else {
                let placeholders = Array(repeating: "?", count: categories.count).joined(separator: ",")
                if includingUncategorized {
                    conditions.append("(categoryID IN (\(placeholders)) OR categoryID IS NULL)")
                } else {
                    conditions.append("categoryID IN (\(placeholders))")
                }
                arguments = Array(categories)
            }
            let sql = "SELECT id FROM note WHERE " + conditions.joined(separator: " AND ")
            return Set(try UUID.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)))
        }
    }
}
