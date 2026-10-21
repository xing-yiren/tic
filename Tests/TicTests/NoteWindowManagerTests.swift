import AppKit
import Foundation
import Testing
import SwiftUI
@testable import Tic

@Suite("NoteWindowManager placement")
struct NoteWindowManagerTests {
    // Two side-by-side displays in global coordinates: the main one at the origin, a second to its right.
    private let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let second = CGRect(x: 1440, y: 0, width: 2560, height: 1415)

    @Test("a note on the second display counts as visible, not lost")
    func secondDisplayIsVisible() {
        let onSecond = CGRect(x: 2000, y: 300, width: 280, height: 360)
        #expect(NoteWindowManager.isVisible(onSecond, onAnyOf: [main, second]))
        #expect(!NoteWindowManager.isVisible(onSecond, onAnyOf: [main]))   // display unplugged
    }

    @Test("a sliver hanging off every edge is lost; an 80×80 corner is enough")
    func slivers() {
        let sliver = CGRect(x: -250, y: 300, width: 280, height: 360)     // 30pt showing
        #expect(!NoteWindowManager.isVisible(sliver, onAnyOf: [main, second]))
        let corner = CGRect(x: -200, y: -280, width: 280, height: 360)    // exactly 80×80 showing
        #expect(NoteWindowManager.isVisible(corner, onAnyOf: [main, second]))
    }

    @Test("office → home → office: parked on the main display while its monitor is gone, back exactly after")
    func displayRoundTrip() {
        let onSecond = CGRect(x: 2000, y: 300, width: 280, height: 360)
        #expect(NoteWindowManager.placement(for: onSecond, screens: [main, second], main: main) == onSecond)

        let parked = NoteWindowManager.placement(for: onSecond, screens: [main], main: main)   // monitor unplugged
        #expect(NoteWindowManager.isVisible(parked, onAnyOf: [main]))
        #expect(parked.size == onSecond.size)
        #expect(parked.maxX == main.maxX && parked.minY == 300)   // nearest edge, not a pile in the centre

        // The saved frame is never rewritten by parking, so the same input places it back on the monitor.
        #expect(NoteWindowManager.placement(for: onSecond, screens: [main, second], main: main) == onSecond)
    }

    @Test("a note taller than the display keeps its header on screen")
    func tallNote() {
        let tall = CGRect(x: 5000, y: 5000, width: 280, height: 1200)
        let parked = NoteWindowManager.placement(for: tall, screens: [main], main: main)
        #expect(parked.maxY == main.maxY && parked.maxX == main.maxX)
    }
}

/// The full-screen policy: while another app is in a full-screen Space, unpinned notes are taken off
/// the screen and put back afterwards; pinned notes ("keep on top") are left alone.
///
/// The system's full-screen state is stubbed (`fullScreenProbe`); everything else — the panels, the
/// ordering calls, the state machine — is the real thing.
@MainActor
@Suite("NoteWindowManager full-screen policy")
struct NoteWindowManagerFullScreenTests {
    /// A panel that records the ordering calls the manager makes.
    final class RecordingPanel: NotePanel {
        var orders: [String] = []
        override func showAsOrdinaryWindow() { orders.append("show") ; super.showAsOrdinaryWindow() }
        override func raiseRegardless() { orders.append("raise"); super.raiseRegardless() }
        /// Which ordering primitive the panel itself picks for a plain `orderFront` (the shortcut
        /// into it used to end up in the on-screen list regardless of the pin).
        var plainOrderUsesSuper = false
        override func orderFront(_ sender: Any?) {
            if isPinned { plainOrderUsesSuper = true }
            super.orderFront(sender)
        }
        init(pinned: Bool, frame: CGRect = CGRect(x: 100, y: 400, width: 280, height: 360)) {
            super.init(
                note: Note(frameX: frame.minX, frameY: frame.minY,
                            frameW: frame.width == 0 ? 280 : frame.width,
                            frameH: frame.height == 0 ? 360 : frame.height,
                            floatOnTop: pinned, showOnAllSpaces: true),
                content: AnyView(Color.clear)
            )
            apply(floatOnTop: pinned, showOnAllSpaces: true)
            // The panels are never ordered on screen by these tests, so give them the frame the
            // policy reads (which display they are on).
            setFrame(frame, display: false)
        }
    }

