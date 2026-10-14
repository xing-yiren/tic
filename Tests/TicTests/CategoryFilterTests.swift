import Foundation
import Testing
@testable import Tic

/// Pure logic for the category filter: matching, hiding, revealing, and selection cleanup. Fixed
/// inputs only (no clock, no database).
@Suite("CategoryFilter")
struct CategoryFilterTests {
    private let a = UUID()
    private let b = UUID()

    @Test("`.all` shows everything, including uncategorised")
    func allShowsEverything() {
        #expect(CategoryFilter.all.matches(categoryID: nil))
        #expect(CategoryFilter.all.matches(categoryID: a))
        #expect(!CategoryFilter.all.hides(categoryID: b))
    }

    @Test("a selected set shows only the chosen categories and (optionally) uncategorised")
    func selected() {
        let onlyA = CategoryFilter(mode: .selected, categoryIDs: [a], includesUncategorized: false)
        #expect(onlyA.matches(categoryID: a))
        #expect(!onlyA.matches(categoryID: b))
        #expect(!onlyA.matches(categoryID: nil))

        let withUncat = CategoryFilter(mode: .selected, categoryIDs: [a], includesUncategorized: true)
        #expect(withUncat.matches(categoryID: nil))
        #expect(!withUncat.matches(categoryID: b))
    }

    @Test("an empty selection is a deliberate 'show nothing', not 'show everything'")
    func emptySelectionShowsNothing() {
        let none = CategoryFilter(mode: .selected, categoryIDs: [], includesUncategorized: false)
        #expect(none.showsNothing)
        #expect(none.hides(categoryID: a))
        #expect(none.hides(categoryID: nil))
        #expect(!CategoryFilter.all.showsNothing)
    }

    @Test("reveal pulls a filtered-out category into view but never narrows `.all`")
    func reveal() {
        var filter = CategoryFilter(mode: .selected, categoryIDs: [a], includesUncategorized: false)
        filter.reveal(categoryID: b)
        #expect(filter.matches(categoryID: b))
        filter.reveal(categoryID: nil)
        #expect(filter.matches(categoryID: nil))

        var all = CategoryFilter.all
        all.reveal(categoryID: a)
        #expect(all == .all)      // revealing while showing everything is a no-op
    }

    @Test("deleting a category drops it from the persisted selection")
    func removeCategory() {
        var filter = CategoryFilter(mode: .selected, categoryIDs: [a, b], includesUncategorized: false)
        filter.removeCategory(a)
        #expect(filter.categoryIDs == [b])
        #expect(!filter.matches(categoryID: a))
    }

    @Test("the filter round-trips through JSON (persistence across relaunch)")
    func codableRoundTrip() throws {
        let filter = CategoryFilter(mode: .selected, categoryIDs: [a, b], includesUncategorized: true)
        let data = try JSONEncoder().encode(filter)
        #expect(try JSONDecoder().decode(CategoryFilter.self, from: data) == filter)
    }
}
