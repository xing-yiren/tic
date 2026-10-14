import SwiftUI

/// A single checklist row. Shows the task as rendered inline **Markdown** (bold, *italic*,
/// `code`, ~~strike~~, [links]) across as many lines as it has; tap the text to edit the raw
/// source in a plain, growing text box. While editing, **Return** commits and **Shift-Return**
/// (or Option-Return) inserts a newline; **Shift-Tab** nests the task one level deeper and
/// **Ctrl-Shift-Tab** promotes it back out. Editing commits on Return or when focus leaves.
/// Hover reveals a ✕ delete button; the "Add subtask" affordance lives at the bottom of the hovered
/// heading's group and is rendered by `NoteView` (this row just reports its hover state up).
struct TaskRowView: View {
    let task: TaskItem
    let theme: NoteTheme
    /// True while this row is the active rapid-add target: it begins editing as soon as it appears —
    /// and again if the list scrolls and the LazyVStack recreates it — so a freshly-added subtask
    /// keeps the keyboard and typing flows uninterrupted. The parent clears it when the run ends.
    let autoEdit: Bool
    let onToggle: () -> Void
    let onCommit: (String) -> Void
    let onDelete: () -> Void
    let onIndent: () -> Void
    let onOutdent: () -> Void
    /// Fired when the user commits this row with Return (not Esc / focus loss). Used to chain the
    /// next subtask in the rapid-add flow.
    let onSubmit: () -> Void
    /// Reports hover enter/leave up to the list, which uses it to reveal the "Add subtask" affordance
    /// at the bottom of the hovered heading's group.
    let onHoverChanged: (Bool) -> Void
    /// The task's pasted image (built by `NoteView`), shown under the text; nil when it has none.
    let image: TaskImageView?
    /// ⌘V of an image while this row is being edited attaches it to the task.
    let onPasteImage: (Data) -> Void
    /// The task's reminder (nil = none), and callbacks to set/clear the deadline + reminder.
    var reminder: TaskReminder?
    var isOverdue = false
    var onSetDue: ((Date?) -> Void)?
    var onSetReminder: ((Date?) -> Void)?

    @State private var draft: String
    @State private var editing = false
    @State private var hovering = false
    @State private var showDueEditor = false
    // Memoises the parsed Markdown so it isn't re-parsed on every re-render (e.g. each frame of a
    // drag), which otherwise makes reordering feel laggy.
    @State private var renderCache = MarkdownRenderCache()

    /// Where the text column starts — the 16pt checkbox glyph plus the row's spacing — so the image lines up.
    private static let textInset: CGFloat = 24

    init(
        task: TaskItem,
        theme: NoteTheme,
        autoEdit: Bool = false,
        onToggle: @escaping () -> Void,
        onCommit: @escaping (String) -> Void,
        onDelete: @escaping () -> Void,
        onIndent: @escaping () -> Void,
        onOutdent: @escaping () -> Void,
        onSubmit: @escaping () -> Void = {},
        onHoverChanged: @escaping (Bool) -> Void = { _ in },
        image: TaskImageView? = nil,
        onPasteImage: @escaping (Data) -> Void = { _ in },
        reminder: TaskReminder? = nil,
        isOverdue: Bool = false,
        onSetDue: ((Date?) -> Void)? = nil,
        onSetReminder: ((Date?) -> Void)? = nil
    ) {
        self.task = task
        self.theme = theme
        self.autoEdit = autoEdit
        self.onToggle = onToggle
        self.onCommit = onCommit
        self.onDelete = onDelete
        self.onIndent = onIndent
        self.onOutdent = onOutdent
        self.onSubmit = onSubmit
        self.onHoverChanged = onHoverChanged
        self.image = image
        self.onPasteImage = onPasteImage
        self.reminder = reminder
        self.isOverdue = isOverdue
        self.onSetDue = onSetDue
        self.onSetReminder = onSetReminder
        _draft = State(initialValue: task.text)
    }