    private func makeManager() throws -> NoteWindowManager {
        _ = NSApplication.shared
        let manager = NoteWindowManager(appDatabase: try AppDatabase.makeInMemory())
        // A two-display desktop: the policy is exercised against known frames, not the machine's.
        manager.screenProbe = { [mainDisplay, secondDisplay] }
        manager.fullScreenProbe = { [] }
        return manager
    }

    /// A two-display desktop: the main one and a second to its right, with a note on each. Stood in
    /// for so the policy is exercised identically on the machine running the tests.
    private var mainDisplay: CGRect { CGRect(x: 0, y: 0, width: 1440, height: 900) }
    private var secondDisplay: CGRect { CGRect(x: 1440, y: 0, width: 1920, height: 1080) }
    private var noteOnMain: CGRect { CGRect(x: 100, y: 400, width: 280, height: 360) }
    private var noteOnSecond: CGRect { CGRect(x: 1600, y: 300, width: 280, height: 360) }


    private func open(_ manager: NoteWindowManager, _ panel: NotePanel) -> NotePanel {
        // Register the panel the way `openNote` would (controller + panel), then apply the policy.
        manager.register(panel)
        manager.applyFullScreenPolicy()
        return panel
    }

    @Test("an unpinned note is hidden while another app is full screen, and shown again after")
    func unpinnedLeavesFullScreen() throws {
        let manager = try makeManager()
        manager.fullScreenProbe = { [] }   // baseline: nothing full screen
        let panel = RecordingPanel(pinned: false)
        open(manager, panel)
        #expect(!manager.otherAppIsFullScreen)

        manager.fullScreenProbe = { [mainDisplay] }
        manager.applyFullScreenPolicy()
        #expect(manager.otherAppIsFullScreen)
        #expect(manager.isHiddenForFullScreen(panel.noteID))

        manager.fullScreenProbe = { [] }
        manager.applyFullScreenPolicy()   // first "desktop" reading: the gate opens, nothing shows yet
        #expect(!manager.otherAppIsFullScreen)
        manager.applyFullScreenPolicy()   // confirmed: the notes come back
        #expect(!manager.isHiddenForFullScreen(panel.noteID))
        #expect(panel.orders.contains("show"))   // put back on its Space
    }

    @Test("a full-screen app on the second display leaves the notes on the first one alone")
    func fullScreenIsPerDisplay() throws {
        // The regression: any full-screen app anywhere used to take *every* unpinned note off screen,
        // so a full-screen Chrome/Space on the second monitor made the notes on the first one vanish.
        let manager = try makeManager()
        let onMain = RecordingPanel(pinned: false, frame: noteOnMain)
        let onSecond = RecordingPanel(pinned: false, frame: noteOnSecond)
        open(manager, onMain)
        open(manager, onSecond)
        onMain.orders.removeAll()
        onSecond.orders.removeAll()

        manager.fullScreenProbe = { [secondDisplay] }
        manager.applyFullScreenPolicy()
        #expect(manager.otherAppIsFullScreen)
        #expect(!manager.isHiddenForFullScreen(onMain.noteID), "the note on the other display stays")
        #expect(onMain.orders.isEmpty, "orders: \(onMain.orders)")
        #expect(manager.isHiddenForFullScreen(onSecond.noteID))
        #expect(onSecond.suppressedByFullScreen, "its gate is closed")

        manager.fullScreenProbe = { [] }
        manager.applyFullScreenPolicy()
        manager.applyFullScreenPolicy()
        #expect(!manager.isHiddenForFullScreen(onSecond.noteID))
        #expect(onSecond.orders.contains("show"), "orders: \(onSecond.orders)")
        #expect(onMain.orders.isEmpty, "orders: \(onMain.orders)")
    }

