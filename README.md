# Beads Tracker

A native macOS app for creating, browsing and managing issues in the [beads](https://github.com/gastownhall/beads/) (`bd`) issue tracking system — no CLI required. It stays fast and live on large workspaces, with a thousand issues and many agents working at once.

**Repository:** [github.com/cngarrison/beads-tracker](https://github.com/cngarrison/beads-tracker) · **Author:** [@cngarrison](https://github.com/cngarrison)

<img src="BeadsTracker.svg" alt="Beads Tracker icon" width="96"/>

---

## Screenshots

<table>
  <tr>
    <td align="center"><strong>Create an issue</strong></td>
    <td align="center"><strong>Browse issues</strong></td>
  </tr>
  <tr>
    <td><img src="beads-tracker-create.png" alt="Create tab" width="480"/></td>
    <td><img src="beads-tracker-issues.png" alt="Issues tab" width="480"/></td>
  </tr>
</table>

---

## What it does

`bd` is a powerful local-first issue tracker, but its interface is the terminal. Beads Tracker gives it a native SwiftUI window:

- **Fast on large workspaces.** Each workspace is read once into memory and then kept up to date, so filtering, searching and sorting are instant, with no `bd` call per keystroke. Lists of a thousand issues stay responsive while agents create and update issues around you.
- **Live.** Changes from anyone, including your agents, appear as they happen, using `bd`'s events journal (the **Live** indicator). The list is also re-read in the background every few minutes, to pick up changes the journal doesn't record such as `bd dolt pull`, and it stays on screen while it refreshes.
- **Browse the whole tree.** Epics expand to show their children. Filter by status, priority and type; sort by priority, last modified (an epic rises when its visible children change) or created date; search by title, description, notes, all three, or ID.
- **See and act on issues.** Select one or many (click, ⌘-click, Shift-click) to see them in the detail panel, with description, design, acceptance criteria, notes, comments, dependencies and children. Claim, close or change status, edit fields, due and defer dates, add comments, or copy issues as Markdown.
- **Create issues** with a form that mirrors `bd create-form`: title, description, type, priority, assignee, labels, external reference, design notes, acceptance criteria and dependencies. An unsaved form is kept as a draft, and quitting asks before discarding it.
- **Multi-window.** Open a window per project, each with its own repository, filters and selection. Windows on the same repository share one in-memory copy, and recent repositories are a click away.
- **Works with embedded or server-mode Dolt.** No special configuration: the app shells out to `bd`, so it follows whatever storage mode your project already uses.

---

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools (`xcode-select --install`)
- [`bd`](https://steveyegge.github.io/beads/getting-started/installation) installed and available in your `PATH` (see [PATH note](#bd-not-found) below)
- A beads-initialised repository (one with a `.beads/` directory)

For the icon pipeline only:

```bash
brew install librsvg   # provides rsvg-convert
```

---

## Install

The easiest way to run Beads Tracker is to download the latest signed and notarized disk image from [GitHub Releases](https://github.com/cngarrison/beads-tracker/releases) — built automatically by a GitHub Actions release workflow. Download the `.dmg`, mount it, drag **Beads Tracker** into **Applications**, and launch it; macOS Gatekeeper will not show an unidentified-developer warning since the app is signed and notarized.

Prefer to build it yourself? See [Build & run](#build--run) below.

## Build & run

```bash
# Clone or download this repo, then:
cd beads-tracker

make          # compiles the .swift files → BeadsTracker.app
make run      # compiles + opens the app
make clean    # removes BeadsTracker.app
```

The `Makefile` auto-detects your CPU architecture (`arm64` on Apple Silicon, `x86_64` on Intel) so no configuration is needed.

### Building the icon (optional)

```bash
make icon     # SVG → .icns  (requires librsvg)
make          # rebuilds the app and bundles the icon
```

If the Dock doesn't pick up the new icon immediately:

```bash
killall Dock
```

---

## Usage

### Selecting a repository

Click **Choose…** in the top bar and navigate to any directory that contains a `.beads/` folder. The selection persists between launches.

### Creating an issue

![Create tab](beads-tracker-create.png)

Click **Create** in the top bar. Fill in at minimum the **Title** field (marked `*`), then press **Create Issue** or hit `⌘↵`.

On success, a green banner shows the new issue ID (e.g. `bd-abc`), with **Copy ID** to put it on the clipboard.

Field reference:

| Field | `bd create` flag | Notes |
|---|---|---|
| Title | `--title` | Required |
| Description | `--description` | Multi-line |
| Type | `--type` | task / bug / feature / epic / chore |
| Priority | `--priority` | P0 (critical) → P4 (backlog), default P2 |
| Assignee | `--assignee` | Username or email |
| Labels | `--labels` | Comma-separated |
| External Reference | `--external-ref` | e.g. `gh-123` |
| Dependencies | `--deps` | e.g. `blocks:bd-15` |
| Design Notes | `--design` | Multi-line |
| Acceptance Criteria | `--acceptance` | Multi-line |

### Browsing issues

![Issues tab](beads-tracker-issues.png)

The list loads when you choose a repository and then updates live as issues change (the **Live** indicator), re-reading from `bd` every few minutes. Click **Refresh** (↺, `⌘R`) to re-read now.

- **Filter** by status, priority and type, and **sort** by priority, last modified or created date. Epics expand to show their children, which are sorted the same way.
- **Search** (`⌘F`) by title, description, notes, all three (**All Content**) or ID. An ID search takes several IDs separated by spaces or commas, and shows matching issues whatever their status, priority or type (those menus dim while they are ignored); the other scopes keep the filters.
- **Select** issues (click, ⌘-click, Shift-click or drag) to see them in the detail panel. The pencil button on a card, or a double-click on a row, edits that issue. With one issue selected, the panel's toolbar also has a status menu and copy actions.
- **Right-click** a row to claim or close it, view its full detail, or copy its ID, title or details as Markdown.

Live updates use `bd`'s events journal, which the app turns on for each repository it opens (`bd config set events-journal true`).

---

## `bd` not found

macOS GUI apps launched from the Dock or Finder do not inherit the user's shell `PATH`, so `bd` may not be found even if it works fine in Terminal. The fix is a one-time setup step that tells the OS where Homebrew's binaries live:

```bash
echo $(brew --prefix)/bin | sudo tee /etc/paths.d/homebrew
```

Then restart Beads Tracker. If `bd` is still not found, the app will display the exact command to run with the path that applies to your machine (Intel or Apple Silicon).

---

## Project structure

```
beads-tracker/
├── ContentView.swift        # App entry point (@main), window, top bar, project picker
├── Models.swift             # Data models, date helpers, draft manager, app delegate
├── BeadsRunner.swift        # CLI subprocess layer (bd commands)
├── BeadsEventsWatcher.swift # `bd events tail` subprocess for live updates
├── WorkspaceStore.swift     # Shared in-memory copy of a workspace's issues
├── CreateIssueView.swift    # Create sheet UI
├── IssueListView.swift      # Issue list, detail panel, edit sheet
├── BTLog.swift              # Diagnostic log file
├── Info.plist               # App bundle metadata
├── Makefile                 # Build + icon pipeline
├── BeadsTracker.svg         # App icon source
└── README.md

See CONTRIBUTING.md for the full layout, including the release workflow and scripts.
```

There is no Xcode project, no Swift Package Manager manifest, no third-party dependencies. `swiftc` compiles all source files directly into an `.app` bundle — the entire build is a single `swiftc` invocation in the `Makefile`. This minimal footprint is a deliberate design goal, not an oversight: keeping the codebase small and dependency-free means an AI coding agent (or a new human contributor) can read the whole project in one pass and ship a change without first onboarding onto a large build system.

---

## How this was built

### Background

`beads` (`bd`) is a local-first, git-backed issue tracker that stores everything in a Dolt database inside your repository. It's fast and powerful, but entirely CLI-driven. The idea for Beads Tracker was simple: make it easier to file issues without leaving a GUI context — the same way GitHub Issues or Linear let you create tickets without touching a terminal.

### The experiment

This app was built as a deliberate experiment: *how quickly can a non-Swift developer produce a working, native macOS app with AI assistance?*

The answer: **just over 30 minutes**, using [Beyond Better](https://BeyondBetter.app) — an AI-powered project assistant — with Claude Sonnet as the underlying model.

### The conversation

The session began with a single prompt explaining the goal and sharing:

- The output of `bd create-form` (the interactive TUI for creating issues)
- The full `bd create --help` reference
- A preference for a compiled `.app` bundle via a `Makefile` rather than a full Xcode project
- The desired field scope (matching `bd create-form`), a folder picker for repo selection, and a success banner with a Copy ID button

Claude asked five clarifying questions — delivery format, PATH assumptions, field scope, working directory persistence, and post-submission behaviour — and then produced all three files (`BeadsTracker.swift`, `Info.plist`, `Makefile`) in a single pass.

### Errors encountered

**Compile error #1 — the only error on first build:**

```
BeadsTracker.swift:315: error: 'monospaced' is only available in macOS 13.3 or newer
```

The fix was a one-liner: replace `.monospaced()` (added in 13.3) with `.font(.system(.body, design: .monospaced))` (available since macOS 12). One search-replace, recompile, done.

**Runtime issue — Issues tab showed "No Issues":**

This took two iterations to resolve:

1. **Wrong string literal type.** The regex pattern was written inside a Swift *raw string literal* (`#"..."#`). Raw strings don't process `\u{XXXX}` Unicode escape sequences, so the character class `[\u{25CB}...]` was matching literal backslash-u text rather than ○●◐✓❄. Switching to a regular string literal fixed the escape processing.

2. **Wrong output format.** Even with the escape fixed, nothing matched. Running `bd list --flat | cat -v` revealed the actual output format:
   ```
   ○ bt-e4l [● P2] [task] - Add icon for the app
   ```
   The original regex assumed `○ id ● P2 title` (no brackets, no type field). The real format has `[● P2] [task] -` between the ID and the title. A regex rewrite against the real format fixed it immediately.

Both issues were diagnosed and patched within minutes of being reported.

### Why this matters

The entire app — including the icon SVG, the `Makefile`, the full SwiftUI form, the `bd list` parser, and this README — was produced collaboratively in a single conversation. The developer involved has no Swift experience. Beyond Better handled the context, tracked the files, and applied patches directly to the repository; Claude provided the Swift knowledge and iterative debugging.

For teams using `beads` for issue tracking, this pattern — *describe what you want, iterate on errors, ship* — means a custom native UI is now within reach without dedicated front-end engineering.

---

## What's next

Some features on the roadmap (tracked in this repo's beads database):

- **Custom types** — read the project's beads config to offer project-specific issue types
- **Label filter**, and **grouping** the list by type, status or label
- **Create child issues** from the detail view
- **Dependency graph** — a visual view of what blocks what
- **Menu bar extra** for quick issue creation, and **Open in Terminal** for the selected repository

Contributions welcome — or just describe what you want to [Beyond Better](https://BeyondBetter.app) and send a PR.

---

## License

MIT
