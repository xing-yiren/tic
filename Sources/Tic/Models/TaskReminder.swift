import Foundation
import GRDB

/// The single pending reminder for a task (one reminder time per task in this version). `revision`
/// increments on every change to the *reminder*, so a notification carrying an older revision is
/// recognised as stale and ignored. `acknowledgedRevision` records the last revision the coordinator
/// has already posted/handled, so a missed reminder is delivered at most once.
struct TaskReminder: Identifiable, Equatable, Codable, Sendable {
    /// One reminder per task, so the task id is the primary key.
    var taskID: UUID
    var remindAt: Date
    var revision: Int
    var acknowledgedRevision: Int?
    var updatedAt: Date

    var id: UUID { taskID }

    init(
        taskID: UUID,
        remindAt: Date,
        revision: Int = 1,
        acknowledgedRevision: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.taskID = taskID
        self.remindAt = remindAt
        self.revision = revision
        self.acknowledgedRevision = acknowledgedRevision
        self.updatedAt = updatedAt
    }
}

extension TaskReminder: FetchableRecord, PersistableRecord {
    static let databaseTableName = "taskReminder"

    enum Columns {
        static let taskID = Column("taskID")
        static let remindAt = Column("remindAt")
        static let revision = Column("revision")
        static let acknowledgedRevision = Column("acknowledgedRevision")
    }
}
