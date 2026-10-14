import Foundation

/// Which notes the desktop should show, by category. Persisted so the selection survives relaunch.
///
/// The two states are kept deliberately distinct (per the design): `.all` means *no restriction*
/// (every note that is open shows), whereas `.selected` with an empty set means *show nothing*.
/// "Uncategorised" is a first-class option in the set, represented by `includesUncategorized`.
struct CategoryFilter: Equatable, Codable, Sendable {
    enum Mode: String, Codable, Sendable { case all, selected }

    var mode: Mode
    /// Category ids to show when `mode == .selected`.
    var categoryIDs: Set<UUID>
    /// Whether uncategorised notes (`categoryID == nil`) show when `mode == .selected`.
    var includesUncategorized: Bool

    static let all = CategoryFilter(mode: .all, categoryIDs: [], includesUncategorized: true)

    init(mode: Mode = .all, categoryIDs: Set<UUID> = [], includesUncategorized: Bool = true) {
        self.mode = mode
        self.categoryIDs = categoryIDs
        self.includesUncategorized = includesUncategorized
    }

    /// Whether a note with `categoryID` (nil = uncategorised) should be shown.
    func matches(categoryID: UUID?) -> Bool {
        switch mode {
        case .all:
            return true
        case .selected:
            guard let categoryID else { return includesUncategorized }
            return categoryIDs.contains(categoryID)
        }
    }

    /// A note is hidden only when the filter is restrictive *and* it doesn't match. Used by the
    /// window coordinator to decide `orderOut` vs. restore.
    func hides(categoryID: UUID?) -> Bool { !matches(categoryID: categoryID) }

    /// Adds a category to the visible set, switching to `.selected` if we were showing everything —
    /// used when a note in a filtered-out category is opened explicitly (so it becomes visible).
    mutating func reveal(categoryID: UUID?) {
        if mode == .all { return }   // everything is already visible
        if let categoryID { categoryIDs.insert(categoryID) } else { includesUncategorized = true }
    }

    /// Removes a category that no longer exists from a persisted selection.
    mutating func removeCategory(_ id: UUID) { categoryIDs.remove(id) }

    /// True when nothing at all would be shown (an empty `.selected` selection).
    var showsNothing: Bool { mode == .selected && categoryIDs.isEmpty && !includesUncategorized }
}

/// Persists the category filter in `UserDefaults` (JSON-encoded), so the selection survives relaunch
/// while "hide everything" stays a *session* toggle handled separately.
enum CategoryFilterStore {
    private static let key = "categoryFilter"

    static func load(from defaults: UserDefaults = .standard) -> CategoryFilter {
        guard let data = defaults.data(forKey: key),
              let filter = try? JSONDecoder().decode(CategoryFilter.self, from: data) else {
            return .all
        }
        return filter
    }

    static func save(_ filter: CategoryFilter, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(filter) else { return }
        defaults.set(data, forKey: key)
    }
}
