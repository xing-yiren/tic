import SwiftUI

/// A compact category chip for a note header: shows the note's category (or "Uncategorised") and opens
/// a popover to switch it. Also lets you create a category inline, so filing a note never requires a
/// detour through the management window.
struct CategoryPicker: View {
    let controller: NoteController
    let theme: NoteTheme

    @State private var showPicker = false
    @State private var newName = ""
    @State private var errorMessage: String?

    private var model: AppModel { AppModel.shared }

    private var currentName: String {
        guard let id = controller.note.categoryID,
              let category = model.categories.first(where: { $0.id == id }) else { return "Uncategorised" }
        return category.name
    }

    private var isUncategorised: Bool { controller.note.categoryID == nil }

    var body: some View {
        Button {
            showPicker.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tag")
                    .font(.system(size: 9, weight: .medium))
                Text(currentName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isUncategorised ? theme.secondary : theme.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(theme.accent.opacity(isUncategorised ? 0.10 : 0.18))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Category — click to change")
        .popover(isPresented: $showPicker, arrowEdge: .bottom) { picker }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Category")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                option("Uncategorised", selected: isUncategorised) {
                    controller.setCategory(nil)
                    showPicker = false
                }
                ForEach(model.categories) { category in
                    option(category.name, selected: controller.note.categoryID == category.id) {
                        controller.setCategory(category.id)
                        showPicker = false
                    }
                }
            }

            Divider()

            HStack(spacing: 6) {
                TextField("New category", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(createAndAssign)
                Button("Add", action: createAndAssign)
                    .controlSize(.small)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(width: 240)
    }

    private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark") }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func createAndAssign() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            do {
                let category = try await model.createCategory(name: name)
                controller.setCategory(category.id)
                newName = ""
                errorMessage = nil
                showPicker = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