    @Test("a full-screen app moving to the other display frees the notes it left behind")
    func fullScreenMovesToAnotherDisplay() throws {
        // The regression: the app stays full screen (so the state never "changes"), but it moves from
        // one display to the other. The notes on the display it left must come back.
        let manager = try makeManager()
        let onMain = RecordingPanel(pinned: false, frame: noteOnMain)
        let onSecond = RecordingPanel(pinned: false, frame: noteOnSecond)
        open(manager, onMain)
        open(manager, onSecond)

        manager.fullScreenProbe = { [mainDisplay] }
        manager.applyFullScreenPolicy()
        #expect(manager.isHiddenForFullScreen(onMain.noteID))
        #expect(!manager.isHiddenForFullScreen(onSecond.noteID))
        onMain.orders.removeAll()

        // Still full screen, but on the other display now.
        manager.fullScreenProbe = { [secondDisplay] }
        manager.applyFullScreenPolicy()
        #expect(manager.otherAppIsFullScreen)
        #expect(!manager.isHiddenForFullScreen(onMain.noteID), "the note it left behind comes back")
        #expect(onMain.orders.contains("show"), "orders: \(onMain.orders)")
        #expect(manager.isHiddenForFullScreen(onSecond.noteID))
    }

    @Test("a pinned note is left alone while another app is full screen")
    func pinnedStaysVisible() throws {
        let manager = try makeManager()
        manager.fullScreenProbe = { [] }
        let panel = RecordingPanel(pinned: true)
        open(manager, panel)
        manager.fullScreenProbe = { [mainDisplay] }
        manager.applyFullScreenPolicy()
        #expect(!manager.isHiddenForFullScreen(panel.noteID))
    }

    @Test("a note shown while another app is full screen is taken off screen again")
    func shownDuringFullScreenIsHidden() throws {
        // The regression: while VS Code was full screen, toggling a note's pin off (or an agent
        // touching it) ordered the panel on screen *after* the state had flipped to "full screen", so
        // the "became full screen" sweep had already run and nothing hid it again.
        let manager = try makeManager()
        manager.fullScreenProbe = { [] }
        let panel = RecordingPanel(pinned: true)   // pinned: shown while full screen is up
        open(manager, panel)

        manager.fullScreenProbe = { [mainDisplay] }
        manager.applyFullScreenPolicy()
        panel.apply(floatOnTop: false, showOnAllSpaces: true)   // user unpins it right then
        panel.showInBackground(raise: true)                     // ...and it gets ordered on screen
        manager.applyFullScreenPolicy()                         // next sweep
        #expect(manager.isHiddenForFullScreen(panel.noteID))
    }

    @Test("an unpinned panel refuses to show at all while another app is full screen")
    func suppressedPanelStaysHidden() throws {
        let manager = try makeManager()
        manager.fullScreenProbe = { [mainDisplay] }
        let panel = RecordingPanel(pinned: false)
        manager.register(panel)
        manager.applyFullScreenPolicy()
        #expect(panel.suppressedByFullScreen)
        panel.orders.removeAll()   // opening the panel may have shown it before the policy ran
        #expect(!panel.isVisible, "still off screen")
        panel.orderFront(nil)
        panel.makeKeyAndOrderFront(nil)
        panel.raiseRegardless()
        // `raiseRegardless` records its intent before consulting the gate, so only "raise" may show;
        // an unpinned panel that got through would have gone to showAsOrdinaryWindow (→ "show").
        #expect(!panel.orders.contains("show"), "orders: \(panel.orders)")

        manager.fullScreenProbe = { [] }
        manager.applyFullScreenPolicy()
        #expect(!panel.suppressedByFullScreen)
    }

    @Test("a probe that flickers to 'desktop' and back doesn't put the note back on screen")
    func flickeringProbeDoesNotRestore() throws {
        // While a full-screen Space is still animating, the window server can report the display's
        // ordinary Space for a tick. The notes were taken off screen at that point — putting them back
        // would leave them over the full-screen app until the next sweep saw the full-screen Space.
        let manager = try makeManager()
        let panel = RecordingPanel(pinned: false)
        open(manager, panel)                  // one sweep: still an ordinary desktop
        panel.orders.removeAll()
        manager.fullScreenProbe = { [mainDisplay] }
        manager.applyFullScreenPolicy()       // the app goes full screen: the note is taken off
        panel.orders.removeAll()

        manager.fullScreenProbe = { [] }   // one tick of the transition
        manager.applyFullScreenPolicy()
        #expect(!panel.orders.contains("show"), "orders: \(panel.orders)")

        manager.fullScreenProbe = { [mainDisplay] }    // the Space is really still full screen
        manager.applyFullScreenPolicy()
        #expect(manager.otherAppIsFullScreen)
        #expect(panel.suppressedByFullScreen, "the note was never put back on screen")
    }

