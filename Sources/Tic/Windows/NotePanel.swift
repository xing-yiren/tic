import AppKit
import SwiftUI

/// A single sticky note window. A titled panel with a hidden, transparent title bar gives us
/// rounded corners, a system shadow, and edge resizing for free, while `fullSizeContentView`
/// lets the SwiftUI content cover the whole surface. `nonactivatingPanel` keeps clicking a note
/// from yanking the whole app forward — it behaves like a desktop sticky.
final class NotePanel: NSPanel {
    let noteID: UUID

    init(note: Note, content: AnyView) {
        self.noteID = note.id

        let rect = NSRect(x: note.frameX, y: note.frameY, width: note.frameW, height: note.frameH)
        super.init(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // The window is dragged only by its header (a WindowMoveArea), NOT the whole body —
        // otherwise starting a task-row drag would move the window instead of reordering.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false            // stay visible when another app is focused
        isOpaque = false
        backgroundColor = .clear             // let the SwiftUI background (incl. glass) show through
        hasShadow = true
        isReleasedWhenClosed = false         // the window manager owns the lifetime
        animationBehavior = .utilityWindow
        minSize = NSSize(width: 200, height: 160)

        // Hide the traffic-light buttons; notes get their own controls in the header.
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        // The hidden traffic-light buttons also disable the standard title-bar resize grip, so a note
        // could only be resized by its edges. Add a visible grip in the bottom-right corner (a
        // non-opaque child window, so it survives the transparent panel) that drags the frame.
        let grip = ResizeGripView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        grip.onResize = { [weak self] delta in self?.resizeBy(delta) }
        let gripWindow = NSWindow(
            contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false
        )
        gripWindow.isOpaque = false
        gripWindow.backgroundColor = .clear
        gripWindow.hasShadow = false
        gripWindow.ignoresMouseEvents = false
        gripWindow.contentView = grip
        gripWindow.isReleasedWhenClosed = false
        addChildWindow(gripWindow, ordered: .above)
        resizeGripWindow = gripWindow
        layoutResizeGrip()

        let hosting = NSHostingView(rootView: content)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting

        apply(floatOnTop: note.floatOnTop, showOnAllSpaces: note.showOnAllSpaces)
    }

    /// Applies the float-on-top and show-on-all-Spaces behaviours to the live window.
    func apply(floatOnTop: Bool, showOnAllSpaces: Bool) {
        level = floatOnTop ? .floating : .normal
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary]
        if showOnAllSpaces { behavior.insert(.canJoinAllSpaces) }
        collectionBehavior = behavior
    }

    /// Borderless/utility panels don't become key by default; we need it for text editing.
    override var canBecomeKey: Bool { true }

    // MARK: - Resize grip

    /// A small child window pinned to the bottom-right corner that drags the note's corner to
    /// resize it (the traffic lights being hidden disables the standard grip).
    private var resizeGripWindow: NSWindow?

    /// Pins the grip window to the bottom-right corner of the note, inside the frame.
    private func layoutResizeGrip() {
        guard let grip = resizeGripWindow else { return }
        let side = ResizeGripView.side
        grip.setFrame(
            NSRect(x: frame.width - side - 1, y: 1, width: side, height: side),
            display: false
        )
    }

    /// Resizes by a drag *delta* measured in the grip's window coordinates (origin bottom-left, so
    /// dragging the corner down grows `height` and dragging right grows `width`).
    fileprivate func resizeBy(_ delta: CGSize) {
        // Keep the top edge fixed (as the note's roll-up does) and clamp to the panel's min size.
        let newWidth = max(minSize.width, frame.width + delta.width)
        let newHeight = max(minSize.height, frame.height + delta.height)
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - newHeight, width: newWidth, height: newHeight), display: true)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        layoutResizeGrip()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        super.setFrame(frameRect, display: flag, animate: animateFlag)
        layoutResizeGrip()
    }

    // MARK: - Paste

    /// Hands over a pasted image, which waits in the note's quick-add. Reached when nothing in the note
    /// is being edited — a focused editor handles ⌘V itself, earlier in the responder chain. Set by
    /// `NoteWindowManager`.
    var onPasteImage: ((Data) -> Void)?

    @objc func paste(_ sender: Any?) {
        if let data = NSPasteboard.general.pastableImageData() { onPasteImage?(data) }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) { return NSPasteboard.general.hasPastableImage }
        return super.validateUserInterfaceItem(item)
    }
}

/// The little bottom-right resize grip: a native "resize" cursor on hover and a drag that reports its
/// per-move delta (in the grip's own coordinates) back to the note, which resizes itself.
private final class ResizeGripView: NSView {
    static let side: CGFloat = 16
    var onResize: ((CGSize) -> Void)?

    private var lastPoint: NSPoint?
    private var tracking: NSTrackingArea?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        ctx.setLineWidth(1)
        // Three short diagonal strokes in the corner, the familiar "grab here" cue.
        for offset in stride(from: CGFloat(4), through: 12, by: 4) {
            ctx.move(to: CGPoint(x: offset, y: 1))
            ctx.addLine(to: CGPoint(x: bounds.maxX - 1, y: bounds.height - offset))
            ctx.strokePath()
        }
    }

    override func mouseDown(with event: NSEvent) { lastPoint = convert(event.locationInWindow, from: nil) }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let last = lastPoint else { lastPoint = point; return }
        onResize?(CGSize(width: point.x - last.x, height: point.y - last.y))
        lastPoint = point
    }

    override func mouseUp(with event: NSEvent) { lastPoint = nil }

    // Hit-testing: only the corner is grabbable, so a click elsewhere isn't swallowed.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
}
