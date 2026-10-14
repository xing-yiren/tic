import SwiftUI

/// Manage categories: create, rename, reorder, delete. Deleting a category never deletes its notes —
/// they fall back to "Uncategorised". A shared, centered floating panel like the other aux windows.
struct CategoryManagementView: View {
    private var model: AppModel { AppModel.shared }

    @State private var newName = ""
    @State private var editingID: UUID?
    @State private var editingName = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Categories")
                .font(.title2.weight(.semibold))

            addRow

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            list

            Spacer(minLength: 0)

            HStack {
                Text("New notes default to the selected category.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { model.dismissCategories() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420, height: 460, alignment: .topLeading)
        .background(NoteBackground(color: .graphite, material: .glass))
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("New category name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var list: some View {
        List {
            ForEach(model.categories) { category in
                row(category)
            }
            if model.categories.isEmpty {
                Text("No categories yet.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func row(_ category: Category) -> some View {
        HStack(spacing: 8) {
            if editingID == category.id {
                TextField("", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(category) }
                Button("Save") { commitRename(category) }
                    .controlSize(.small)
                Button("Cancel") { editingID = nil }
                    .controlSize(.small)
            } else {
                Text(category.name)
                Spacer()
                Button {
                    editingID = category.id
                    editingName = category.name
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Rename")

                Button(role: .destructive) {
                    Task { await model.deleteCategory(id: category.id) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete (notes move to Uncategorised)")
            }
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            do {
                _ = try await model.createCategory(name: name)
                newName = ""
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func commitRename(_ category: Category) {
        let name = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await model.renameCategory(id: category.id, name: name)
                editingID = nil
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
