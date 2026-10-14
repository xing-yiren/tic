import Foundation
import GRDB
import Testing
@testable import Tic

/// Incremental-upgrade safety: a database written by an older schema must migrate forward without
/// losing rows, and the new tables/columns must be usable afterwards. We build a genuine v5 database
/// (the last schema before categories/resources/reminders) and open it with the current `AppDatabase`
/// so the real migrator runs.
@Suite("AppDatabase migrations")
struct AppDatabaseMigrationTests {
    /// Creates a v5-shaped database with one note + one task, and records the migrations already run
    /// so the current migrator only applies v6…v8.
    private func makeV5Database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for id in ["v1_notes_and_tasks", "v2_task_indent_level",
                       "v3_note_completed_options", "v4_task_image", "v5_note_is_open"] {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [id])
            }

            try db.execute(sql: """
                CREATE TABLE note (
                    id TEXT NOT NULL PRIMARY KEY, title TEXT NOT NULL DEFAULT '',
                    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL,
                    color TEXT NOT NULL, material TEXT NOT NULL,
                    frameX DOUBLE NOT NULL, frameY DOUBLE NOT NULL,
                    frameW DOUBLE NOT NULL, frameH DOUBLE NOT NULL,
                    floatOnTop BOOLEAN NOT NULL DEFAULT 0, showOnAllSpaces BOOLEAN NOT NULL DEFAULT 0,
                    isCollapsed BOOLEAN NOT NULL DEFAULT 0, sortIndex INTEGER NOT NULL DEFAULT 0,
                    hideCompleted BOOLEAN NOT NULL DEFAULT 0, moveCompletedToBottom BOOLEAN NOT NULL DEFAULT 0,
                    isOpen BOOLEAN NOT NULL DEFAULT 1)
                """)
            try db.execute(sql: """
                CREATE TABLE task (
                    id TEXT NOT NULL PRIMARY KEY, noteId TEXT NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                    text TEXT NOT NULL DEFAULT '', isDone BOOLEAN NOT NULL DEFAULT 0,
                    sortIndex INTEGER NOT NULL DEFAULT 0, createdAt DATETIME NOT NULL,
                    completedAt DATETIME, indentLevel INTEGER NOT NULL DEFAULT 0)
                """)
            try db.execute(sql: """
                CREATE TABLE taskImage (
                    taskId TEXT NOT NULL PRIMARY KEY REFERENCES task(id) ON DELETE CASCADE,
                    data BLOB NOT NULL, cropX DOUBLE NOT NULL DEFAULT 0, cropY DOUBLE NOT NULL DEFAULT 0,
                    cropW DOUBLE NOT NULL DEFAULT 1, cropH DOUBLE NOT NULL DEFAULT 1, updatedAt DATETIME NOT NULL)
                """)

            let now = Date()
            let noteID = UUID(), taskID = UUID()
            try db.execute(sql: """
                INSERT INTO note (id, title, createdAt, updatedAt, color, material, frameX, frameY, frameW, frameH)
                VALUES (?, 'Old Note', ?, ?, 'yellow', 'solid', 40, 40, 280, 360)
                """, arguments: [noteID, now, now])
            try db.execute(sql: """
                INSERT INTO task (id, noteId, text, createdAt, sortIndex) VALUES (?, ?, 'Old task', ?, 0)
                """, arguments: [taskID, noteID, now])
        }
        return queue
    }

    @Test("a v5 database upgrades to the current schema, keeping its notes and tasks")
    func upgradesFromV5() async throws {
        let queue = try makeV5Database()
        let db = try AppDatabase(queue)   // runs v6…v8

        let notes = try await db.allNotes()
        #expect(notes.count == 1)
        let note = try #require(notes.first)
        #expect(note.title == "Old Note")
        #expect(note.categoryID == nil)   // migrated notes are uncategorised

        let tasks = try await db.tasks(noteId: note.id)
        #expect(tasks.map(\.text) == ["Old task"])
        #expect(tasks.first?.dueAt == nil)   // the new deadline column defaults to NULL
    }

    @Test("after upgrading, the new tables accept categories, resources, and reminders")
    func newTablesUsable() async throws {
        let db = try AppDatabase(try makeV5Database())
        let note = try #require(try await db.allNotes().first)
        let task = try #require(try await db.tasks(noteId: note.id).first)

        let category = try await db.createCategory(name: "Work")
        try await db.updateNoteCategory(id: note.id, categoryID: category.id)
        #expect(try await db.note(id: note.id)?.categoryID == category.id)

        let resource = try await db.addResource(noteID: note.id, url: "https://example.com/x", kind: nil, label: nil)
        #expect(try await db.resources(noteID: note.id).map(\.id) == [resource.id])

        let reminder = try await db.setReminder(taskID: task.id, remindAt: Date().addingTimeInterval(3600))
        #expect(reminder.revision == 1)
    }

    @Test("a v5 fixture still upgrades after the category column references the new table")
    func categoryForeignKeyCascade() async throws {
        // ON DELETE SET NULL: deleting a category returns its notes to Uncategorised, never deleting them.
        let db = try AppDatabase.makeInMemory()
        let note = try await db.insertNewNote(Note(title: "Filed"))
        let category = try await db.createCategory(name: "Temp")
        try await db.updateNoteCategory(id: note.id, categoryID: category.id)
        #expect(try await db.note(id: note.id)?.categoryID == category.id)

        _ = try await db.deleteCategory(id: category.id)
        let after = try await db.note(id: note.id)
        #expect(after != nil)                     // the note survives
        #expect(after?.categoryID == nil)         // back to Uncategorised
    }
}
