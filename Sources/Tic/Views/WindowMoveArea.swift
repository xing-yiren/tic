import SwiftUI
import AppKit

/// A transparent layer that lets the user drag the window by this region (the note's title-bar
/// handle) and reports double-clicks (for roll-up). Used because whole-window background dragging
/// is disabled on the panel — so dragging a task row reorders it instead of moving the window.
struct WindowMoveArea: NSViewRepresentable {
    var onDoubleClick: () -> Void = {}

    func makeNSView(context: Context) -> NSView {
        MoveView(onDoubleClick: onDoubleClick)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MoveView)?.onDoubleClick = onDoubleClick
    }

    /// Variant that also reports pointer enter/leave, so a caller can reveal an affordance (e.g. the
    /// collapsed note's expand button) on hover while still using the area as a drag handle.
    struct Hovering: NSViewRepresentable {
        var onDoubleClick: () -> Void = {}
        @Binding var isHovering: Bool

        func makeNSView(context: Context) -> NSView {
            let view = MoveView(onDoubleClick: onDoubleClick)
            view.onHover = { hovering in
                if isHovering != hovering { isHovering = hovering }
            }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            guard let view = nsView as? MoveView else { return }
            view.onDoubleClick = onDoubleClick
            view.onHover = { hovering in
                if isHovering != hovering { isHovering = hovering }
            }
        }
    }

    final class MoveView: NSView {
        var onDoubleClick: () -> Void
        var onHover: ((Bool) -> Void)?

        init(onDoubleClick: @escaping () -> Void) {
            self.onDoubleClick = onDoubleClick
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick()
                return
            }
            window?.performDrag(with: event)   // begin a window-move drag loop
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil
            ))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }
}
