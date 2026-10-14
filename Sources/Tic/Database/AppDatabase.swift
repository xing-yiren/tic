import Foundation
import GRDB

/// Owns the SQLite connection (via GRDB) and exposes typed CRUD operations plus live
/// `ValueObservation` streams that SwiftUI subscribes to. Thread-safe: GRDB's `DatabaseQueue`
/// serialises all access.
final class AppDatabase: Sendable {
    let dbQueue: DatabaseQueue

    init(_ dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try migrator.migrate(dbQueue)
    }

    // MARK: - Setup

    /// Root of every on-disk artifact (database, MCP socket, backups).
    ///
    /// A development build (see `Environment` in `AppEnvironment.swift`) uses a *separate* folder
    /// so a second-dev checkout can never read or erase the user's real Tic data. Release builds
    /// keep the original `~/Library/Application Support/Tic/` path, so upgrading in place is safe.
    static func supportDirectory() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = appSupport.appendingPathComponent(Environment.current.supportDirectoryName, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The shared on-disk database at `~/Library/Application Support/<support dir>/tic.sqlite`.
    static func makeShared() throws -> AppDatabase {
        let dbURL = try supportDirectory().appendingPathComponent("tic.sqlite")
        let queue = try DatabaseQueue(path: dbURL.path)
        // Snapshot the *pre-migration* database before the migrator touches it, so a new schema has a
        // genuinely recoverable "before" copy next to it. (Done before `init`, which runs migrations.)
        try snapshot(queue)
        let db = try AppDatabase(queue)
        try db.seedSampleDataIfEmpty()
        return db
    }

    /// An ephemeral in-memory database, for previews and tests.
    static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }

    var path: String { dbQueue.path }

