# How Beads Tracker was built

*Project history: how the first version was written. For using the app, see the [user guide](../docs/README.md).*

## Background

`beads` (`bd`) is a local-first, git-backed issue tracker that stores everything in a Dolt database inside your repository. It's fast and powerful, but entirely CLI-driven. The idea for Beads Tracker was simple: make it easier to file issues without leaving a GUI context — the same way GitHub Issues or Linear let you create tickets without touching a terminal.

## The experiment

This app was built as a deliberate experiment: *how quickly can a non-Swift developer produce a working, native macOS app with AI assistance?*

The answer: **just over 30 minutes**, using [Beyond Better](https://BeyondBetter.app) — an AI-powered project assistant — with Claude Sonnet as the underlying model.

## The conversation

The session began with a single prompt explaining the goal and sharing:

- The output of `bd create-form` (the interactive TUI for creating issues)
- The full `bd create --help` reference
- A preference for a compiled `.app` bundle via a `Makefile` rather than a full Xcode project
- The desired field scope (matching `bd create-form`), a folder picker for repo selection, and a success banner with a Copy ID button

Claude asked five clarifying questions — delivery format, PATH assumptions, field scope, working directory persistence, and post-submission behaviour — and then produced all three files (`BeadsTracker.swift`, `Info.plist`, `Makefile`) in a single pass.

## Errors encountered

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

## Why this matters

The entire app — including the icon SVG, the `Makefile`, the full SwiftUI form, the `bd list` parser, and the first README — was produced collaboratively in a single conversation. The developer involved has no Swift experience. Beyond Better handled the context, tracked the files, and applied patches directly to the repository; Claude provided the Swift knowledge and iterative debugging.

For teams using `beads` for issue tracking, this pattern — *describe what you want, iterate on errors, ship* — means a custom native UI is now within reach without dedicated front-end engineering.

