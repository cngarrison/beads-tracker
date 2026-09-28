---
title: BeadsTracker Project Guidelines
version: 1.0.0
created: 2026-09-28
updated: 2026-09-28
purpose: Working agreement for BB collaboration on the BeadsTracker macOS app project
---

# BeadsTracker Project Guidelines

## Project Purpose and Scope

BeadsTracker is a single-window (multi-window capable) native macOS SwiftUI app that provides a
GUI over the `bd` (beads) issue-tracker CLI. It lets a user create, view, edit, filter, and manage
beads issues without hand-typing CLI commands, while shelling out to `bd` for all actual data
operations (no separate database or API layer maintained by this app).

This BB project/collaboration is used for ongoing feature development, bug fixes, and maintenance
of the BeadsTracker Swift codebase — implementing features, fixing UI/UX issues, wiring new `bd`
subcommands into the Swift wrapper, and keeping build/release tooling working.

**In scope:**
- Swift/SwiftUI source changes (`*.swift` files) implementing UI and `bd` CLI integration
- Build tooling (`Makefile`, icon generation, entitlements, Info.plist)
- GitHub Actions release workflow and release scripts
- Documentation (README.md, ROADMAP.md, CONTRIBUTING.md, BEADS.md)
- Issue tracking of project work via `bd` itself (this project is meta: it tracks its own
  development using the same `bd` tool it provides a UI for)

**Out of scope:**
- Modifying the `bd` CLI itself (it's an external dependency/tool, not part of this codebase)
- Non-macOS platforms (no iOS/Linux/Windows targets)
- Backend/server work (no `bd serve`/HTTP transport currently used — see BeadsEventsWatcher notes)

**Expected outcomes:** working, buildable (`make` exit 0) Swift app changes; issues tracked in `bd`
for all non-trivial work; changes committed and pushed per the session completion protocol.

## Restrictions and Guardrails

1. **BB auto-commits to git after every mutating tool call.** Each `write_resource`,
   `edit_resource`, `apply_patch`, `move_resources`, `remove_resources`, or `rename_resources` call
   is automatically committed to git as it completes — there is no separate manual git-commit step
   for BB to perform or track, and no need to remind CNG of pending `git add`/`git commit` commands.
   - **Pushing to the remote is exclusively the human user's (CNG's) responsibility.** BB does not
     run `git push` (git is not in the `execute` allow-list for this datasource anyway: `ls, pwd,
     cat, find, grep, rg, tree, head, tail, which, whereis, env, bd, make`). BB should still note
     when a session's changes are ready to be pushed, but must not attempt or claim to push.
   - `bd dolt push` (pushing the beads issue-tracker database itself) is a separate concern from
     app-code git push — see BEADS.md for the beads-specific push workflow.
2. **Always run `make` after non-trivial Swift changes** to verify the build compiles (exit 0)
   before considering work complete. Report build failures with the exact error output.
3. **Never fabricate `bd` CLI behavior or JSON schema.** Confirmed schemas (e.g. `bd show --json`
   fields, `bd list --json` fields) should be treated as ground truth from prior sessions (see
   project-context memory) — verify against actual `bd` output via `execute` if uncertain, don't
   guess new fields.
4. **Do not remove or bypass the draft-protection / quit-confirmation logic** (`AppDelegate`,
   `FormDraftManager`) without explicit user approval — it exists to prevent silent data loss on
   app quit.
5. **SwiftUI struct-capture gotcha (learned the hard way):** `IssueListView` is a value-type
   struct. Closures stored by long-lived objects (`@StateObject`/`@ObservableObject`, e.g.
   `BeadsEventsWatcher`) must NEVER rely on implicit `self` capture of `let` properties like
   `workingDirectory` inside parameterless calls (e.g. `loadIssues()`). Always capture an explicit
   local (`let dir = workingDirectory`) and pass it into the closure/function call explicitly
   (`loadIssues(dir: dir)`).
6. **Do not touch the toolbar/drag-handle layout structure without care** — the toolbar is
   intentionally nested inside the left column of the `HSplitView`; moving it to full-width breaks
   the drag gesture for the detail-panel divider (confirmed broken previously, do not re-attempt
   without a different technical approach).
