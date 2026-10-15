import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A borderless, transparent, auto-growing multiline text editor backed by `NSTextView`.
///
/// We use AppKit here rather than SwiftUI's `TextField(axis: .vertical)` because, on macOS, that
/// control neither reliably inserts line breaks nor lets us intercept Tab (the AppKit key-view loop
/// swallows it before SwiftUI's `.onKeyPress` runs). An `NSTextView` subclass that overrides
/// `keyDown` gives deterministic control:
///   • **Return** → `onCommit` (finish)            • **Shift/Option-Return** → insert a line break
///   • **Shift-Tab** → `onIndent` (nest deeper)    • **Ctrl-Shift-Tab** → `onOutdent` (promote)
///   • **⌘Return** → `onAddTask` (sibling below)   • **⇧⌘Return** → `onAddSubtask` (child below)
///   • **Esc** → `onCommit`
/// It grows to fit its content via `sizeThatFits` and commits on focus loss.
struct PlainTextEditor: NSViewRepresentable {
    /// Vertical inset above the first text line (matches `textContainerInset.height`); used to align
    /// an adjacent checkbox/icon to the editor's first baseline.
    static let topInset: CGFloat = 2

    @Binding var text: String
    var textColor: Color
    var font: NSFont = .preferredFont(forTextStyle: .body)
    /// Grab the keyboard as soon as the view appears (true for tap-to-edit rows, false for the
    /// always-present quick-add field, which should only focus on click).
    var autoFocus: Bool = false
    /// Bump to make the editor take the keyboard on demand (e.g. an image pasted with nothing focused).
    var focusRequest = 0
    var onCommit: () -> Void = {}
    /// Fired *only* on a plain Return — not on Esc or focus loss (both of which call `onCommit`). Lets
    /// a caller distinguish "the user pressed Return to move on" from "editing ended", e.g. to open
    /// the next row in a rapid-add flow without a blur/Esc spuriously triggering it.
    var onSubmit: () -> Void = {}
    var onIndent: () -> Void = {}
    var onOutdent: () -> Void = {}
    /// Fired on ⌘Return — "add a task below this one, at the same level".
    var onAddTask: () -> Void = {}
    /// Fired on ⇧⌘Return — "add a subtask under this one".
    var onAddSubtask: () -> Void = {}
    /// Fired when the editor gains (`true`) / loses (`false`) first-responder, so the note can show
    /// its contextual shortcut hints only while a field is actually being edited.
    var onFocusChange: (Bool) -> Void = { _ in }
    /// When set, ⌘V with an image on the clipboard hands the image here instead of pasting text.
    var onPasteImage: ((Data) -> Void)?

    func makeNSView(context: Context) -> EditorTextView {
        let view = EditorTextView()
        // Stay on the default text engine (TextKit 2 on macOS 14+). Reaching for `layoutManager`
        // forces a half-migrated TextKit 1 fallback, and that legacy compatibility path is what was
        // breaking the input method here — the Pinyin candidate window never appeared. Height is now
        // measured against whichever engine is active (see `fittingHeight`).
        view.delegate = context.coordinator
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        configure(view)
        view.string = text
        // Grab focus once the view is actually in a window (see `EditorTextView.viewDidMoveToWindow`).
        // The window-entry hook fires the moment the (eagerly-realised, non-lazy) row attaches to the
        // window — reliable regardless of whether the row is on screen yet. A one-shot
        // `makeFirstResponder` here would no-op for a row created off-screen.
        view.autoFocusesOnAppear = autoFocus
        return view
    }

