import Foundation
import GRDB

// MARK: - Deadlines & reminders

extension AppDatabase {
    /// The pending reminder for a task, if any.
    func reminder(taskID: UUID) async throws -> TaskReminder? {
        try await dbQueue.read { db in
            try TaskReminder.filter(TaskReminder.Columns.taskID == taskID).fetchOne(db)
        }
    }

    /// Targeted write of just a task's deadline, so it can't clobber text/completion/positions.
    func updateTaskDue(id: UUID, dueAt: Date?) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE task SET dueAt = ? WHERE id = ?", arguments: [dueAt, id])
        }
    }

    /// Sets (or replaces) a task's reminder. Each change bumps `revision` and clears the
    /// acknowledgement, so the coordinator re-schedules and any in-flight notification is superseded.
    @discardableResult
    func setReminder(taskID: UUID, remindAt: Date) async throws -> TaskReminder {
        try await dbQueue.write { db in
            // Any existing row carries forward the revision counter (so an old notification's payload
            // never matches the new one).
            let current = try TaskReminder.filter(TaskReminder.Columns.taskID == taskID).fetchOne(db)
            let reminder = TaskReminder(
                taskID: taskID,
                remindAt: remindAt,
                revision: (current?.revision ?? 0) + 1,
                acknowledgedRevision: nil
            )
            try reminder.save(db)   // upsert on the PK
            return reminder
        }
    }

    /// Clears a task's reminder (cancels the pending notification).
    func clearReminder(taskID: UUID) async throws {
        try await dbQueue.write { db in
            _ = try TaskReminder.filter(TaskReminder.Columns.taskID == taskID).deleteAll(db)
        }
    }

    /// Marks a reminder's given revision as delivered/handled, so it isn't re-posted on the next
    /// reconcile. Only advances (never rewinds) the acknowledged revision.
    func acknowledgeReminder(taskID: UUID, revision: Int) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE taskReminder SET acknowledgedRevision = ?
                    WHERE taskID = ? AND (acknowledgedRevision IS NULL OR acknowledgedRevision < ?)
                    """,
                arguments: [revision, taskID, revision]
            )
        }
    }

    /// Every reminder that still needs attention, each paired with its task and note — the raw
    /// material for the coordinator's expected-notification set. Excludes completed/deleted tasks
    /// (deletion cascades the row away; completion is filtered here).
    func pendingReminders(now: Date) async throws -> [ReminderCandidate] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id AS taskID, t.noteId AS noteID, t.text AS text, t.isDone AS isDone,
                       r.remindAt AS remindAt, r.revision AS revision, r.acknowledgedRevision AS ack
                FROM taskReminder r
                JOIN task t ON t.id = r.taskID
                """)
            return rows.compactMap { row in
                let isDone: Bool = row["isDone"]
                guard !isDone else { return nil }
                return ReminderCandidate(
                    taskID: row["taskID"], noteID: row["noteID"], text: row["text"],
                    remindAt: row["remindAt"], revision: row["revision"],
                    acknowledgedRevision: row["ack"]
                )
            }
        }
    }

    /// Task ids that are done — so the coordinator can drop any notification whose task is finished.
    func doneTaskIDs() async throws -> Set<UUID> {
        try await dbQueue.read { db in
            Set(try UUID.fetchAll(db, sql: "SELECT id FROM task WHERE isDone = 1"))
        }
    }

    /// A one-shot read of reminders including their scheduling state (used by MCP / get_note).
    func reminderValue(taskID: UUID) async throws -> TaskReminder? { try await reminder(taskID: taskID) }

    /// Emits a note's reminders whenever they change, keyed by task id — so a row's due/reminder badge
    /// updates live. Never selects bookmark-style blobs (this table has none anyway).
    func observeReminders(noteID: UUID) -> AsyncValueObservation<[UUID: TaskReminder]> {
        ValueObservation
            .tracking { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT r.taskID, r.remindAt, r.revision, r.acknowledgedRevision, r.updatedAt
                    FROM taskReminder r JOIN task t ON t.id = r.taskID
                    WHERE t.noteId = ?
                    """, arguments: [noteID])
                return Dictionary(uniqueKeysWithValues: rows.map { row in
                    let reminder = TaskReminder(
                        taskID: row["taskID"], remindAt: row["remindAt"],
                        revision: row["revision"], acknowledgedRevision: row["acknowledgedRevision"],
                        updatedAt: row["updatedAt"]
                    )
                    return (reminder.taskID, reminder)
                })
            }
            .values(in: dbQueue)
    }
}

/// A reminder joined with the task/note it points at — the coordinator's unit of work.
struct ReminderCandidate: Sendable, Equatable {
    let taskID: UUID
    let noteID: UUID
    let text: String
    let remindAt: Date
    let revision: Int
    let acknowledgedRevision: Int?

    /// Whether this reminder is due (its time has passed) and not yet acknowledged.
    func isOverdue(now: Date) -> Bool { remindAt <= now && acknowledgedRevision != revision }
}