    @Test("a note the system dropped is put back in the background; nothing else is re-ordered")
    func lostNoteComesBack() throws {
        // Display sleep or the screen locking can order a non-activating panel out, and nothing
        // asks an inactive app to show it again. The sweep notices and puts it back — without
        // raising it over the user's work, and without touching panels that are still up.
        let manager = try makeManager()
        manager.fullScreenProbe = { [] }
        let lost = RecordingPanel(pinned: false)
        let up = RecordingPanel(pinned: false)
        open(manager, lost)
        open(manager, up)
        lost.orderOut(nil)
        lost.orders.removeAll()
        up.orders.removeAll()

        manager.applyFullScreenPolicy()

        #expect(lost.orders == ["show"], "orders: \(lost.orders)")   // shown, never raised
        #expect(up.orders.isEmpty, "orders: \(up.orders)")
    }

    @Test("a sweep leaves notes the filter or the full-screen policy took off screen alone")
    func lostNoteRespectsSuppression() throws {
        let manager = try makeManager()
        manager.fullScreenProbe = { [mainDisplay] }
        let panel = RecordingPanel(pinned: false)
        open(manager, panel)                    // hidden for the full-screen Space
        #expect(manager.isHiddenForFullScreen(panel.noteID))
        panel.orders.removeAll()

        manager.applyFullScreenPolicy()         // however often it runs
        manager.applyFullScreenPolicy()
        #expect(panel.orders.isEmpty, "orders: \(panel.orders)")

        // And the filter's notes are just as safe once nothing is full screen.
        manager.fullScreenProbe = { [] }
        manager.applyFullScreenPolicy()
        manager.applyFullScreenPolicy()
        manager.hideByFilterForTesting([panel.noteID])
        panel.orderOut(nil)
        panel.orders.removeAll()
        manager.applyFullScreenPolicy()
        #expect(panel.orders.isEmpty, "orders: \(panel.orders)")
    }

    @Test("a note closed while it was out of sight is not put back when the full-screen Space goes away")
    func closedWhileHiddenStaysClosed() throws {
        // The manager's set of "taken off screen" notes outlives the panel: the user's X only closes
        // the window, and the note stays closed (`isOpen: false`). A sweep must not resurrect it.
        let manager = try makeManager()
        let panel = RecordingPanel(pinned: false)
        open(manager, panel)
        manager.fullScreenProbe = { [mainDisplay] }
        manager.applyFullScreenPolicy()
        #expect(manager.isHiddenForFullScreen(panel.noteID))

        manager.unregisterForTesting(panel.noteID)   // the user closes the note
        panel.orders.removeAll()
        manager.fullScreenProbe = { [] }
        manager.applyFullScreenPolicy()              // first "desktop" tick
        manager.applyFullScreenPolicy()              // confirmed: restore sweep
        #expect(!panel.orders.contains("show"), "orders: \(panel.orders)")
        #expect(!manager.isHiddenForFullScreen(panel.noteID))
    }

    @Test("an unpinned note's own orderFront is an ordinary one, a pinned note's is the plain one")
    func plainOrderFrontFollowsThePin() {
        let unpinned = RecordingPanel(pinned: false)
        unpinned.orderFront(nil)
        #expect(!unpinned.plainOrderUsesSuper, "an unpinned note must not use the full-screen-joining order")

        let pinned = RecordingPanel(pinned: true)
        pinned.orderFront(nil)
        #expect(pinned.plainOrderUsesSuper)
    }

    @Test("re-applying the same state doesn't re-order anything")
    func idempotent() throws {
        let manager = try makeManager()
        manager.fullScreenProbe = { [] }
        let panel = RecordingPanel(pinned: false)
        open(manager, panel)
        manager.fullScreenProbe = { [mainDisplay] }
        manager.applyFullScreenPolicy()
        let orders = panel.orders
        manager.applyFullScreenPolicy()
        #expect(panel.orders == orders)
    }
}
