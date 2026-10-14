<div align="center">
  <img src="Assets/AppIcon/Tic-256.png" width="128" alt="Tic icon">
  <h1>Tic</h1>
  <p><strong>Floating, Stickies-style task lists for macOS.</strong></p>

[![CI](https://github.com/kasvith/tic/actions/workflows/ci.yml/badge.svg)](https://github.com/kasvith/tic/actions/workflows/ci.yml)
[![GitHub Release](https://img.shields.io/github/v/release/kasvith/tic)](https://github.com/kasvith/tic/releases)
[![GitHub Downloads](https://img.shields.io/github/downloads/kasvith/tic/total)](https://github.com/kasvith/tic/releases)

<a href="https://www.producthunt.com/products/tic?utm_source=badge-follow&utm_medium=badge&utm_source=badge-tic" target="_blank"><img src="https://api.producthunt.com/widgets/embed-image/v1/follow.svg?product_id=1317575&theme=light" alt="Tic - To&#0045;do&#0032;lists&#0032;that&#0032;live&#0032;on&#0032;your&#0032;desktop&#0044;&#0032;not&#0032;in&#0032;a&#0032;menu&#0032;bar | Product Hunt" style="width: 250px; height: 54px;" width="250" height="54" /></a>

<a href="https://tic.kasvith.me"><img src="site/public/og.png" alt="Tic sticky-note to-do lists floating on a Mac desktop"></a>

</div>

Tic keeps your lists **on the desktop** as floating sticky notes instead of buried behind a menu
bar click — glance at them, check things off, drag them around. Each note is its own checklist.

## Features

- **Floating sticky notes** — borderless, draggable, resizable panels; optional float-on-top and
  show-on-all-Spaces per note. Positions and state are remembered across launches.
- **Multiple lists** — create from the menu bar, **⌘N**, the in-note **+**, or the Dock menu.
  New lists are auto-named *List 1, List 2, …*
- **Rich tasks** — **subtasks** up to 3 levels (completing a parent completes its children),
  **multiline** notes (Shift-Return), and inline Markdown (`**bold**`, `*italic*`, `` `code` ``,
  `~~strike~~`, links). Tap to edit; drag to reorder, or drag right to nest.
- **Solid or Liquid-Glass** notes — per-note color themes, or a translucent material that shows
  the desktop through it.
- **Roll-up** — double-click a note's title bar to collapse it to just the header.
- **Raycast-style search palette** — a floating, centered command palette to search/open/delete
  any list, with keyboard navigation.
- **Launch at Login**, a custom menu-bar icon, and a native Dock identity.
- **Categories** — group lists by project, then show only what you're working on. Hiding a
  category is temporary (it never counts as "closed"), so a note you shut yourself stays shut.
- **Resources** — attach files, folders, repositories, or web links to a note; open in the default
  app, reveal in Finder, or relocate a moved file. Tic stores a reference and never touches the
  original.
- **Deadlines & reminders** — give a task a due date and an optional system notification, with
  **Open Note / Complete / Snooze 10 min** actions right on the banner.
- **Global new-note shortcut** (default **⌘⇧N**) — works from any app, and tells you if the chord
  is already taken.

> This is a **development fork**. It uses a separate data directory, bundle id, and preferences
> from upstream Tic, so it can't read or overwrite your real notes. See
> [`docs/DEVELOPMENT_NOTES.zh-CN.md`](docs/DEVELOPMENT_NOTES.zh-CN.md) for the differences, known
> limits, and backup/recovery steps.

## Requirements

macOS **14 (Sonoma)** or later.

## Install

1. Download `Tic-vX.Y.Z.zip` from the [latest release](https://github.com/kasvith/tic/releases),
   unzip it, and move **`Tic.app`** to `/Applications`.
2. Tic isn't code-signed/notarized (it's ad-hoc signed), so Gatekeeper will block it on first
   launch. Clear the quarantine flag:

   ```sh
   xattr -c /Applications/Tic.app
   ```

   Then open it normally. (Alternatively: right-click `Tic.app` → **Open** → **Open**.)
3. To have Tic open automatically, enable **Launch at Login** from its menu-bar menu.

## Local development roadmap

本地二次开发文档（中文）：[产品与技术方案](docs/DEVELOPMENT_SPEC.zh-CN.md) · [分阶段开发计划](docs/DEVELOPMENT_PLAN.zh-CN.md)。这些文档描述计划中的扩展，当前功能以源码为准。

## Build from source

Tic is a Swift Package — no `.xcodeproj` needed.

```sh
swift run                 # build + launch (dev)
swift build -c release    # release build
swift test                # run the test suite (Swift Testing)
./scripts/package.sh      # assemble dist/Tic.app (add --open to launch it)
open Package.swift        # edit in Xcode
```

## Usage

- The menu-bar icon lists your **recent lists** (with a **More Lists** submenu for the rest) and
  opens **Search Lists…**, **New List** (⌘N), and **Launch at Login**.
- Hover a note to reveal its controls: color, solid/glass, float-on-top, roll-up, **+** new list,
  and close. Click the title to rename; the bottom field adds tasks (Return keeps focus).
- Hover a task to reveal a **✕** (delete) and, below it, a **＋** line — click it to add a subtask
  nested under that row. An empty task you don't fill in disappears when you click away.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| **Return** | Finish editing a task / add the typed task |
| **Shift-Return** (or **⌥ Return**) | New line within the same task |
| **Shift-Tab** | Make the task a subtask (nest one level deeper) |
| **⌃ Shift-Tab** | Un-nest a subtask (move it back out) |
| **⌘N** | New list |
| **⌘⇧N** (configurable) | New list from **any** app — the global shortcut |
| **⌘,** | Preferences |
| **Double-click** the title bar | Roll the note up / down |

You can also **drag a task** to reorder it, or **drag it right** to nest it — the drop indicator
shows where (and at what level) it will land. The relevant chord (`⇧⏎ line`, `⇧⇥ nest`) shows as a
tiny keycap hint right in the field while you're editing, so you don't have to memorise this table.

## Architecture

SwiftUI views hosted inside AppKit `NSPanel`s (the only way to get true desktop-sticky behavior),
backed by **SQLite via GRDB**. An `AppModel` coordinator bridges the menu bar to the window layer.
See [`CLAUDE.md`](CLAUDE.md) for the full breakdown.

**Stack:** Swift 6 · SwiftUI + AppKit · GRDB (SQLite) · `SMAppService` (login item).

## Development & releases

- **CI** (`.github/workflows/ci.yml`) builds, tests, and lints on every push/PR.
- **Changelog** is generated from [Conventional Commits](https://www.conventionalcommits.org)
  with [git-cliff](https://git-cliff.org) (`cliff.toml`) and kept in `CHANGELOG.md`.
- **Releases are tag-based:** push a `v*` tag and the release workflow builds `Tic.app`, generates
  release notes, and publishes a GitHub Release with the zipped app.

  ```sh
  git tag v0.1.0 && git push origin v0.1.0
  ```

Icon source art lives in [`Assets/`](Assets) (AppIcon / Flat / MenuBar).

## License

Released under the [MIT License](LICENSE). © 2026 Kasun Vithanage.