    private var baseColor: Color { task.isDone ? theme.completed : theme.task }
    private var canNestDeeper: Bool { task.indentLevel < TaskItem.maxIndentLevel }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Hover is tracked on the text line only. Over an image it would reveal the ✕ and the section's
            // "Add subtask" row, and either shifts the layout under a pointer resting on a tall picture.
            taskRow
                .onHover { isHovering in
                    withAnimation(.easeInOut(duration: 0.12)) { hovering = isHovering }
                    onHoverChanged(isHovering)
                }
            if hasScheduling {
                deadlineChip.padding(.leading, Self.textInset)
            }
            // Below the text line's HStack, so the ✕ / nest hint appearing can't narrow a fill-width image —
            // which would shorten the row under the pointer and make the hover flicker on and off.
            image
                .opacity(task.isDone ? 0.6 : 1)
                .padding(.leading, Self.textInset)
        }
        .padding(.vertical, 2)
        .padding(.leading, CGFloat(task.indentLevel) * NoteLayout.indentStep)
        .contentShape(Rectangle())
        // The deadline/reminder popover is anchored to the *row* rather than to the hover-revealed
        // calendar button or the deadline chip. Those controls mount and unmount as the pointer
        // moves (and as `hasScheduling` flips), and a popover whose anchor disappears is torn down —
        // so moving the mouse toward the popover, or setting a deadline that makes the chip appear
        // and shift the layout, used to make it vanish mid-interaction. The row itself is always in
        // the hierarchy, so the popover stays put until the user dismisses it.
        .popover(isPresented: $showDueEditor, arrowEdge: .bottom) { dueEditor }
            // Begin editing whenever this becomes (or re-becomes, after a scroll recreates the row)
            // the active add target. `beginEditing` is a no-op once already editing, so a plain
            // re-render won't disturb an in-progress edit — only a fresh appearance re-triggers it.
            .onAppear { if autoEdit { beginEditing() } }
            .onChange(of: autoEdit) { _, shouldEdit in
                if shouldEdit { beginEditing() }
            }
    }

    private var taskRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(task.isDone ? theme.checkbox : theme.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            content
                .frame(maxWidth: .infinity, alignment: .leading)

            if editing {
                // Minimal hint: the nest shortcut, shown only while this row is being edited.
                if canNestDeeper {
                    ShortcutHint(glyphs: "⇧⇥", label: "nest", theme: theme)
                }
            } else if hovering {
                if onSetDue != nil {
                    Button { showDueEditor = true } label: {
                        Image(systemName: reminder != nil ? "bell.badge" : "calendar.badge.clock")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondary.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Deadline & reminder")
                }
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Delete task")
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Deadline & reminder

    private var hasScheduling: Bool { task.dueAt != nil || reminder != nil }

    /// The compact chip under a row's text showing the deadline (red when overdue) and whether a
    /// reminder is set. Clicking it opens the editor.
    private var deadlineChip: some View {
        Button { showDueEditor = true } label: {
            HStack(spacing: 5) {
                if let due = task.dueAt {
                    Label(Self.dueFormatter.string(from: due), systemImage: "calendar")
                        .font(.caption2.weight(.medium))
                }
                if let remindAt = reminder?.remindAt {
                    Label(Self.compactFormatter.string(from: remindAt), systemImage: "bell.fill")
                        .font(.caption2)
                }
            }
            .foregroundStyle(chipColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(chipColor.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Deadline & reminder")
    }

    private var chipColor: Color {
        if isOverdue { return .red }
        if task.dueAt != nil { return theme.accent }
        return theme.secondary
    }

    /// Due date + reminder time: two independent fields (an early reminder never moves the DDL), each
    /// clearable. "Remind" defaults to the deadline so setting a DDL offers a reminder in one step.
    private var dueEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(task.text.isEmpty ? "Task" : task.text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(width: 260, alignment: .leading)

            Toggle("Deadline", isOn: Binding(
                get: { task.dueAt != nil },
                set: { enabled in
                    if enabled {
                        let base = task.dueAt ?? Self.defaultDueDate()
                        onSetDue?(base)
                        if reminder == nil { onSetReminder?(base) }
                    } else {
                        onSetDue?(nil)
                        onSetReminder?(nil)
                    }
                }
            ))
            if let due = task.dueAt {
                DatePicker("", selection: Binding(
                    get: { due },
                    set: { onSetDue?($0) }
                ), displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
            }

            Toggle("Remind me", isOn: Binding(
                get: { reminder != nil },
                set: { enabled in
                    onSetReminder?(enabled ? (task.dueAt ?? Self.defaultDueDate()) : nil)
                }
            ))
            if let remindAt = reminder?.remindAt {
                DatePicker("", selection: Binding(
                    get: { remindAt },
                    set: { onSetReminder?($0) }
                ), displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
            }

            Text("Reminders use system notifications, so they respect Do Not Disturb and may be delayed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)

            HStack {
                Spacer()
                Button("Clear") {
                    onSetDue?(nil)
                    onSetReminder?(nil)
                }
                Button("Done") { showDueEditor = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 288)
    }

    /// The deadline a fresh picker starts at: the next round hour.
    private static func defaultDueDate() -> Date {
        let cal = Calendar.current
        let next = Date().addingTimeInterval(3600)
        return cal.date(bySetting: .minute, value: 0, of: next) ?? next
    }

    private static let dueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private static let compactFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    @ViewBuilder
    private var content: some View {
        if editing {
            // A plain, vertically-growing AppKit text box: Return commits, Shift/Option-Return adds
            // a line, Shift-Tab nests, Ctrl-Shift-Tab promotes. Commits on Return / Esc / focus loss.
            PlainTextEditor(
                text: $draft,
                textColor: baseColor,
                autoFocus: true,
                onCommit: { commit() },
                onSubmit: onSubmit,
                onIndent: onIndent,
                onOutdent: onOutdent,
                onPasteImage: onPasteImage
            )
            .editorFirstBaseline()
        } else if task.text.isEmpty {
            // An image-only task: an empty line (a hint on hover) keeps the row's height steady and is
            // where you click to add text.
            Text("Add text…")
                .foregroundStyle(theme.secondary)
                .opacity(hovering ? 1 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { beginEditing() }
        } else {
            Text(renderCache.rendered(text: task.text, color: baseColor))
                .strikethrough(task.isDone, color: theme.completed.opacity(0.7))
                .opacity(task.isDone ? 0.85 : 1)
                .fixedSize(horizontal: false, vertical: true)   // wrap + grow, don't truncate
                .contentShape(Rectangle())
                .onTapGesture { beginEditing() }
        }
    }

    private func beginEditing() {
        guard !editing else { return }   // already editing: keep the in-progress draft, don't reset it
        draft = task.text
        editing = true   // PlainTextEditor grabs focus itself (autoFocus).
    }

    private func commit() {
        guard editing else { return }
        editing = false
        onCommit(draft)
    }
}

/// Caches a task's text rendered as tinted inline Markdown, re-parsing only when the text or colour
/// actually changes. Held by reference in a row's `@State` so the (relatively costly) Markdown parse
/// doesn't run on every SwiftUI body re-evaluation — notably the many re-renders during a drag.
@MainActor
final class MarkdownRenderCache {
    private var cachedText: String?
    private var cachedColor: Color?
    private var value = AttributedString()

    func rendered(text: String, color: Color) -> AttributedString {
        if text == cachedText, color == cachedColor { return value }
        value = Self.parse(text, color: color)
        cachedText = text
        cachedColor = color
        return value
    }

    /// Parses each line as inline Markdown (bold/italic/`code`/~~strike~~/links), tinting normal
    /// text to `color` and leaving links their accent. Newlines are preserved so a multiline task
    /// renders across multiple lines; each line is parsed alone so a break never merges two lines.
    private static func parse(_ text: String, color: Color) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        var result = AttributedString()
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            var attributed = (try? AttributedString(markdown: String(line), options: options))
                ?? AttributedString(String(line))
            for run in attributed.runs where run.link == nil {
                attributed[run.range].foregroundColor = color
            }
            result.append(attributed)
        }
        return result
    }
}
