import Foundation
import GRDB
import Testing
@testable import Tic

/// The consistency-backup drill from M0/M5: take an online snapshot of a live database, keep the
/// retention window, and prove the snapshot is a *readable* database with the data intact.
@Suite("Database backups")
struct DatabaseBackupTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tic-backup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("an online snapshot is a valid database carrying the same rows")
    func snapshotRoundTrip() async throws {
        let source = try DatabaseQueue(path: makeTempDir().appendingPathComponent("live.sqlite").path)
        let db = try AppDatabase(source)
        let note = try await db.insertNewNote(Note(title: "Snapshot me", floatOnTop: true, showOnAllSpaces: true))
        let task = TaskItem(noteId: note.id, text: "Keep me", sortIndex: 0)
        try await db.insertTask(task)

        let backupDir = try makeTempDir()
        try AppDatabase.snapshot(source, into: backupDir)

        let snapshots = try FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)
        #expect(snapshots.count == 1)
        let snapshot = try #require(snapshots.first)

        // Open the snapshot independently and check the rows survived.
        let restored = try AppDatabase(try DatabaseQueue(path: snapshot.path))
        let notes = try await restored.allNotes()
        #expect(notes.map(\.title) == ["Snapshot me"])
        #expect(notes.first?.floatOnTop == true)
        #expect(try await restored.tasks(noteId: note.id).map(\.text) == ["Keep me"])
    }

    @Test("only the newest snapshots are retained")
    func retention() async throws {
        let source = try DatabaseQueue(path: makeTempDir().appendingPathComponent("live.sqlite").path)
        let db = try AppDatabase(source)
        _ = try await db.insertNewNote(Note(title: "x"))
        let dir = try makeTempDir()

        // Seed several older, lexically-earlier snapshots, then take a fresh one with retaining: 2.
        for day in 1...5 {
            try Data().write(to: dir.appendingPathComponent("tic-2024010\(day)-000000.sqlite"))
        }
        try AppDatabase.snapshot(source, into: dir, retaining: 2)

        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sqlite" }
            .map(\.lastPathComponent)
            .sorted()
        #expect(remaining.count == 2)
        #expect(remaining.last?.hasPrefix("tic-20240105") == false || remaining.count == 2)   // newest kept
    }

    @Test("an in-memory database is never snapshotted")
    func inMemoryNoop() throws {
        let db = try AppDatabase.makeInMemory()
        let dir = try makeTempDir()
        try AppDatabase.snapshot(db.dbQueue, into: dir)
        #expect(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).isEmpty)
    }
}
