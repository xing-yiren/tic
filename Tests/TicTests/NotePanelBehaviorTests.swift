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
        let note = Note(color: .yellow, floatOnTop: pinned, showOnAllSpaces: true)
        let panel = NotePanel(note: note, content: AnyView(Color.clear))
        panel.apply(floatOnTop: pinned, showOnAllSpaces: true)
        return panel
    }

    /// Records which ordering primitive a panel ends up using.
    final class Spy: NotePanel {
        var calls: [String] = []
        override func orderFront(_ sender: Any?) {
            calls.append("orderFront")
            super.orderFront(sender)   // → NotePanel's dispatch, which may route elsewhere
        }
        override func showAsOrdinaryWindow() { calls.append("orderFrontRegardless") }
        override func raiseRegardless() { calls.append("raiseRegardless") }
        init(pinned: Bool) {
            super.init(note: Note(color: .yellow, floatOnTop: pinned), content: AnyView(Color.clear))
            apply(floatOnTop: pinned, showOnAllSpaces: true)
        }
    }

    @Test("an unpinned note never uses the unordered orderFront (which shows over other apps)")
    func unpinnedOrdersAsOrdinaryWindow() {
        let spy = Spy(pinned: false)
        spy.orderFront(nil)
        #expect(spy.calls == ["orderFront", "orderFrontRegardless"])   // never a plain super.orderFront
    }

    @Test("a pinned note is ordered normally, so it floats in front")
    func pinnedOrdersNormally() {
        let spy = Spy(pinned: true)
        spy.orderFront(nil)
        #expect(spy.calls == ["orderFront"])
    }

    @Test("a background restore of an unpinned note does not raise it")
    func backgroundRestoreDoesNotRaise() {
        let spy = Spy(pinned: false)
        spy.showInBackground(raise: false)
        #expect(spy.calls == ["orderFrontRegardless"])   // shown, not raised
    }

    @Test("an explicit 'show me this' raises even an unpinned note")
    func explicitShowRaises() {
        let spy = Spy(pinned: false)
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
