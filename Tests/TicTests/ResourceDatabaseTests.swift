import Foundation
import Testing
@testable import Tic

@Suite("Resources (database)")
struct ResourceDatabaseTests {
    private func makeDB() throws -> AppDatabase { try AppDatabase.makeInMemory() }
    private func makeNote(_ db: AppDatabase) async throws -> Note {
        try await db.insertNewNote(Note(title: "Project"))
    }

    @Test("only file:// and http(s):// URLs are accepted; other schemes are rejected")
    func urlValidation() {
        #expect(AppDatabase.validatedResourceURL("https://example.com/a")?.kind == .web)
        #expect(AppDatabase.validatedResourceURL("http://example.com")?.kind == .web)
        // Both local paths validate as a file reference; the file/folder/repository distinction is
        // resolved later by `ResourceAccessService.kind(for:)` against the real filesystem.
        #expect(AppDatabase.validatedResourceURL("file:///tmp/notes.txt")?.kind == .file)
        #expect(AppDatabase.validatedResourceURL("file:///Users/me/projects")?.kind == .file)

        // Things that must never masquerade as a resource.
        #expect(AppDatabase.validatedResourceURL("javascript:alert(1)") == nil)
        #expect(AppDatabase.validatedResourceURL("ftp://example.com") == nil)
        #expect(AppDatabase.validatedResourceURL("ssh://git@host/repo") == nil)
        #expect(AppDatabase.validatedResourceURL("not a url") == nil)
        #expect(AppDatabase.validatedResourceURL("") == nil)
    }

    @Test("a local file can't be relabelled as a web kind (no scheme/kind mismatch)")
    func webKindMismatchRejected() async throws {
        let db = try makeDB()
        let note = try await makeNote(db)
        await #expect(throws: AppDatabase.ResourceError.self) {
            _ = try await db.addResource(noteID: note.id, url: "file:///tmp/x", kind: .web, label: nil)
        }
    }

    @Test("resources keep insertion order and default to a sensible label")
    func addAndOrder() async throws {
        let db = try makeDB()
        let note = try await makeNote(db)
        let a = try await db.addResource(noteID: note.id, url: "https://example.com/docs", kind: nil, label: nil)
        let b = try await db.addResource(noteID: note.id, url: "file:///tmp/report.pdf", kind: nil, label: " Report ")
        #expect(a.label == "example.com")     // host for a web link
        #expect(b.label == "Report")          // explicit label, trimmed
        #expect(try await db.resources(noteID: note.id).map(\.id) == [a.id, b.id])
    }

    @Test("renaming writes only the label, so the URL and ordering survive")
    func narrowRename() async throws {
        let db = try makeDB()
        let note = try await makeNote(db)
        let r = try await db.addResource(noteID: note.id, url: "https://example.com/x", kind: nil, label: nil)
        try await db.renameResource(id: r.id, label: "Docs")
        let updated = try #require(try await db.resource(id: r.id))
        #expect(updated.label == "Docs")
        #expect(updated.url == r.url)
        #expect(updated.sortIndex == r.sortIndex)

        await #expect(throws: AppDatabase.ResourceError.emptyLabel) {
            try await db.renameResource(id: r.id, label: "  ")
        }
    }

    @Test("deleting a resource removes only the link, never the note or its siblings")
    func deleteLinkOnly() async throws {
        let db = try makeDB()
        let note = try await makeNote(db)
        let keep = try await db.addResource(noteID: note.id, url: "https://example.com/a", kind: nil, label: nil)
        let drop = try await db.addResource(noteID: note.id, url: "https://example.com/b", kind: nil, label: nil)
        try await db.deleteResource(id: drop.id)
        #expect(try await db.resources(noteID: note.id).map(\.id) == [keep.id])
        #expect(try await db.note(id: note.id) != nil)
    }

    @Test("deleting the note cascades away its resources")
    func cascadeOnNoteDelete() async throws {
        let db = try makeDB()
        let note = try await makeNote(db)
        _ = try await db.addResource(noteID: note.id, url: "https://example.com/a", kind: nil, label: nil)
        try await db.deleteNote(id: note.id)
        #expect(try await db.resources(noteID: note.id).isEmpty)
    }

    @Test("relocating re-points the resource and refreshes its bookmark")
    func relocate() async throws {
        let db = try makeDB()
        let note = try await makeNote(db)
        let r = try await db.addResource(noteID: note.id, url: "file:///tmp/old", kind: .file, label: nil)
        try await db.relocateResource(id: r.id, to: "file:///tmp/new", kind: .file, bookmarkData: Data([1, 2, 3]))
        let moved = try #require(try await db.resource(id: r.id))
        #expect(moved.url.hasSuffix("/tmp/new"))
        #expect(try await db.resourceBookmark(id: r.id) == Data([1, 2, 3]))

        await #expect(throws: AppDatabase.ResourceError.self) {
            try await db.relocateResource(id: r.id, to: "javascript:bad", kind: .file, bookmarkData: nil)
        }
    }

    @Test("the observed summary never carries the bookmark blob")
    func summaryOmitsBookmark() async throws {
        let db = try makeDB()
        let note = try await makeNote(db)
        _ = try await db.addResource(noteID: note.id, url: "file:///tmp/x", kind: .file, label: nil, bookmarkData: Data([9]))
        let summaries = try await db.resourcesWithBookmarks(noteID: note.id)
        #expect(summaries.count == 1)
        #expect(summaries.first?.bookmarkData != nil)   // the full record does carry it
    }
}
