import SwiftUI

/// The hover-reveal control strip + editable title for a sticky note. Controls fade in/out via
/// `isRevealed` (driven by `NoteView`'s hover over the whole note), so the affordances stay
/// hidden until the pointer is on the note — keeping the small note uncluttered.
struct NoteHeaderView: View {
    @Bindable var controller: NoteController
    let theme: NoteTheme
    let isRevealed: Bool

    @Binding var titleText: String
    @FocusState.Binding var titleFocused: Bool

    @State private var showColorPopover = false
    @State private var showCompletedPopover = false
    @State private var showClearConfirm = false
    @State private var showHelp = false
    @State private var hoverClose = false

    private var note: Note { controller.note }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controlStrip
                .opacity(isRevealed ? 1 : 0)
                .allowsHitTesting(isRevealed)

            TextField("", text: $titleText)
                .textFieldStyle(.plain)
                .font(.headline.weight(.semibold))
                .foregroundStyle(theme.title)
                .focused($titleFocused)
                .overlay(alignment: .leading) {
                    if titleText.isEmpty {
                        Text("Untitled List")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(theme.secondary)
                            .padding(.leading, 2)   // align with the field's text/caret inset
                            .allowsHitTesting(false)
                    }
                }
                .onSubmit { commitTitle() }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { commitTitle() }
                }

            CategoryPicker(controller: controller, theme: theme)
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(theme.accent.opacity(0.35))
                .frame(height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        // The header is the window's drag handle; double-clicking its chrome rolls the note up.
        .background(WindowMoveArea { controller.toggleCollapsed() })
    }

    /// Commit the title, normalising the field to the trimmed value so a whitespace-only entry
    /// becomes empty and the "Untitled List" placeholder reappears.
    private func commitTitle() {
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != titleText { titleText = trimmed }
        controller.commitTitle(trimmed)
    }

    // MARK: - Control strip

    private var controlStrip: some View {
        HStack(spacing: 10) {
            newNoteButton
            colorButton
            materialButton
            completedButton
            if controller.completedCount > 0 { clearButton }
            Spacer(minLength: 0)
            helpButton
            collapseButton
            floatButton
            closeButton
        }
        .frame(height: 22)
        .animation(.easeInOut(duration: 0.15), value: isRevealed)
        .animation(.easeInOut(duration: 0.15), value: controller.completedCount > 0)
        .confirmationDialog(
            "Delete \(controller.completedCount) completed task\(controller.completedCount == 1 ? "" : "s")? "
                + "This can't be undone.",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { controller.clearCompleted() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var newNoteButton: some View {
        iconButton(systemName: "plus", isActive: false, help: "New list") {
            controller.requestNewNote()
        }
    }

    private var colorButton: some View {
        Button {
            showColorPopover.toggle()
        } label: {
            Circle()
                .fill(theme.accent)
                .frame(width: 13, height: 13)
                .overlay(Circle().strokeBorder(theme.secondary.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help("List color")
        .popover(isPresented: $showColorPopover, arrowEdge: .bottom) { colorPicker }
    }

    private var colorPicker: some View {
        let columns = Array(repeating: GridItem(.fixed(26), spacing: 8), count: 3)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(NoteColor.allCases) { swatch in
                Button {
                    controller.setColor(swatch)
                    showColorPopover = false
                } label: {
                    Circle()
                        .fill(swatch.fill)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle().strokeBorder(
                                swatch == note.color ? swatch.accent : Color.black.opacity(0.12),
                                lineWidth: swatch == note.color ? 2.5 : 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .help(swatch.displayName)
            }
        }
        .padding(12)
    }

    private var materialButton: some View {
        let isGlass = note.material == .glass
        return iconButton(
            systemName: isGlass ? "sparkles" : "circle.hexagongrid",
            isActive: isGlass,
            help: isGlass ? "Switch to solid" : "Switch to glass"
        ) {
            controller.toggleMaterial()
        }
    }

    private var completedButton: some View {
        let isActive = note.hideCompleted || note.moveCompletedToBottom
        return Button {
            showCompletedPopover.toggle()
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? theme.accent : theme.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Completed task options")
        .popover(isPresented: $showCompletedPopover, arrowEdge: .bottom) { completedOptionsMenu }
    }

    /// The two per-note display toggles. `note` is `private(set)`, so each `Toggle` writes through the
    /// controller's toggle method (the binding's incoming value is ignored — the method flips + persists).
    private var completedOptionsMenu: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Hide completed", isOn: Binding(
                get: { note.hideCompleted },
                set: { _ in controller.toggleHideCompleted() }
            ))
            Toggle("Move completed to bottom", isOn: Binding(
                get: { note.moveCompletedToBottom },
                set: { _ in controller.toggleMoveCompletedToBottom() }
            ))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.callout)
        .tint(theme.accent)
        .padding(14)
        .frame(width: 240)
    }

    private var clearButton: some View {
        // A "tidy up" wand rather than a trash can — this clears finished items, it isn't a delete.
        iconButton(systemName: "wand.and.sparkles", isActive: false, help: "Clean up completed tasks") {
            showClearConfirm = true
        }
    }

    private var collapseButton: some View {
        iconButton(systemName: "chevron.up", isActive: false, help: "Roll up (collapse)") {
            controller.toggleCollapsed()
        }
    }

    /// A "keyboard shortcuts" popover. The task-row chords (nest / add task / add subtask) used to be
    /// shown inline while editing, but they crowded the text field; this keeps them discoverable
    /// without stealing space from what you're typing.
    private var helpButton: some View {
        Button { showHelp.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(showHelp ? theme.accent : theme.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Keyboard shortcuts")
        .popover(isPresented: $showHelp, arrowEdge: .bottom) { shortcutList }
    }

    private var shortcutList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard shortcuts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            shortcut("Return", "Save and start the next task")
            shortcut("⇧Return", "New line inside a task")
            shortcut("⇧Tab", "Nest — make a subtask")
            shortcut("⌃⇧Tab", "Un-nest — promote a level")
            shortcut("⌘Return", "New task at this level")
            shortcut("⇧⌘Return", "New subtask under this one")
            shortcut("Esc", "Stop editing")
        }
        .padding(14)
        .frame(width: 260)
    }

    private func shortcut(_ glyphs: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(glyphs)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(theme.accent.opacity(0.13))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(theme.accent.opacity(0.22), lineWidth: 0.5)
                )
                .frame(width: 66, alignment: .leading)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.secondary)
            Spacer(minLength: 0)
        }
    }

    private var floatButton: some View {
        let isFloating = note.floatOnTop
        return iconButton(
            systemName: isFloating ? "pin.fill" : "pin",
            isActive: isFloating,
            help: isFloating ? "Unpin from top" : "Keep on top"
        ) {
            controller.toggleFloatOnTop()
        }
    }

    private var closeButton: some View {
        Button {
            controller.requestClose()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hoverClose ? Color.red : theme.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverClose = $0 }
        .help("Close list")
    }

    private func iconButton(
        systemName: String,
        isActive: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? theme.accent : theme.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
