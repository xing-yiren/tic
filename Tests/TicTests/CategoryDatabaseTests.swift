import Foundation
import Testing
@testable import Tic

@Suite("Categories (database)")
struct CategoryDatabaseTests {
    private func makeDB() throws -> AppDatabase { try AppDatabase.makeInMemory() }

    @Test("names are trimmed and must be non-empty and unique (case-insensitively)")
    func validation() async throws {
        let db = try makeDB()
        let cat = try await db.createCategory(name: "  Work  ")
        #expect(cat.name == "Work")

        do {
            _ = try await db.createCategory(name: "   ")
            Issue.record("an empty name should be rejected")
        } catch let error as AppDatabase.CategoryError {
            #expect(error == .emptyName)
        }
        do {
            _ = try await db.createCategory(name: "work")
            Issue.record("a duplicate name should be rejected")
        } catch let error as AppDatabase.CategoryError {
            #expect(error == .duplicateName("work"))
        }
    }

    @Test("create assigns increasing sort indices so the list has a stable order")
    func ordering() async throws {
        let db = try makeDB()
        let a = try await db.createCategory(name: "A")
        let b = try await db.createCategory(name: "B")
        let c = try await db.createCategory(name: "C")
        #expect(try await db.allCategories().map(\.id) == [a.id, b.id, c.id])

        try await db.reorderCategories([c.id, a.id, b.id])
        #expect(try await db.allCategories().map(\.id) == [c.id, a.id, b.id])
    }

    @Test("rename validates and preserves sort order")
    func rename() async throws {
        let db = try makeDB()
        let a = try await db.createCategory(name: "A")
        try await db.renameCategory(id: a.id, name: " Renamed ")
        #expect(try await db.allCategories().first?.name == "Renamed")

        do {
            try await db.renameCategory(id: a.id, name: "")
            Issue.record("an empty rename should be rejected")
        } catch let error as AppDatabase.CategoryError {
            #expect(error == .emptyName)
        }
    }

    @Test("delete returns the notes it affected and moves them to Uncategorised (never deletes them)")
    func deleteSetsNull() async throws {
        let db = try makeDB()
        let category = try await db.createCategory(name: "Work")
        let other = try await db.createCategory(name: "Home")
        let filed = try await db.insertNewNote(Note(title: "Filed", categoryID: category.id))
        let kept = try await db.insertNewNote(Note(title: "Kept", categoryID: other.id))

        let affected = try await db.deleteCategory(id: category.id)
        #expect(affected == [filed.id])
        #expect(try await db.note(id: filed.id)?.categoryID == nil)   // uncategorised, not deleted
        #expect(try await db.note(id: kept.id)?.categoryID == other.id) // untouched
        #expect(try await db.allCategories().map(\.id) == [other.id])
    }

    @Test("a note's category is updated with a narrow, single-column write")
    func narrowCategoryUpdate() async throws {
        let db = try makeDB()
        let category = try await db.createCategory(name: "Work")
        var note = try await db.insertNewNote(Note(title: "Task list"))
        // A concurrent-looking edit to the title must survive the category assignment.
        try await db.updateNoteTitle(id: note.id, title: "Renamed concurrently")
        try await db.updateNoteCategory(id: note.id, categoryID: category.id)

        note = try #require(try await db.note(id: note.id))
        #expect(note.categoryID == category.id)
        #expect(note.title == "Renamed concurrently")

        try await db.updateNoteCategory(id: note.id, categoryID: nil)
        #expect(try await db.note(id: note.id)?.categoryID == nil)
    }

    @Test("note counts per category, with uncategorised grouped under nil")
    func counts() async throws {
        let db = try makeDB()
        let work = try await db.createCategory(name: "Work")
        let home = try await db.createCategory(name: "Home")
        _ = try await db.insertNewNote(Note(title: "w1", categoryID: work.id))
        _ = try await db.insertNewNote(Note(title: "w2", categoryID: work.id))
        _ = try await db.insertNewNote(Note(title: "none"))

        let counts = try await db.noteCountsByCategory()
        #expect(counts[work.id] == 2)
        #expect(counts[home.id] == nil)   // categories with no notes are simply absent
        // Uncategorised notes aren't a category row, so they aren't counted here.
        #expect(counts.values.reduce(0, +) == 2)
    }

    @Test("openNoteIDs(in:) matches only open notes in the requested categories")
    func openNoteIDsByCategory() async throws {
        let db = try makeDB()
        let work = try await db.createCategory(name: "Work")
        let home = try await db.createCategory(name: "Home")
        let openWork = try await db.insertNewNote(Note(title: "ow", isOpen: true, categoryID: work.id))
        let closedWork = try await db.insertNewNote(Note(title: "cw", isOpen: false, categoryID: work.id))
        let openHome = try await db.insertNewNote(Note(title: "oh", isOpen: true, categoryID: home.id))
        let openNone = try await db.insertNewNote(Note(title: "on", isOpen: true))

        let matched = try await db.openNoteIDs(in: [work.id], includingUncategorized: false)
        #expect(matched == [openWork.id])
        let _ = [closedWork, openHome]

        let withUncat = try await db.openNoteIDs(in: [work.id], includingUncategorized: true)
        #expect(withUncat == [openWork.id, openNone.id])
    }
}