    /// The path the *real* (release) Tic database would live at, regardless of the current build's
    /// environment — used to warn a dev build when it is pointed at real data.
    static func releaseDatabasePath() -> URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("Tic", isDirectory: true)
            .appendingPathComponent("tic.sqlite")
    }

    // MARK: - Migrations

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Never wipe a real database automatically — not even in DEBUG. Auto-erasing on schema
        // change would destroy a developer's or user's data on the next launch. Instead a migration
        // failure is fatal-and-visible, and `backUpBeforeMigration()` below leaves a recoverable
        // copy. (Previously `eraseDatabaseOnSchemaChange = true` under `#if DEBUG`.)

        migrator.registerMigration("v1_notes_and_tasks") { db in
            try db.create(table: "note") { t in
                t.primaryKey("id", .blob).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("color", .text).notNull()
                t.column("material", .text).notNull()
                t.column("frameX", .double).notNull()
                t.column("frameY", .double).notNull()
                t.column("frameW", .double).notNull()
                t.column("frameH", .double).notNull()
                t.column("floatOnTop", .boolean).notNull().defaults(to: false)
                t.column("showOnAllSpaces", .boolean).notNull().defaults(to: false)
                t.column("isCollapsed", .boolean).notNull().defaults(to: false)
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "task") { t in
                t.primaryKey("id", .blob).notNull()
                t.column("noteId", .blob).notNull()
                    .references("note", onDelete: .cascade)
                t.column("text", .text).notNull().defaults(to: "")
                t.column("isDone", .boolean).notNull().defaults(to: false)
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("completedAt", .datetime)
            }
            try db.create(index: "task_on_noteId", on: "task", columns: ["noteId"])
        }

        migrator.registerMigration("v2_task_indent_level") { db in
            try db.alter(table: "task") { t in
                t.add(column: "indentLevel", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v3_note_completed_options") { db in
            try db.alter(table: "note") { t in
                t.add(column: "hideCompleted", .boolean).notNull().defaults(to: false)
                t.add(column: "moveCompletedToBottom", .boolean).notNull().defaults(to: false)
            }
        }

        // A task's pasted image, in its own table (not columns on `task`) so the task observation —
        // which re-fetches every row on each toggle/drag — never drags the blobs along, and so the crop
        // gets its own targeted write that a whole-record task text commit can't clobber. The crop is
        // normalised (0…1, top-left origin) over the untouched original. Cascades with its task.
        migrator.registerMigration("v4_task_image") { db in
            try db.create(table: "taskImage") { t in
                t.primaryKey("taskId", .blob).notNull()
                    .references("task", onDelete: .cascade)
                t.column("data", .blob).notNull()
                t.column("cropX", .double).notNull().defaults(to: 0)
                t.column("cropY", .double).notNull().defaults(to: 0)
                t.column("cropW", .double).notNull().defaults(to: 1)
                t.column("cropH", .double).notNull().defaults(to: 1)
                t.column("updatedAt", .datetime).notNull()
            }
        }

        // Existing notes default to open, so upgrading changes nothing until a note is closed.
        migrator.registerMigration("v5_note_is_open") { db in
            try db.alter(table: "note") { t in
                t.add(column: "isOpen", .boolean).notNull().defaults(to: true)
            }
        }

        return migrator
    }

    // MARK: - Backup

    /// Folder holding rotating pre-migration snapshots, beside the database.
    static func backupDirectory() throws -> URL {
        let dir = try supportDirectory().appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Takes a consistent snapshot of the live database into `Backups/tic-<timestamp>.sqlite` and
    /// keeps the newest `retainedBackups`. Uses SQLite's online backup API (via GRDB), so it is safe
    /// while the database is open with a WAL — a plain file copy would not be. No-op for in-memory
    /// databases (tests) and for a brand-new file that has no data yet.
    func backUpBeforeMigration(retaining retainedBackups: Int = 5) throws {
        try Self.snapshot(dbQueue, retaining: retainedBackups)
    }

    /// Snapshots an on-disk queue into `Backups/tic-<timestamp>.sqlite`, keeping the newest
    /// `retainedBackups`. Safe to call *before* migrations (the queue need not be migrated yet) and
    /// while the database is open with a WAL. No-op for in-memory queues or a not-yet-created file.
    static func snapshot(_ queue: DatabaseQueue, retaining retainedBackups: Int = 5) throws {
        try snapshot(queue, into: try backupDirectory(), retaining: retainedBackups)
    }

    /// The testable core of `snapshot(_:retaining:)`: same behaviour, but the destination folder is
    /// supplied (so tests never touch Application Support).
    static func snapshot(_ queue: DatabaseQueue, into dir: URL, retaining retainedBackups: Int = 5) throws {
        guard queue.path != ":memory:" else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: queue.path) else { return }
        // Skip a brand-new, never-written database: an empty snapshot is noise.
        let size = (try? fm.attributesOfItem(atPath: queue.path))?[.size] as? Int ?? 0
        guard size > 0 else { return }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = backupTimestampFormatter.string(from: Date())
        let destination = dir.appendingPathComponent("tic-\(stamp).sqlite")

        let backupQueue = try DatabaseQueue(path: destination.path)
        try queue.backup(to: backupQueue)

        // Prune the oldest snapshots beyond the retention window.
        let snapshots = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("tic-") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        for stale in snapshots.dropLast(max(1, retainedBackups)) {
            try? fm.removeItem(at: stale)
        }
    }

    private static let backupTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    // MARK: - Notes

    func allNotes() async throws -> [Note] {
        try await dbQueue.read { db in
            try Note.order(Note.Columns.sortIndex).fetchAll(db)
        }
    }

    /// The notes whose panels were on screen at last quit (launch restore).
    func openNotes() async throws -> [Note] {
        try await dbQueue.read { db in
            try Note.filter(Note.Columns.isOpen == true).order(Note.Columns.sortIndex).fetchAll(db)
        }
    }


    func insert(_ note: Note) async throws {
        try await dbQueue.write { db in try note.insert(db) }
    }

    /// Inserts a note assigning the next `sortIndex` (`MAX + 1`) atomically inside the write, so
    /// concurrent/rapid creation can't collide and ordering stays stable regardless of which
    /// notes happen to be open. Returns the stored note (with its assigned `sortIndex`).
    @discardableResult
    func insertNewNote(_ note: Note) async throws -> Note {
        try await dbQueue.write { db in
            let maxIndex = try Int.fetchOne(db, sql: "SELECT MAX(sortIndex) FROM note") ?? -1
            var stored = note
            stored.sortIndex = maxIndex + 1
            if stored.title.isEmpty {
                // Default name based on how many lists exist *now*: 0 lists → "List 1"; after you
                // rename one and add another you get "List 2" (not "List 1" again); restarting with
                // zero lists naturally starts back at 1. Bump past any clash so names stay unique.
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note") ?? 0
                let titles = try String.fetchSet(db, sql: "SELECT title FROM note")
                var n = count + 1
                while titles.contains("List \(n)") { n += 1 }
                stored.title = "List \(n)"
            }
            try stored.insert(db)
            return stored
        }
    }

    /// Updates a note, stamping `updatedAt`.
    func update(_ note: Note) async throws {
        var updated = note
        updated.updatedAt = Date()
        let snapshot = updated
        try await dbQueue.write { db in try snapshot.update(db) }
    }

    func deleteNote(id: UUID) async throws {
        try await dbQueue.write { db in
            _ = try Note.filter(Note.Columns.id == id).deleteAll(db)
        }
    }

    /// Targeted write of just a note's window frame, so frequent drag/resize saves never race
    /// with edits to other fields (title, tasks, flags).
    func updateNoteFrame(id: UUID, x: Double, y: Double, width: Double, height: Double) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE note SET frameX = ?, frameY = ?, frameW = ?, frameH = ?, updatedAt = ? WHERE id = ?",
                arguments: [x, y, width, height, Date(), id]
            )
        }
    }

    /// Targeted write of a note's title.
    func updateNoteTitle(id: UUID, title: String) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE note SET title = ?, updatedAt = ? WHERE id = ?",
                arguments: [title, Date(), id]
            )
        }
    }

    /// Targeted write of a note's appearance (colour + material).
    func updateNoteAppearance(id: UUID, color: NoteColor, material: NoteMaterial) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE note SET color = ?, material = ?, updatedAt = ? WHERE id = ?",
                arguments: [color.rawValue, material.rawValue, Date(), id]
            )
        }
    }

    /// Targeted write of a note's window behaviour flags.
    func updateNoteFlags(id: UUID, floatOnTop: Bool, showOnAllSpaces: Bool, isCollapsed: Bool) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE note SET floatOnTop = ?, showOnAllSpaces = ?, isCollapsed = ?, updatedAt = ? WHERE id = ?",
                arguments: [floatOnTop, showOnAllSpaces, isCollapsed, Date(), id]
            )
        }
    }

    /// Targeted write of whether a note's panel is on screen (closed via X vs. opened).
    func updateNoteOpen(id: UUID, isOpen: Bool) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE note SET isOpen = ? WHERE id = ?",
                arguments: [isOpen, id]
            )
        }
    }

    /// Targeted write of a note's checklist display options (hide completed / move completed to
    /// bottom). Kept separate from `updateNoteFlags` (window behaviour) so each stays column-targeted.
    func updateNoteListOptions(id: UUID, hideCompleted: Bool, moveCompletedToBottom: Bool) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE note SET hideCompleted = ?, moveCompletedToBottom = ?, updatedAt = ? WHERE id = ?",
                arguments: [hideCompleted, moveCompletedToBottom, Date(), id]
            )
        }
    }

    /// A single note fetched by id (nil if it was deleted). Used to open a note an agent created
    /// or wrote to while its panel was closed.
    func note(id: UUID) async throws -> Note? {
        try await dbQueue.read { db in
            try Note.filter(Note.Columns.id == id).fetchOne(db)
        }
    }

    /// Emits one note whenever it changes (nil once deleted) — the per-row twin of `observeNotes`,
    /// so an open panel reflects an agent's title/colour/flag writes live.
    func observeNote(id: UUID) -> AsyncValueObservation<Note?> {
        ValueObservation
            .tracking { db in try Note.filter(Note.Columns.id == id).fetchOne(db) }
            .values(in: dbQueue)
    }

    /// Emits the full ordered list of notes whenever any note changes.
    func observeNotes() -> AsyncValueObservation<[Note]> {
        ValueObservation
            .tracking { db in try Note.order(Note.Columns.sortIndex).fetchAll(db) }
            .values(in: dbQueue)
    }
}

