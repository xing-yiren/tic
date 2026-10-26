import AppKit
import SwiftUI
import Testing
@testable import Tic

/// Window behaviour behind the pin ("keep on top") toggle.
///
/// An *unpinned* note is an ordinary window: on a normal desktop it must be occluded by (and go
/// behind) other app windows, and it must NOT be brought along into another app's full-screen Space
/// — that's the whole difference the pin buys you. Sitting above everything, and riding into a
/// full-screen Space, is reserved for pinned notes.
@MainActor
@Suite("NotePanel window behaviour")
struct NotePanelBehaviorTests {
    private func makePanel(pinned: Bool, allSpaces: Bool = true) -> NotePanel {
        _ = NSApplication.shared
        let note = Note(color: .yellow, floatOnTop: pinned, showOnAllSpaces: allSpaces)
        let panel = NotePanel(note: note, content: AnyView(Color.clear))
        panel.apply(floatOnTop: pinned, showOnAllSpaces: allSpaces)
        return panel
    }

    @Test("an unpinned note is a normal-level window")
    func unpinnedIsNormalLevel() {
        #expect(makePanel(pinned: false).level == .normal)
    }

    @Test("a pinned note floats above other apps' windows")
    func pinnedFloats() {
        #expect(makePanel(pinned: true).level == .floating)
    }

    @Test("an unpinned note does not follow into another app's full-screen Space")
    func unpinnedStaysOutOfFullScreen() {
        let panel = makePanel(pinned: false)
        #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.collectionBehavior.contains(.fullScreenPrimary))
    }

    @Test("a pinned note joins the full-screen Space (and all Spaces when asked)")
    func pinnedJoinsFullScreen() {
        let panel = makePanel(pinned: true)
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
    }

    @Test("all-Spaces without pinning still doesn't claim the full-screen Space")
    func allSpacesAloneIsNotFullScreen() {
        let panel = makePanel(pinned: false, allSpaces: true)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @Test("toggling pin at runtime re-applies the behaviour both ways")
    func togglingReapplies() {
        let panel = makePanel(pinned: true)
        panel.apply(floatOnTop: false, showOnAllSpaces: true)
        #expect(panel.level == .normal)
        #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))
        panel.apply(floatOnTop: true, showOnAllSpaces: true)
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }
}

/// The ordering half of the pin. A non-activating note panel that is merely `orderFront`ed stays in
/// front of *other apps* while Tic is inactive (including over another app's full-screen Space), so
/// an unpinned note must never be ordered that way — only a pinned one may be raised that way.
@MainActor
@Suite("NotePanel ordering")
struct NotePanelOrderingTests {
    private func makePanel(pinned: Bool) -> NotePanel {
        _ = NSApplication.shared
        _ = Spy(pinned: false)   // see `Spy.loadPanelClass`: installs NotePanel's overrides up front
        let note = Note(color: .yellow, floatOnTop: pinned, showOnAllSpaces: true)
        let panel = NotePanel(note: note, content: AnyView(Color.clear))
        panel.apply(floatOnTop: pinned, showOnAllSpaces: true)
        return panel
    }

    /// Records which ordering primitive a panel ends up using.
    final class Spy: NotePanel {
        // `NotePanel` overrides `orderFront`/`orderFrontRegardless` in Swift, and Swift installs a
        // class's overrides into the Objective-C method table when the class is *first constructed*.
        // Calls made from within that first construction (e.g. `apply` in `init`) still dispatch to
        // `NSWindow`; every later instance — and every later call on the first one — uses the
        // override. Tests that measure calls therefore build a throwaway `Spy` first.

        var calls: [String] = []
        /// Records the ordinary-window path (the note's decision) and then runs it, so the test also
        /// sees the level it leaves the panel at.
        var showedAsOrdinary = false
        override func showAsOrdinaryWindow() {
            showedAsOrdinary = true
            calls.append("orderFrontRegardless")
            super.showAsOrdinaryWindow()
        }
        override func orderFront(_ sender: Any?) {
            calls.append("orderFront")
            super.orderFront(sender)   // → NotePanel's dispatch, which may route elsewhere
        }
        override func orderFrontRegardless() { calls.append("orderFrontRegardless") }
        override func raiseRegardless() { calls.append("raiseRegardless") }
        init(pinned: Bool) {
            super.init(note: Note(color: .yellow, floatOnTop: pinned), content: AnyView(Color.clear))
            apply(floatOnTop: pinned, showOnAllSpaces: true)
        }
    }

