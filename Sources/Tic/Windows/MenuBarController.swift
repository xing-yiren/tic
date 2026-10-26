import AppKit
import SwiftUI

/// The status-bar item and its menu, built with AppKit rather than a SwiftUI `MenuBarExtra`.
///
/// A `.menu`-style `MenuBarExtra` only supports plain items: no submenus, and no context menus on
/// an item — both of which the menu needs (a "More Lists" submenu, and right-click → Delete on a
/// list). An `NSMenu` gets both natively. The menu is rebuilt on every open, so it always reflects
/// the current lists and categories.
///
/// It also hosts the icon, mirroring `MenuBarLabel`'s template glyph + unseen-update dot (see
/// `TicApp.swift`). Main-actor isolated: the menu delegate callbacks and every `@objc` action are
/// delivered on the main thread, which `NSMenuItem.target` dispatch satisfies.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private var updateObserver: Task<Void, Never>?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = Self.icon(badged: AppModel.shared.updates.isUnseen)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        observeUpdateBadge()
        if Self.debugLog {
            // Ask what the system is going to show straight away: the menu-bar scene extension may
            // read the items itself without calling the delegate for every open.
            let probe = NSMenu()
            rebuild(probe)
            NSLog("[Tic] menu probe built with %d items", probe.numberOfItems)
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Opening the icon's menu is the user reaching for Tic: the notes currently on screen stay
        // visible over a full-screen app until the user goes back to it.
        AppModel.shared.noteUserReachedForTic()
        if Self.debugLog {
            let line = "[Tic] menu opened fullScreen=\(AppModel.shared.windows.otherAppIsFullScreen ? 1 : 0) summoned=\(AppModel.shared.windows.summonedWhileFullScreen.count)"
            NSLog("%@", line as NSString)
        }
        rebuild(menu)
    }

    /// Set `TIC_MENU_DEBUG=1` to log the menu as it is built (how to verify the AppKit menu when
    /// AX can't drive a system status item). Off unless the variable is set.
    private static let debugLog = ProcessInfo.processInfo.environment["TIC_MENU_DEBUG"] != nil

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let model = AppModel.shared

        menu.addItem(item("New List", action: #selector(newList), key: "n"))
        menu.addItem(item("Overview…", action: #selector(openOverview), key: "o"))
        menu.addItem(.separator())

        appendRecentLists(to: menu, model: model)

        menu.addItem(.separator())
        menu.addItem(categoryItem(model: model))
        menu.addItem(item("Manage Categories…", action: #selector(manageCategories)))
        let hideAll = item("Hide All Notes", action: #selector(toggleHideAll))
        hideAll.state = model.hideAllActive ? .on : .off
        menu.addItem(hideAll)

        menu.addItem(.separator())
        menu.addItem(item("Search Lists…", action: #selector(searchLists)))
        menu.addItem(item("AI Agents (MCP)…", action: #selector(mcpSetup)))
        menu.addItem(item("Preferences…", action: #selector(preferences), key: ","))

        let launchAtLogin = item("Launch at Login", action: #selector(toggleLaunchAtLogin))
        launchAtLogin.state = model.launchAtLogin ? .on : .off
        menu.addItem(launchAtLogin)

        if let title = model.updates.menuTitle {
            menu.addItem(.separator())
            menu.addItem(item(title, action: #selector(openReleasePage)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Quit Tic", action: #selector(quit), key: "q"))

        if Self.debugLog {
            NSLog("[Tic] menu rebuilt: %@", menu.items.map { Self.describe($0, depth: 1) }.joined(separator: " | ") as NSString)
        }
    }

    private static let recentCount = 5
    private static let moreCount = 95   // 5 + 95 = up to 100 reachable from the menu

    /// The five most recently updated lists, plus a "More Lists" submenu for the next 95. Each list
    /// item opens on click and offers **Delete** on right-click (an `NSMenu` context menu).
    private func appendRecentLists(to menu: NSMenu, model: AppModel) {
        let recent = model.notes.sorted { $0.updatedAt > $1.updatedAt }
        guard !recent.isEmpty else {
            menu.addItem(disabled("No lists yet"))
            return
        }
        for note in recent.prefix(Self.recentCount) {
            menu.addItem(listItem(note))
        }
        let more = Array(recent.dropFirst(Self.recentCount).prefix(Self.moreCount))
        if !more.isEmpty {
            let submenuItem = NSMenuItem(title: "More Lists", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for note in more { submenu.addItem(listItem(note)) }
            submenuItem.submenu = submenu
            menu.addItem(submenuItem)
        }
    }

    /// A list's item. Its action opens the list; its `submenu` is what macOS shows on right-click,
    /// which is the only way to delete a list from the menu.
    private func listItem(_ note: Note) -> NSMenuItem {
        let item = NSMenuItem(title: Self.title(of: note), action: #selector(openList(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = note.id

        let actions = NSMenu()
        let open = NSMenuItem(title: "Open", action: #selector(openList(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = note.id
        actions.addItem(open)
        let delete = NSMenuItem(title: "Delete…", action: #selector(deleteList(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = note.id
        actions.addItem(delete)
        item.submenu = actions
        if Self.debugLog { NSLog("[Tic] list item: %@ (delete action present: %d)", item.title as NSString, actions.numberOfItems) }
        return item
    }

    /// Mirrors the category filter: "All Categories", one checkable entry per category, and
    /// "Uncategorised", plus a way into the category manager.
    private func categoryItem(model: AppModel) -> NSMenuItem {
        let root = NSMenuItem(title: "Show Categories", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let all = item("All Categories", action: #selector(showAllCategories))
        all.state = model.categoryFilter.mode == .all ? .on : .off
        menu.addItem(all)
        menu.addItem(.separator())
        for category in model.categories {
            let entry = item("Show \(category.name)", action: #selector(toggleCategory(_:)))
            entry.representedObject = category.id
            entry.state = model.categoryFilter.mode == .all || model.categoryFilter.categoryIDs.contains(category.id)
                ? .on : .off
            menu.addItem(entry)
        }
        let uncategorised = item("Show Uncategorised", action: #selector(toggleUncategorised))
        let f = model.categoryFilter
        uncategorised.state = f.mode == .all || f.includesUncategorized ? .on : .off
        menu.addItem(uncategorised)
        if model.categories.isEmpty {
            menu.addItem(disabled("No categories yet"))
        }
        menu.addItem(.separator())
        menu.addItem(item("Manage Categories…", action: #selector(manageCategories)))
        root.submenu = menu
        return root
    }

    private static func describe(_ item: NSMenuItem, depth: Int) -> String {
        let pad = String(repeating: "  ", count: depth)
        let kids = (item.submenu?.items ?? []).map { describe($0, depth: depth + 1) }.joined()
        return "\n\(pad)- \(item.title) [\(item.isSeparatorItem ? "sep" : "item")]\(kids)"
    }

    // MARK: - List lifecycle

    private func note(for item: NSMenuItem) -> Note? {
        guard let id = item.representedObject as? UUID else { return nil }
        return AppModel.shared.notes.first { $0.id == id }
    }

    /// Open a list from the menu. (While an app is full screen this also brings the list into that
    /// full-screen Space — see `NoteWindowManager.bringToFront`.)
    @objc private func openList(_ sender: NSMenuItem) {
        guard let note = note(for: sender) else { return }
        AppModel.shared.open(note)
    }

    /// Delete a list from the menu, behind a confirmation: the item sits right next to Open, so a
    /// stray click must not destroy a note. The note is re-read by id — the menu may be stale.
    @objc private func deleteList(_ sender: NSMenuItem) {
        guard let note = note(for: sender) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(Self.title(of: note))”?"
        alert.informativeText = "This permanently deletes the list and its tasks."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete List")
        alert.addButton(withTitle: "Cancel")
        // The triggering item's window is the menu; use the list itself as the sheet anchor.
        let confirm: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            AppModel.shared.delete(note)
        }
        // A sheet needs a visible window to attach to; with the menu open and nothing on screen
        // (or the note hidden) fall back to a modal alert.
        if let host = NSApp.windows.first(where: { $0.isVisible && $0 is NotePanel }) {
            alert.beginSheetModal(for: host, completionHandler: confirm)
        } else {
            NSApp.activate()
            confirm(alert.runModal())
        }
    }

    private static func title(of note: Note) -> String {
        note.title.isEmpty ? "Untitled List" : note.title
    }

    // MARK: - Actions

    @objc private func newList() { AppModel.shared.newNote() }
    @objc private func openOverview() { AppModel.shared.openOverview() }
    @objc private func manageCategories() { AppModel.shared.openCategories() }
    @objc private func toggleHideAll() { AppModel.shared.setHideAll(!AppModel.shared.hideAllActive) }
    @objc private func searchLists() { AppModel.shared.openSearch() }
    @objc private func mcpSetup() { AppModel.shared.openMCPSetup() }
    @objc private func preferences() { AppModel.shared.openSettings() }
    @objc private func toggleLaunchAtLogin() { AppModel.shared.setLaunchAtLogin(!AppModel.shared.launchAtLogin) }
    @objc private func openReleasePage() { AppModel.shared.updates.openReleasePage() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showAllCategories() { AppModel.shared.showAllCategories() }
    @objc private func toggleCategory(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        AppModel.shared.toggleCategoryVisibility(id)
    }
    @objc private func toggleUncategorised() { AppModel.shared.toggleUncategorizedVisibility() }

    // MARK: - Item helpers

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Icon

    /// Redraws the icon when the unseen-update flag flips while the app runs.
    private func observeUpdateBadge() {
        updateObserver = Task { [weak self] in
            var seen = AppModel.shared.updates.isUnseen
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let now = AppModel.shared.updates.isUnseen
                guard now != seen else { continue }
                seen = now
                self?.statusItem.button?.image = Self.icon(badged: now)
            }
        }
    }

    private static func icon(badged: Bool) -> NSImage? {
        MenuBarLabel.image(badged: badged)
    }
}
