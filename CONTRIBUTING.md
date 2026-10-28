# Contributing to Beads Tracker

Thank you for your interest in contributing! This project started as a 30-minute experiment in AI-assisted development — and contributions made the same way are absolutely welcome. You don’t need to know Swift.

---

## The spirit of this project

Beads Tracker is a small native SwiftUI app with a deliberately simple build: a handful of `.swift` files compiled directly with `swiftc` by a `Makefile`. No Xcode project, no Swift Package Manager, no third-party dependencies. This keeps the codebase approachable for people who aren’t professional Swift developers.

The app is a GUI over the `bd` CLI: every data operation shells out to `bd`. It keeps no database or API layer of its own, and changes to `bd` itself belong in the [beads](https://github.com/cngarrison/beads) repo, not here.

Please keep it that way: add to the existing files where a change fits, and open an issue to discuss before adding new files, dependencies or build steps.

---

## Ways to contribute

### Without writing any code
- **File a bug** — run `bd create` in this repo and describe what’s wrong
- **Suggest a feature** — check `bd list` and [ROADMAP.md](ROADMAP.md) first, then `bd create` if it’s new
- **Improve the docs** — README, ROADMAP, and this file are all fair game
- **Test on your hardware** — especially Intel Macs and different macOS versions

### With code
- Pick an issue from `bd ready` (or an item from [ROADMAP.md](ROADMAP.md))
- Claim it with `bd update <id> --claim` if you’re working from this repo
- Write the Swift, rebuild with `make`, test manually, send a PR

---

## You don’t need to know Swift

This project was built by someone with no Swift experience, using [Beyond Better](https://BeyondBetter.app) and Claude. If you want to add a feature:

1. Open Beyond Better, Claude Code, or any Claude interface with this repo as context
2. Describe the feature you want to add, referencing the relevant `bd` CLI commands from `bd --help`
3. Iterate on any compile errors (there are usually very few)
4. Test with `make run`
5. Send a PR

Instructions for AI assistants live in [CLAUDE.md](CLAUDE.md) (Claude Code) and [GUIDELINES.md](GUIDELINES.md) (Beyond Better). They list the project’s known pitfalls, which are worth reading whether or not you use an assistant.

---

## Issue Tracker Sync

Beads Tracker uses [beads](https://github.com/cngarrison/beads) (`bd`) for issue tracking. Issues live in a Dolt database (`bt`), synced through this Git repo under `refs/dolt/data` alongside the source code — no separate account or service needed.

**First-time setup** (after cloning):
```bash
bd bootstrap   # pulls the issue database from the remote
bd list        # verify issues are visible
```

**Day-to-day:**
```bash
bd dolt pull   # pull latest issues before starting work
bd dolt push   # push your changes after creating/closing issues
```

With the git hooks installed (`make setup`), `git pull`/`git merge` runs `bd dolt pull` and `git push` runs `bd dolt push` for you.

---

## Development setup

```bash
# Clone the repo
git clone https://github.com/cngarrison/beads-tracker.git
cd beads-tracker

# One-time setup: git hooks + issue tracker bootstrap
make setup

# Build (native architecture)
make

# Build and open the app
make run

# Universal binary (arm64 + x86_64), as built by the release workflow
make universal

# Rebuild the app icon from the SVG (requires: brew install librsvg)
make icon && make

# Remove build output
make clean
```

`make setup` points git at the `.githooks` directory (hooks that sync the issue database with `bd dolt pull`/`bd dolt push`) and runs `bd bootstrap` to pull the issue database from the repo.

No Xcode project, no Swift Package Manager, no dependencies beyond the Xcode Command Line Tools and `bd` on your `PATH`.

```bash
xcode-select --install   # if you don’t have them already
```

### Debug logging

The app is normally launched with `open`, so `print()` output goes nowhere. Use `BTLog` instead; it writes to a log file you can follow while testing:

```bash
tail -f ~/Library/Logs/BeadsTracker/beads-tracker.log
```

---

## Project layout

```
ContentView.swift          ── App entry point (@main), ContentView, top bar, project picker
Models.swift               ── Enums, data structs, date helpers, FormDraftManager, AppDelegate
BeadsRunner.swift          ── CLI interaction layer: all `bd` subprocess calls
BeadsEventsWatcher.swift   ── `bd events tail --follow` subprocess for live updates
WorkspaceStore.swift       ── Shared in-memory copy of a workspace's issues, patched from events
CreateIssueView.swift      ── CreateIssueView, IssueFormContent, shared form helpers
IssueListView.swift        ── Issue list, detail card, Markdown rendering, detail/edit sheets
BTLog.swift                ── File-based diagnostic logger

Info.plist                 ── App bundle metadata, including the version (set by the release script)
BeadsTracker.entitlements  ── Entitlements used when signing releases
Makefile                   ── Build system + icon pipeline
BeadsTracker.svg           ── App icon source (edit to change the icon)
.githooks/                 ── post-merge / pre-push hooks that sync the issue database
.github/workflows/         ── release.yml: build, sign, notarize and publish on version tags
scripts/release-version.sh ── Bump version, tag and push a release
README.md                  ── User-facing docs
ROADMAP.md                 ── Feature ideas and backlog
BEADS.md                   ── Quick reference for agents using `bd` in this repo
CONTRIBUTING.md            ── This file
```

---

## Code conventions

There aren’t many rules, but please follow these:

**Follow the file you’re in** — each file starts with a header comment saying what it holds, and uses `// MARK: -` sections. Put new code where it belongs and follow the existing patterns (file-scope helper functions, `@SceneStorage` vs `@State` usage, SF Symbols and styling).

**`BeadsRunner`** — all `bd` calls go through `BeadsRunner` (most via its `run(_:in:)` helper). The one long-running exception is the `bd events tail` process owned by `BeadsEventsWatcher`. Don’t spawn `Process` directly in views.

**`WorkspaceStore`** — the issue list reads from one in-memory store per workspace path, shared by every window showing it. It is baselined from `bd list --all --json`, patched from `bd events tail`, and re-read in the background every few minutes (the journal doesn’t record `bd dolt pull`, merges or `bd sql` writes). Filters and search are applied in memory, so don’t add `bd list` calls for filtering; after a change made through `BeadsRunner`, call `store.expectOwnChange()` rather than re-reading.

**Don’t guess `bd` output** — check real output (`bd show <id> --json`, `bd list --json`, `bd <command> --help`) before relying on a JSON field or flag.

**Main thread** — `@State` mutations must happen on the main actor. Use `Task.detached` for background work and `DispatchQueue.main.async` (or `await` on the main actor) to update state.

**Closures and struct views** — views like `IssueListView` are structs. A closure stored by a long-lived object (e.g. `BeadsEventsWatcher`) must not rely on implicitly capturing `self`’s properties: copy what it needs into a local first (`let dir = workingDirectory`) and pass it in explicitly (`loadIssues(dir: dir)`).

**Toolbar layout** — the toolbar sits inside the left column of the `HSplitView` on purpose. Moving it to full width breaks dragging the detail-panel divider.

**Unsaved drafts** — `FormDraftManager` and the quit confirmation in `AppDelegate` stop unsaved issue forms being lost when the app quits. Don’t remove or bypass them.

**No third-party dependencies** — only the Swift standard library and Apple frameworks (SwiftUI, AppKit, WebKit).

**macOS 13.0 minimum** — check API availability before using newer APIs. Known pitfall: `.monospaced()` on `Text` requires 13.3+; use `.font(.system(.body, design: .monospaced))` instead.

**Activation policy** — because the app is built with `swiftc -parse-as-library` rather than through Xcode, `NSApplication` can default to a non-regular activation policy (no Dock icon, no ⌘-Tab entry). `BeadsTrackerApp.init()` explicitly calls `NSApplication.shared.setActivationPolicy(.regular)` to fix this. Don’t remove it.

**Raw string Unicode escapes** — Swift raw string literals (`#"..."#`) do **not** process `\u{XXXX}` escape sequences. Use regular string literals when you need Unicode characters in regex patterns or string comparisons.

---

## Submitting a PR

1. Fork the repo and create a branch: `git checkout -b my-feature`
2. Make your changes
3. Confirm `make` succeeds with no errors
4. Test the feature manually with a real beads repository
5. Close the related `bd` issue (and update `ROADMAP.md` if the item is listed there)
6. Open a pull request with a brief description of what you changed and why

Please don’t change the version in `Info.plist`; that’s done at release time.

---

## Releases (maintainers)

Releases are cut from `main` with the release script, which replaces a plain `git push`:

```bash
./scripts/release-version.sh           # patch: 1.2.3 → 1.2.4 (default)
./scripts/release-version.sh --minor   # 1.2.3 → 1.3.0
./scripts/release-version.sh --major   # 1.2.3 → 2.0.0
```

From a clean working tree, the script bumps `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`, commits that as `chore: bump version to X.Y.Z (build N)`, creates an annotated `vX.Y.Z` tag and pushes the commit and the tag to `origin`.

The tag triggers [`.github/workflows/release.yml`](.github/workflows/release.yml), which checks the tag matches `Info.plist`, builds a universal binary, signs it with the Developer ID certificate, packages and notarizes a DMG, and publishes it as a GitHub Release with generated notes.

---

## Reporting bugs

Please include:
- macOS version (`sw_vers`)
- CPU architecture (`uname -m`)
- Output of `bd --version`
- Steps to reproduce
- What you expected vs. what happened
- Any relevant lines from `~/Library/Logs/BeadsTracker/beads-tracker.log`

---

## Questions?

Open an issue or start a discussion. This is a small, friendly project.
