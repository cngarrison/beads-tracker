# Project Instructions for AI Agents

Instructions for Claude Code working on BeadsTracker, reflecting CNG's working preferences.
Adapted from `GUIDELINES.md` (the equivalent file for the BB harness; keep the two in step when
project rules change). Re-running `bd setup claude` would append beads' generic template again
(including "always git push" rules that do not apply here) - remove it if that happens.

## Project

BeadsTracker is a native macOS SwiftUI app (macOS 13+, can open several windows) that provides a
GUI over the `bd` (beads) issue-tracker CLI. All data operations shell out to `bd`; the app keeps
no database or API layer of its own. The project tracks its own development in `bd`.

- **Source:** `ContentView.swift`, `IssueListView.swift` (largest: list/detail/edit views),
  `CreateIssueView.swift`, `Models.swift`, `BeadsRunner.swift` (all `bd` subprocess wrappers),
  `BeadsEventsWatcher.swift` (real-time sync via `bd events tail`), `WorkspaceStore.swift`
  (shared per-workspace in-memory issue store, patched from events), `BTLog.swift`
- **Build/config:** `Makefile`, `Info.plist`, `BeadsTracker.entitlements`, `.github/` (release
  workflow), `scripts/release-version.sh`, `.githooks/`
- **Docs:** `README.md`, `ROADMAP.md`, `CONTRIBUTING.md` (keep its project layout and conventions
  in step with the code), `BEADS.md`

Out of scope: changing the `bd` CLI itself, non-macOS platforms, and backend/server work (no
`bd serve`/HTTP transport is used).

## Build

```bash
make          # native-arch BeadsTracker.app; must exit 0 after any Swift change
make run      # build and open the app (needs to run outside the sandbox)
make universal
```

Inside the sandbox `make` prints harmless `xcrun_db ... Operation not permitted` cache warnings;
only `error:` lines from the Swift compiler matter. If `make` fails, report the exact compiler
error and file/line before changing anything else.

## Code Rules and Known Gotchas

- Follow the patterns already in the file you edit (file-scope helper functions, `@SceneStorage`
  vs `@State` usage, existing SF Symbol and styling conventions) rather than introducing new ones
  without discussion.
- **Never invent `bd` behaviour or JSON fields.** Check real output (`bd show <id> --json`,
  `bd list --json`, `bd <cmd> --help`) before relying on a field or flag.
- **SwiftUI struct capture:** `IssueListView` is a struct. Closures stored by long-lived objects
  (`@StateObject`/`ObservableObject`, e.g. `BeadsEventsWatcher`) must never rely on implicit `self`
  capture of `let` properties such as `workingDirectory` inside parameterless calls like
  `loadIssues()`. Capture an explicit local (`let dir = workingDirectory`) and pass it in
  (`loadIssues(dir: dir)`).
- **Toolbar layout:** the toolbar is deliberately nested inside the left column of the
  `HSplitView`. Moving it to full width breaks dragging the detail-panel divider (tried before;
  do not retry without a different technical approach).
- **Draft protection:** do not remove or bypass the quit-confirmation / draft logic (`AppDelegate`,
  `FormDraftManager`) without CNG's explicit approval; it prevents silent data loss on quit.
- If a request conflicts with one of these gotchas, flag it to CNG before proceeding.

## Git Workflow

Work is local.

- Do NOT push (`git push`) and do not open pull requests. Commit locally on the session's branch,
  then tell CNG the branch is ready. Pushing `main` is CNG's job: CNG runs
  `./scripts/release-version.sh` on `main`, which bumps the version in `Info.plist`, commits, tags
  `vX.Y.Z` and pushes; the tag triggers `.github/workflows/release.yml` to build, sign, notarize
  and publish the release. Never run the script or edit the `Info.plist` version yourself.
- New worktrees/sessions and feature branches are based on the LOCAL `main` branch.
- Name feature/bug branches `claude/<bead-id>-<short-slug>` (e.g. `claude/bt-elk-quit-tail`).
- Completed branches are archived, never deleted. Once a branch is in local `main`
  (`git merge-base --is-ancestor <branch> main` succeeds), rename it under `done/`, keeping its
  full name: `git branch -m claude/<name> 'done/claude/<name>'`. Do this as the last git step of
  the session, and say so.
- `backup/*` branches are created by Fork during rebases, and by Claude before squashing. Leave
  them as they are: do not rename, delete or rebase them.
- Do not remove session worktrees yourself; the app removes a session's worktree when the session
  is archived.

### Bringing a branch into main

When CNG asks to "rebase", "squash" or "bring" a branch into `main`, it means squash and merge.
Do this only when asked, one branch at a time:

1. **Back up the branch**, named the way Fork names its backups
   (`backup/<branch>-<h-mm-ss> am|pm`, 12-hour local time, U+202F before am/pm):
   `git branch "backup/<branch>-$(date '+%-I-%M-%S %p' | tr 'AMP' 'amp' | sed "s/ /$(printf '\342\200\257')/")" <branch>`.
2. **Rebase onto local `main`**: `git rebase main <branch>`. Note the resulting tip.
3. **Squash** into a few commits that each describe a change: `git reset --soft main`, then
   `git reset` and re-commit in groups with `git add`. Messages describe each change as a whole
   (what and why); keep bead ids and Co-Authored-By trailers.
4. **Verify** nothing was lost: `git diff <tip from step 2> <branch>` must be empty; re-run `make`
   if `main` had moved.
5. **Merge** with a merge commit: `git switch main && git merge --no-ff <branch>`. If the branch
   changes files under `.claude/`, the sandbox blocks git from writing them; run the switch and
   merge outside it.
6. **Archive** the branch under `done/` and report the backup branch name and the squashed commits.

## Issue Tracking and Memory (beads)

This project uses **bd (beads)**; run `bd prime` for the full command reference. The beads
database is `bt` on the shared Dolt server (`dolt.shared-server: true`, `127.0.0.1:3308`, under
`~/.beads/shared-server`), the same server bb-saas uses. `bd` must run outside the sandbox to
reach it.

```bash
bd ready                 # Find available work
bd show <id>             # View issue details
bd update <id> --claim   # Claim work
bd close <id>            # Complete work
```

- Use `bd` for all task tracking - not TodoWrite, TaskCreate or markdown TODO lists. Non-trivial
  work should have a bead: create one if needed, `--claim` it when starting, close it when done.
- Use `bd remember` for persistent knowledge - not MEMORY.md files. Memories are loaded at session
  start by `bd prime`.
- `bd dolt push` (syncing beads data to the remote) is CNG's job, like `git push`.

## Finishing a Piece of Work

1. File `bd` issues for remaining or discovered follow-up work.
2. Run `make` (exit 0) if Swift code changed.
3. Update issue status: close finished work; add notes to in-progress issues, including anything
   not verified (e.g. not checked in the running app).
4. Commit locally on the feature branch (do not push).
5. Hand off: say what changed, what was verified, what is left, and that the branch is ready to be
   squashed into `main` and released (`./scripts/release-version.sh`, plus `bd dolt push` if beads
   data changed).
