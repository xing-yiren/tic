import SwiftUI

/// The Overview window: every list grouped under its category, with a per-list switch that puts the
/// note on the desktop (or takes it off). This is the "see everything at a glance" surface the
/// desktop panels alone can't give you — categories down the page, their lists beneath them, and a
/// single obvious place to choose what shows on the desktop, create a list, or manage categories.
struct OverviewView: View {
    private var model: AppModel { AppModel.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            content
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 620, height: 560)
        .background(NoteBackground(color: .graphite, material: .glass))
        .onExitCommand { model.dismissOverview() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Overview")
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                model.newNote()
            } label: {
                Label("New List", systemImage: "plus")
            }
            .help("Create a new list (⌘N)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var subtitle: String {
        let total = model.notes.count
        let onDesktop = model.notes.filter(\.isOpen).count
        let lists = total == 1 ? "1 list" : "\(total) lists"
        let cats = model.categories.count == 1 ? "1 category" : "\(model.categories.count) categories"
        return "\(lists) across \(cats) · \(onDesktop) on the desktop"
    }

    // MARK: - Grouped list

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(groups) { group in
                    groupHeader(group)
                    if group.notes.isEmpty {
                        Text("No lists in this category")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 22)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(group.notes) { note in
                            row(note)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: .infinity)
    }

    private func groupHeader(_ group: Group) -> some View {
        HStack(spacing: 8) {
            Image(systemName: group.isUncategorized ? "tray" : "folder")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(group.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("\(group.notes.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    private func row(_ note: Note) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(note.color.fill)
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.black.opacity(0.15)))

            Text(title(note))
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                model.open(note)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Bring this list to the front")

            // The "should this note appear on the desktop" switch. It writes the note's own
            // `isOpen` flag through the same open/close path the menu bar and the header X use, so
            // launch restores exactly the notes left switched on here.
            Toggle("", isOn: Binding(
                get: { note.isOpen },
                set: { model.setOnDesktop(note, visible: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(note.isOpen ? "Showing on the desktop" : "Hidden from the desktop")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                model.newNote()
            } label: {
                Label("New List", systemImage: "plus")
            }
            shortcutHint("⌘N")

            Button("Manage Categories…") { model.openCategories() }

            Spacer()

            Button("Done") { model.dismissOverview() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.04))
    }

    private func shortcutHint(_ key: String) -> some View {
        Text(key)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.secondary)
    }

    // MARK: - Grouping

    private struct Group: Identifiable {
        let id: String
        let title: String
        let notes: [Note]
        var isUncategorized = false
    }

    /// Categories in their user order, each with its lists; "Uncategorised" trails them. A note whose
    /// category id no longer resolves (defensive) is treated as uncategorised rather than dropped.
    private var groups: [Group] {
        let cats = model.categories
        let liveIDs = Set(cats.map(\.id))
        var result = cats.map { category in
            Group(
                id: category.id.uuidString,
                title: category.name,
                notes: model.notes.filter { $0.categoryID == category.id }
            )
        }
        let uncategorized = model.notes.filter { note in
            guard let id = note.categoryID else { return true }
            return !liveIDs.contains(id)
        }
        if !uncategorized.isEmpty || result.isEmpty {
            result.append(Group(id: "uncategorised", title: "Uncategorised", notes: uncategorized, isUncategorized: true))
        }
        return result
    }

    private func title(_ note: Note) -> String {
        note.title.isEmpty ? "Untitled List" : note.title
    }
}