/// One sample row for the welcome notes — a named type instead of a 3-tuple.
private struct SeedTask {
    let text: String
    let level: Int
    let done: Bool
    init(_ text: String, _ level: Int, _ done: Bool) {
        self.text = text
        self.level = level
        self.done = done
    }
}

// MARK: - Seeding

extension AppDatabase {
    /// On a brand-new database, drops in a couple of welcome notes that double as a feature tour —
    /// one showing subtasks / Markdown / multiline / completion, and a second listing the keyboard
    /// shortcuts so they're discoverable.
    func seedSampleDataIfEmpty() throws {
        try dbQueue.write { db in
            guard try Note.fetchCount(db) == 0 else { return }
            let now = Date()

            func seed(_ note: Note, _ items: [SeedTask]) throws {
                try note.insert(db)
                for (index, item) in items.enumerated() {
                    let task = TaskItem(
                        noteId: note.id, text: item.text, isDone: item.done,
                        sortIndex: index, indentLevel: item.level,
                        createdAt: now, completedAt: item.done ? now : nil
                    )
                    try task.insert(db)
                }
            }

            try seed(
                Note(
                    title: "Welcome to Tic 👋", color: .yellow, material: .solid,
                    frameX: 130, frameY: 200, frameW: 300, frameH: 440,
                    floatOnTop: true, showOnAllSpaces: true, sortIndex: 0
                ),
                [
                    SeedTask("Tap the circle to finish a task", 0, false),
                    SeedTask("Break big tasks into subtasks", 0, false),
                    SeedTask("Hover a row and click the + below it", 1, false),
                    SeedTask("…or press Shift-Tab while editing", 1, false),
                    SeedTask("*Markdown* — **bold**, `code`, ~~strike~~, [links](https://kasvith.me)", 0, false),
                    SeedTask("Need detail? Press Shift-Return\nfor a new line in the same task", 0, false),
                    SeedTask("Completing a parent completes its subtasks", 0, true),
                    SeedTask("buy milk", 1, true),
                    SeedTask("water the plants", 1, true),
                    SeedTask("⭐️ Star Tic on [GitHub](https://github.com/kasvith/tic)", 0, false),
                ]
            )

            try seed(
                Note(
                    title: "Shortcuts ⌨️", color: .blue, material: .solid,
                    frameX: 470, frameY: 260, frameW: 300, frameH: 320,
                    floatOnTop: true, showOnAllSpaces: true, sortIndex: 1
                ),
                [
                    SeedTask("**Return** — finish editing, or add a task", 0, false),
                    SeedTask("**Shift-Return** — new line in the same task", 0, false),
                    SeedTask("**Shift-Tab** — make it a subtask", 0, false),
                    SeedTask("**Ctrl-Shift-Tab** — move it back out", 0, false),
                    SeedTask("**Drag** to reorder — or drag right to nest", 0, false),
                    SeedTask("**Double-click** the header to roll up", 0, false),
                ]
            )
        }
    }
}
