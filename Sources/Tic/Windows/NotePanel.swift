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
        // Pinning lifts the note to floating for good; unpinning leaves it at its resting level (a
        // show in flight is what put it higher, and it drops back on its own).
        if floatOnTop {
            showFloatGeneration += 1
            level = .floating
        } else {
            level = .normal
        }
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
    /// Where this note was (queue position) while it was taken off screen — restored on re-show so
    /// an unpinned note doesn't jump above pinned ones.
    private var orderingWhileHidden: NSWindow.OrderingMode = .below

    func applyFullScreenSuppression(_ suppressed: Bool) {
        // Re-applying an unchanged hold must still take a note off screen. A note that was pinned
        // and became unpinned *while* the hold was on never left the screen: its earlier `orderOut`
        // (made at `.floating`, while pinned) was refused, and returning early here left it showing
        // over the full-screen app until the user switched Spaces.
        suppressedByFullScreen = suppressed
        // Lifting the hold doesn't show the note (the manager decides when), but a note that was
        // ordered out must not come back until then. Dropping the show-time float here means the
        // ordering below really takes it off the screen instead of leaving it above the full-screen
        // app at a raised level.
        if suppressed {
            // AppKit can't be asked whether the window server really dropped the window (a
            // non-activating panel reports `isVisible == false` even while it is on screen), so a
            // re-applied hold always retries — `orderOut` on an off-screen window is harmless.
            orderedOutWhileSuppressed = true
            showFloatGeneration += 1
            if !isPinned && !userSummoned { level = .normal }
            orderOut(nil)
        } else if !isPinned && !userSummoned {
            orderingWhileHidden = .below
        }
    }

    /// Set when the full-screen hold actually asked for the note to come off screen. Observable
    /// because a re-applied hold is otherwise a no-op the tests can't see: the manager re-runs the
    /// policy every second, and the pin toggle adds one more run of its own.
    var orderedOutWhileSuppressed = false

    /// Every way of putting the panel on screen funnels through here, so the full-screen rule can't
    /// be bypassed by one stray `orderFront`.
    private var mayShow: Bool { isPinned || userSummoned || !suppressedByFullScreen }

    /// While an unpinned note is *shown* it sits at the floating level, so the window server actually
    /// has it on screen. A `.nonactivatingPanel` at level 0 is never re-ordered onto the screen while
    /// another app is frontmost (which is always how a note is shown — Tic is the background app),
    /// so the ordering call would leave it in the window server's off-screen list. The full-screen
    /// policy reads ordering by *out*, so a note that was never ordered in could never be ordered out
    /// either: it stayed on the full-screen app's Space. (In practice only the apps that hold focus
    /// differently — VS Code's quick-open palettes — surfaced it.)
    ///
    /// The extra level is not "pinned": the note still only takes the keyboard on a click
    /// (`isFloatingPanel` stays false, so a click still activates Tic), and the pin's own louder
    /// ordering (`orderFrontRegardless`) is still gated on `isPinned`.
    ///
    /// It is dropped again (back to `.normal`) once the note has been on screen for a moment, so an
    /// unpinned note doesn't hover above other apps' windows for good.
    private func showAtTemporaryFloat(_ order: () -> Void) {
        level = .floating
        order()
        showFloatGeneration += 1
        let generation = showFloatGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showFloatDuration) { [weak self] in
            guard let self, generation == self.showFloatGeneration, !self.isPinned else { return }
            self.level = .normal
        }
    }

    /// Cancels the pending drop back to `.normal` (another show happened first).
    private var showFloatGeneration = 0
    private static let showFloatDuration: TimeInterval = 2.5

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
        // The manager decided it belongs on screen; a summoned note is shown above everything until
        // the user goes back to the full-screen app.
        if userSummoned {
            level = Self.userCanvasLevel
            super.orderFrontRegardless()
            return
        }
        // `orderFront` — deliberately *not* `orderFrontRegardless`. "Regardless" (analysis of the
        // non-activating panel's ordering) is what makes an unpinned note stay above other apps'
        // windows and ride into a full-screen Space; plain `orderFront` shows it as this app's
        // ordinary window, which other apps cover and which stays off another app's full-screen
        // Space. It works even while Tic is inactive, which is the case for every restore.
        if isPinned {
            super.orderFront(nil)
            joinFullScreenSpaceIfShowing()
        } else {
            showAtTemporaryFloat { super.orderFront(nil) }
        }
    }

    // MARK: - Following another app into its full-screen Space

    /// The note's display, as the window server sees it: the one it mostly lies on.
    private var displayUUID: String? {
        let area = frame.width * frame.height
        guard area > 0 else { return nil }
        return NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID else { return false }
            let display = CGDisplayBounds(number)
            let overlap = display.intersection(frame)
            return !overlap.isNull && overlap.width * overlap.height >= area * 0.5
        }.flatMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
            else { return nil }
            return CFUUIDCreateString(nil, uuid) as String?
        }
    }

    /// Puts a pinned note onto another app's full-screen Space once that Space is current on the
    /// note's display.
    ///
    /// A note is shown on the *ordinary* desktop and only afterwards does an app go full screen on
    /// its display. Plain `orderFront` then leaves the note behind on the desktop's Space, and
    /// re-asserting it re-orders it onto the Space that is current — the full-screen one — which is
    /// what a pinned note ("keep on top", show over the full-screen app) wants. Deferred a tick,
    /// because the Space changes hands after the app's full-screen animation, not at the call.
    func joinFullScreenSpace() { joinFullScreenSpaceIfShowing() }

    private func joinFullScreenSpaceIfShowing() {
        guard isVisible else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPinned, self.isVisible else { return }
            // Nothing to do when the window server already has it on the current Space.
            guard !Self.isOnFullScreenSpace(displayUUID: displayUUID) else { return }
            self.orderFront(nil)
        }
    }

    /// Whether `uuid`'s display is currently showing a full-screen Space. Read straight from the
    /// window server, so it can't drift from what the manager decided.
    private static func isOnFullScreenSpace(displayUUID: String?) -> Bool {
        guard let displayUUID,
              let connect = SkyLight.connect, let copySpaces = SkyLight.copySpaces,
              let displays = copySpaces(connect()) as? [[String: Any]]
        else { return false }
        return displays.contains { display in
            guard (display["Display Identifier"] as? String) == displayUUID,
                  let space = display["Current Space"] as? [String: Any]
            else { return false }
            return (space["type"] as? NSNumber)?.intValue == 4 && space["fs_wid"] != nil
        }
    }


    /// The user summoned this note while another app is full screen (Tic's icon, or a list picked
    /// from Recent / Overview / the palette). It then sits above the full-screen app at the
    /// *user-canvas* level: visible and editable until the user goes back to that app, when the
    /// manager clears this and hides it again.
    var userSummoned = false

    /// Back to the resting level after the manager lifts a summon — unless the pin says otherwise
    /// (or the note happens to be mid-show; `showAtTemporaryFloat` handles that itself).
    func restToNormalLevelIfUnpinned() {
        guard !isPinned else { return }
        level = .normal
    }

    /// Which end of the window list a re-shown note joins. An unpinned note goes back *below* the
    /// others, so showing it again can't lift it over a pinned note.
    var restoreOrdering: NSWindow.OrderingMode { orderingWhileHidden }

    /// The level a summoned note shows at — formally the "screen-saver" level (ABOVE the app's
    /// full-screen windows, which live just below it), named for here for what it means: a surface
    /// the user reached for.
    static let userCanvasLevel: NSWindow.Level = .screenSaver

    /// Shows the note as the user's canvas: above whatever is on its display, editable.
    ///
    /// Unlike a pin this is loud on purpose (`orderFrontRegardless` + the screen-saver level): the
    /// note is being pushed into another app's full-screen Space, so it has to be ordered in over it,
    /// not just onto its own Space. It is only ever used in response to an explicit user action, and
    /// the manager takes it back (see `userSummoned`) as soon as the user returns to that app.
    func showAsUserCanvas() {
        level = Self.userCanvasLevel
        orderFrontRegardless()
        makeKey()
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
        if raise || isPinned {
            raiseRegardless()
            if isPinned { joinFullScreenSpaceIfShowing() }
        } else {
            showAsOrdinaryWindow()
        }
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

    /// The private window-server query a pinned note needs (see `joinFullScreenSpaceIfShowing`).
    private enum SkyLight {
        typealias Connect = @convention(c) () -> Int32
        typealias CopySpaces = @convention(c) (Int32) -> CFArray?

        nonisolated(unsafe) static let coreGraphics = dlopen(nil, RTLD_LAZY)
        nonisolated(unsafe) static let framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

        static func load<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _ type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }

        static let connect: Connect? = load(coreGraphics, "CGSMainConnectionID", Connect.self)
        static let copySpaces: CopySpaces? = load(framework, "SLSCopyManagedDisplaySpaces", CopySpaces.self)
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