7. **BEADS.md is the authoritative reference for beads issue-tracker workflow** (`bd onboard`/
   `bd prime`, quick-reference commands, and the beads-specific session-completion/push protocol
   for the `.beads` Dolt database). It is no longer part of the system prompt automatically —
   GUIDELINES.md now serves that role — so consult `BEADS.md` directly (`load_resources`) at the
   start of sessions involving issue tracking, or whenever beads command details are needed. Use
   `bd` for ALL task tracking in this repo; do not use ad hoc TODO lists or MEMORY.md files. Use the
   `memory` tool for BB's own cross-session notes only (separate from beads issue tracking).

## Available Data Sources and Resources

Single filesystem data source: **beads-tracker** (primary, root `~/working/beads-tracker`).

Key resources:
- **Source files:** `ContentView.swift`, `IssueListView.swift` (largest, ~84KB — list/detail/edit
  views), `CreateIssueView.swift`, `Models.swift`, `BeadsRunner.swift` (all `bd` CLI subprocess
  wrapper methods), `BeadsEventsWatcher.swift` (real-time `bd events tail` sync)
- **Build/config:** `Makefile`, `Info.plist`, `BeadsTracker.entitlements`, `.github/` (release
  workflow), `scripts/` (release-version.sh)
- **Docs:** `README.md`, `ROADMAP.md`, `CONTRIBUTING.md`, `BEADS.md`, `NEW_PROJECT_SETUP.md` (BB
  guidelines template, not app-specific), this `GUIDELINES.md`
- **Assets:** `BeadsTracker.svg`/`.icns`/`.png`, screenshots (`beads-tracker-create.png`,
  `beads-tracker-issues.png`)
- **Issue tracker data:** `.beads/` directory (Dolt-backed beads database for this project's own
  issue tracking — accessed via `bd` commands, not direct file edits)
- **Access:** read/write/edit/execute all permitted on this single data source; no restricted
  subdirectories beyond standard git-ignored build artifacts (`.gitignore`)

## Tool Usage Guidelines

- **Reading/editing Swift files:** use `load_resources` before any edit; use `edit_resource`
  (searchReplace) for targeted changes, `apply_patch` for multi-hunk changes, `write_resource` only
  for full-file rewrites (rare given file sizes — prefer targeted edits).
- **Exploring `bd` CLI behavior or schema:** use `execute` with `bd` subcommands (e.g. `bd show
  <id> --json`, `bd list --json`) to verify actual output before relying on remembered schema.
- **Verifying builds:** use `execute` with `make` after Swift changes.
- **Large/multi-file changes:** prefer `delegate_tasks` for self-contained feature implementations
  spanning several files, keeping the main conversation focused on review/coordination.
- **Memory:** consult `beads-ui/project-context.md` (project-scope memory) at the start of any
  substantial session — it contains the authoritative running history of implementation decisions,
  gotchas, and pending git-commit messages. Update it after significant changes rather than
  creating new memory files, to keep project history in one coherent place.

## Quality Standards

- Every Swift change must build cleanly (`make` exit 0) before being considered done.
- Non-trivial work should correspond to a `bd` issue (create if one doesn't exist, `--claim` when
  starting, `close` when done).
- Follow existing code patterns already established in the file being edited (e.g. file-scope
  helper functions, `@SceneStorage` vs `@State` usage patterns, existing SF Symbol / styling
  conventions) rather than introducing new patterns without discussion.
- Since BB auto-commits after each mutating tool call, there's no need to track or report pending
  commit commands. After completing work, simply note that changes are committed locally and ready
  for CNG to push (`git push`, plus `bd dolt push` if beads issue data changed — see BEADS.md).

## Error Handling

- If `make` fails, report the exact compiler error and file/line before attempting further changes.
- If a `bd` command's output doesn't match the previously documented schema, re-verify via
  `execute` and update `project-context.md` memory with the corrected schema.
- If a requested change conflicts with a documented gotcha above (struct capture, toolbar layout,
  draft protection), flag the conflict to CNG before proceeding rather than silently overriding it.

## Collaboration Workflow

1. Check `bd ready` / relevant `bd show <id>` at session start if resuming tracked work.
2. Check `beads-ui/project-context.md` memory for recent history and any pending git-commit
   reminders from prior sessions.
3. Implement change(s), verify with `make`.
4. Update `project-context.md` memory with what changed and why (keep it as one running log,
   trimming/consolidating older entries if it grows unwieldy).
5. Close/update `bd` issues to reflect current status.
6. Note that changes are auto-committed and ready; remind CNG that pushing (`git push` /
   `bd dolt push`) is their responsibility — never attempt or claim to push on their behalf.