    @Test("showing an unpinned note puts it at the floating level for a moment, so it is really on screen")
    func unpinnedShowsAtTemporaryFloat() {
        _ = Spy(pinned: false)   // installs NotePanel's overrides before the measured instance
        let spy = Spy(pinned: false)
        spy.orderFront(nil)
        #expect(spy.calls == ["orderFront", "orderFrontRegardless"])   // an ordinary window, not a raise
        // A `.nonactivatingPanel` at level 0 is never re-ordered onto the screen while another app is
        // frontmost, so the show would be a no-op — and the full-screen policy (which reads "ordered
        // out") could then not take it off a full-screen Space.
        #expect(spy.level == .floating)
    }

    @Test("an unpinned note drops back to the normal level after being shown", .serialized)
    func unpinnedDropsBackToNormal() async throws {
        let spy = Spy(pinned: false)
        spy.orderFront(nil)
        try await Task.sleep(for: .seconds(3))
        #expect(spy.level == .normal)
    }

    @Test("a pinned note stays floating")
    func pinnedStaysFloating() async throws {
        let spy = Spy(pinned: true)
        spy.orderFront(nil)
        #expect(spy.calls == ["orderFront"])
        try await Task.sleep(for: .seconds(3))
        #expect(spy.level == .floating)
    }

    @Test("taking an unpinned note off screen drops the show-time float too, so it really goes away")
    func suppressionDropsTheFloat() {
        let spy = Spy(pinned: false)
        spy.orderFront(nil)
        #expect(spy.level == .floating)
        spy.applyFullScreenSuppression(true)
        #expect(spy.level == .normal)
        #expect(!spy.isVisible)
    }

    @Test("unpinning while the full-screen hold is already on takes the note off screen at once")
    func unpinningWhileSuppressedHidesImmediately() {
        _ = Spy(pinned: false)   // installs NotePanel's overrides before the measured instance
        let spy = Spy(pinned: true)
        spy.applyFullScreenSuppression(true)   // pinned: the hold is noted, the note may stay
        #expect(spy.orderedOutWhileSuppressed)
        spy.orderedOutWhileSuppressed = false   // forget the first take-off; only the re-run matters
        print("DBG visible=\(spy.isVisible) mini=\(spy.isMiniaturized) lvl=\(spy.level.rawValue) pin=\(spy.isPinned) sup=\(spy.suppressedByFullScreen)")
        // The user clicks "unpin": the pin's own `orderOut` at the floating level was refused, so
        // re-running the policy has to try again instead of returning early on the unchanged hold.
        spy.apply(floatOnTop: false, showOnAllSpaces: true)
        spy.applyFullScreenSuppression(true)
        #expect(spy.orderedOutWhileSuppressed)   // the unchanged hold was re-applied, not skipped
        #expect(spy.level == .normal)
    }

    @Test("a background restore of an unpinned note does not raise it")
    func backgroundRestoreDoesNotRaise() {
        _ = Spy(pinned: false)   // installs NotePanel's overrides before the measured instance
        let spy = Spy(pinned: false)
        spy.calls = []
        spy.showInBackground(raise: false)
        #expect(spy.calls == ["orderFrontRegardless"])   // shown, not raised
        #expect(spy.showedAsOrdinary)
    }

    @Test("an explicit 'show me this' raises even an unpinned note")
    func explicitShowRaises() {
        _ = Spy(pinned: false)   // installs NotePanel's overrides before the measured instance
        let spy = Spy(pinned: false)
        spy.calls = []
        spy.showInBackground(raise: true)
        spy.raiseRegardless()
        #expect(spy.calls == ["raiseRegardless", "raiseRegardless"])
    }

    @Test("the pin flag tracks the applied behaviour")
    func pinFlagTracksApply() {
        let panel = makePanel(pinned: false)
        #expect(!panel.isPinned)
        panel.apply(floatOnTop: true, showOnAllSpaces: true)
        #expect(panel.isPinned)
    }
}