    func updateNSView(_ view: EditorTextView, context: Context) {
        // Leave a composing editor completely alone — see `configure`. Reassigning `string` or the
        // text attributes mid-composition would drop the IME's marked text and its candidate window.
        if !view.hasMarkedText() {
            if view.string != text { view.string = text }
            configure(view)
        }
        if focusRequest != context.coordinator.focusRequest {
            context.coordinator.focusRequest = focusRequest
            // Deferred: taking first responder mid-update would fire `onFocusChange` during a view update.
            Task { @MainActor in view.window?.makeFirstResponder(view) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return CGSize(width: width, height: nsView.fittingHeight(forWidth: width))
    }

    private func configure(_ view: EditorTextView) {
        // The action closures are cheap and must always be current.
        view.onCommit = onCommit
        view.onSubmit = onSubmit
        view.onIndent = onIndent
        view.onOutdent = onOutdent
        view.onAddTask = onAddTask
        view.onAddSubtask = onAddSubtask
        view.onFocusChange = onFocusChange
        view.onPasteImage = onPasteImage
        // Never touch the text attributes while an input method is composing. `updateNSView` runs on
        // every SwiftUI re-render — and typing fires `textDidChange` → a re-render each keystroke — so
        // reassigning `font`/`textColor` (or the rich-text flags) mid-composition rewrites the text
        // storage, drops the marked text, and dismisses the IME's candidate window. Leave everything
        // alone until the composition ends.
        guard !view.hasMarkedText() else { return }
        view.font = font
        view.textColor = NSColor(textColor)
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.isRichText = false
        view.isEditable = true
        view.isSelectable = true
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isHorizontallyResizable = false
        view.textContainerInset = NSSize(width: 0, height: Self.topInset)
        view.textContainer?.lineFragmentPadding = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focusRequest: focusRequest) }

    /// Distance from the editor's top to its first text line's baseline, for baseline alignment.
    var firstBaseline: CGFloat { Self.topInset + font.ascender }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        /// The last `focusRequest` acted on (starts at the initial value, so creating the view doesn't focus).
        var focusRequest: Int

        init(text: Binding<String>, focusRequest: Int) {
            _text = text
            self.focusRequest = focusRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text = view.string
        }

        func textDidEndEditing(_ notification: Notification) {
            (notification.object as? EditorTextView)?.onCommit()
        }
    }
}

/// `NSTextView` subclass that routes the editor's key chords to closures and reports the height it
/// needs for a given width so SwiftUI can lay it out.
final class EditorTextView: NSTextView {
    var onCommit: () -> Void = {}
    var onSubmit: () -> Void = {}
    var onIndent: () -> Void = {}
    var onOutdent: () -> Void = {}
    var onAddTask: () -> Void = {}
    var onAddSubtask: () -> Void = {}
    var onFocusChange: (Bool) -> Void = { _ in }
    var onPasteImage: ((Data) -> Void)?

    /// When true, the view makes itself first responder the first time it lands in a window.
    var autoFocusesOnAppear = false
    private var didAutoFocus = false

    /// Grabs first-responder a single time, once the view is in a window and not already focused.
    /// Driven by `viewDidMoveToWindow`, which fires the moment the (eagerly-realised) row attaches to
    /// the window — so it works whether or not the row is on screen yet. Bringing the row into view is
    /// left to SwiftUI's `ScrollViewReader`: an AppKit `scrollToVisible` is a no-op inside a SwiftUI
    /// `ScrollView`, which owns the clip view's content offset and reasserts it on the next layout.
    func focusIfNeeded() {
        guard autoFocusesOnAppear, !didAutoFocus, let window, window.firstResponder !== self else { return }
        didAutoFocus = true
        window.makeFirstResponder(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfNeeded()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange(false) }
        return ok
    }

    private enum Key {
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let tab: UInt16 = 48
        static let escape: UInt16 = 53
    }

