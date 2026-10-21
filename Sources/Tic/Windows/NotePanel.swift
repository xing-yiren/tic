import AppKit
import SwiftUI

/// A single sticky note window. A titled panel with a hidden, transparent title bar gives us
/// rounded corners, a system shadow, and edge resizing for free, while `fullSizeContentView`
/// lets the SwiftUI content cover the whole surface. `.nonactivatingPanel` lets a note take the
/// keyboard without forcing Tic forward — and, together with `canJoinAllSpaces`, it's what lets a
/// note follow across Spaces without activating Tic. Whether a note also appears over another
/// app's full-screen Space is decided by the pin (`apply(floatOnTop:showOnAllSpaces:)`).
class NotePanel: NSPanel {
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
        // could only be resized by its edges. Add a visible grip in the bottom-right corner, as a plain
        // subview of the hosting view — NOT a child window, which would tie the note to one Space.
        let hosting = NSHostingView(rootView: content)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting

        let grip = ResizeGripView(frame: NSRect(x: 0, y: 0, width: ResizeGripView.side, height: ResizeGripView.side))
        grip.autoresizingMask = [.minXMargin, .maxYMargin]
        grip.onResize = { [weak self] delta in self?.resizeBy(delta) }
        hosting.addSubview(grip)
        resizeGrip = grip
        layoutResizeGrip()

        apply(floatOnTop: note.floatOnTop, showOnAllSpaces: note.showOnAllSpaces)
    }

    /// Whether this note is pinned ("keep on top"). Pinned notes sit at a floating level and stay
    /// in the WindowServer's on-screen list across activation (so they show over other apps,
    /// including a full-screen one). Unpinned notes are ordinary windows — see `orderFront`.
    private(set) var isPinned = false

    /// Applies the float-on-top and show-on-all-Spaces behaviours to the live window.
    func apply(floatOnTop: Bool, showOnAllSpaces: Bool) {
        isPinned = floatOnTop
        level = floatOnTop ? .floating : .normal
        // Being pinned is what lets a note ride into another app's full-screen Space. An unpinned
        // note is an ordinary window: it stays on its own Space (free to be covered by other windows)
        // and is left behind when an app goes full screen. `fullScreenAuxiliary` has to be *assigned*,
        // not merely omitted — `NSPanel` carries it by default, so an unset behaviour still joined
        // full-screen Spaces.
        //
        // `canJoinAllSpaces` "show on all desktops" is about the user's own desktop Spaces; it does
        // not by itself put an unpinned note into another app's full-screen Space. `canJoinAllSpaces`
        // is the user's setting and is honoured for both states; `.fullScreenAuxiliary` is what lets a
        // note ride along with a full-screen app, so only the pin grants it.
        var behavior: NSWindow.CollectionBehavior = []
        if showOnAllSpaces { behavior.insert(.canJoinAllSpaces) }
        if floatOnTop { behavior.insert(.fullScreenAuxiliary) }
        collectionBehavior = behavior
    }

    /// Borderless/utility panels don't become key by default; we need it for text editing.
    override var canBecomeKey: Bool { true }

    /// Set by the window manager while another app is full screen: an unpinned note must not be put
    /// on screen at all then, whichever path asks for it (a click, an agent, a restore) — a
    /// full-screen app's Space covers the desktop, so an ordinary window shown "behind" it would
    /// still be visible.
    private(set) var suppressedByFullScreen: Bool = false

    func applyFullScreenSuppression(_ suppressed: Bool) {
        guard suppressed != suppressedByFullScreen else { return }
        suppressedByFullScreen = suppressed
        // Lifting the hold doesn't show the note (the manager decides when), but a note that was
        // ordered out must not come back until then.
        if suppressed { orderOut(nil) }
    }

    /// Every way of putting the panel on screen funnels through here, so the full-screen rule can't
    /// be bypassed by one stray `orderFront`.
    private var mayShow: Bool { isPinned || !suppressedByFullScreen }

    // MARK: - Ordering

    /// An unpinned note is an ordinary window.
    ///
    /// All note panels are *non-activating*, which lets them take the keyboard without activating
    /// Tic. `orderFrontRegardless` would put such a panel in front of everything — other apps
    /// included — and into another app's full-screen Space, which is exactly what "unpinned" must
    /// not do. So an unpinned note is ordered plainly (see `showAsOrdinaryWindow`): it shows on its
    /// own Space and other windows can cover it.
    ///
    /// Pinned notes are ordered plainly too, but at the floating level — above every ordinary window,
    /// wherever the user is.
    override func orderFront(_ sender: Any?) {
        guard mayShow else { return }
        if isPinned {
            super.orderFront(sender)
        } else {
            showAsOrdinaryWindow()
        }
    }

    /// What an unpinned note does instead of being ordered over everything. Separate from
    /// `orderFrontRegardless()` so the intent is greppable (and testable): the note is shown the way
    /// this app shows any of its windows — on its own Space, at level 0, free to be covered.
    func showAsOrdinaryWindow() {
        guard mayShow else { return }
        // `orderFront` — deliberately *not* `orderFrontRegardless`. "Regardless" (analysis of the
        // non-activating panel's ordering) is what makes a note stay above other apps' windows and
        // ride into a full-screen Space; plain `orderFront` shows it as this app's ordinary window,
        // which other apps cover and which stays off another app's full-screen Space. It works even
        // while Tic is inactive, which is the case for every restore.
        super.orderFront(nil)
    }

    /// Whether the note is on the current Space but not on the screen — i.e. it is *on* this
    /// desktop, but the window was ordered out (by the system, as display sleep and the screen
    /// lock do), rather than simply living on another Space.
    ///
    /// `isVisible` alone can't tell the two apart: a window on another Space is not "visible"
    /// either, and treating that as "dropped" would drag notes into whatever Space the user is
    /// looking at.
    var wasOrderedOut: Bool { isOnActiveSpace && !isVisible }

    /// Shows the note without making it the user's active window: a launch restore, or a note an
    /// agent wrote to in the background. `raise: false` (the default) never puts an unpinned note
    /// above whatever is frontmost; a pinned note floats anyway. Pass `raise: true` only for an
    /// explicit "show me this" from the user.
    func showInBackground(raise: Bool) {
        if raise || isPinned { raiseRegardless() } else { showAsOrdinaryWindow() }
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        guard mayShow else { return }
        super.makeKeyAndOrderFront(sender)
    }

    /// Belt and braces: the one ordering call that needs no app-level checks is declined while
    /// suppressed too, so no caller can slip a note into a full-screen Space through it.
    override func orderFrontRegardless() {
        guard mayShow else { return }
        super.orderFrontRegardless()
    }

    /// Forces the note to the front of its level, whatever the pin state — for an explicit request
    /// (e.g. the `focus_note` MCP tool) rather than an incidental restore.
    func raiseRegardless() {
        guard mayShow else { return }
        orderFrontRegardless()
    }

    // MARK: - Resize grip

    /// The bottom-right resize grip, pinned as a subview of the note's hosting view.
    private var resizeGrip: ResizeGripView?

    private func layoutResizeGrip() {
        guard let grip = resizeGrip, let host = contentView else { return }
        let side = ResizeGripView.side
        grip.frame = NSRect(x: host.bounds.maxX - side, y: 0, width: side, height: side)
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