    override func keyDown(with event: NSEvent) {
        // While an input method (e.g. Pinyin) is composing, the keys belong to the IME, not to us.
        // Return confirms the candidate — it must not commit the row and end editing; Tab is often
        // the candidate pager. Hand everything straight to normal key handling so the input context
        // receives it; our own chords resume once the composition is gone.
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case Key.tab where mods.contains(.shift):
            if mods.contains(.control) { onOutdent() } else { onIndent() }
        case Key.returnKey, Key.keypadEnter:
            if mods.contains(.command) {
                // ⌘Return adds a sibling at this level; ⇧⌘Return adds a subtask under this row.
                // Both commit *this* row first, so the new row lands after whatever was typed.
                if mods.contains(.shift) { onAddSubtask() } else { onAddTask() }
            } else if mods.contains(.shift) || mods.contains(.option) {
                insertText("\n", replacementRange: selectedRange())
            } else {
                onCommit()
                onSubmit()   // Return-only; lets callers continue (e.g. open the next add row)
            }
        case Key.escape:
            // A composing IME consumes Esc itself (it's handled by the `hasMarkedText()` branch
            // above, which never reaches here while composing), so this is always a real cancel.
            onCommit()
        default:
            super.keyDown(with: event)
        }
    }

    override func paste(_ sender: Any?) {
        if let onPasteImage, let data = NSPasteboard.general.pastableImageData() {
            onPasteImage(data)
        } else {
            super.paste(sender)
        }
    }

    /// A plain-text view disables Paste when the clipboard holds only an image; re-enable it for one.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), onPasteImage != nil, NSPasteboard.general.hasPastableImage {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The container doesn't track our width on its own (widthTracksTextView is off), so keep it
        // in sync with the real frame — otherwise text wraps at a stale, narrower width.
        if let container = textContainer, container.containerSize.width != newSize.width {
            container.containerSize = NSSize(width: newSize.width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    /// Fallback height (used if SwiftUI consults intrinsic size before `sizeThatFits`).
    override var intrinsicContentSize: NSSize {
        let width = bounds.width > 0 ? bounds.width : (textContainer?.containerSize.width ?? 0)
        return NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight(forWidth: width))
    }

    /// Height needed to lay the current text out at `width`, clamped to at least one line.
    ///
    /// Reads whichever text engine is active. We no longer force TextKit 1 (that legacy fallback
    /// broke the input method), so we prefer TextKit 2's `textLayoutManager` and only fall back to
    /// the TextKit 1 `layoutManager` when the system actually gave us one. Both paths lay the text out
    /// at `width` first, since width tracking is off and the engine's cached layout may be stale.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer else { return lineHeight }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        let used: CGFloat
        if let textLayoutManager {
            textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
            used = textLayoutManager.usageBoundsForTextContainer.height
        } else if let layoutManager {
            layoutManager.ensureLayout(for: container)
            used = layoutManager.usedRect(for: container).height
        } else {
            used = lineHeight
        }
        return ceil(max(used, lineHeight)) + textContainerInset.height * 2
    }

    private var lineHeight: CGFloat {
        guard let font else { return 16 }
        return layoutManager?.defaultLineHeight(for: font) ?? ceil(font.ascender - font.descender + font.leading)
    }
}

extension NSPasteboard {
    /// Matches only image *files* (e.g. a Finder copy).
    private var imageFileOptions: [ReadingOptionKey: Any] {
        [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier]]
    }

    /// Cheap check (no decoding) for whether ⌘V should paste an image rather than text. An image file
    /// wins even though Finder also puts its filename on the clipboard as text; raw image data counts
    /// only when there's no plain text alongside it, so copying text that carries a picture pastes text.
    var hasPastableImage: Bool {
        canReadObject(forClasses: [NSURL.self], options: imageFileOptions)
            || (string(forType: .string) == nil && availableType(from: [.png, .tiff]) != nil)
    }

    /// The image ⌘V should paste, normalised for storage (`TaskImage.normalizedData`), or nil for a
    /// text paste. Takes the first image when several files are copied.
    func pastableImageData() -> Data? {
        if let url = (readObjects(forClasses: [NSURL.self], options: imageFileOptions) as? [URL])?.first {
            return (try? Data(contentsOf: url)).flatMap(TaskImage.normalizedData)
        }
        guard string(forType: .string) == nil,
              let type = availableType(from: [.png, .tiff]),
              let data = data(forType: type) else { return nil }
        return TaskImage.normalizedData(data)
    }
}

extension View {
    /// Aligns this view's `firstTextBaseline` to a sibling `PlainTextEditor`'s first text line.
    /// The editor's `NSView` reports no text baseline, so without this an adjacent checkbox/icon in
    /// an `HStack(alignment: .firstTextBaseline)` hangs below the editor's empty box.
    @MainActor
    func editorFirstBaseline(font: NSFont = .preferredFont(forTextStyle: .body)) -> some View {
        // Resolve the baseline up front so the (`@Sendable`) alignment-guide closure captures only a
        // plain CGFloat — not the non-Sendable NSFont or the main-actor `topInset`.
        let baseline = PlainTextEditor.topInset + font.ascender
        return alignmentGuide(.firstTextBaseline) { _ in baseline }
    }
}
