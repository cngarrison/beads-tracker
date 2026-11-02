# Troubleshooting

[User guide](README.md) › Troubleshooting

## `bd` not found

Apps opened from the Dock or Finder don't get your shell's `PATH`, so the app may not find `bd`
even though it works in Terminal. The app adds the directories listed in `/etc/paths` and
`/etc/paths.d/` to its search path, so a one-time setup step that adds Homebrew's directory
there fixes it:

```bash
echo $(brew --prefix)/bin | sudo tee /etc/paths.d/homebrew
```

Then quit and reopen Beads Tracker. If `bd` still isn't found, the app's error message shows the
exact command for your Mac (Apple Silicon and Intel Macs keep Homebrew in different places).

## The list says Manual instead of Live

**Manual** means the app couldn't follow the repository's events journal, so changes made
outside this app appear only when the list is re-read: every few minutes in the background, or
when you click **Refresh** (`⌘R`). Check in Terminal, in the repository, that `bd` works and the
journal can be turned on:

```bash
bd config set events-journal true
```

Then click **Refresh**. The `[events]` lines in the log file (below) show what went wrong.

## A change made elsewhere doesn't show

Some changes don't go through the events journal, such as `bd dolt pull`. The background
re-read picks them up within a few minutes; click **Refresh** (`⌘R`) to see them now.

## The log file

Beads Tracker writes a diagnostic log to `~/Library/Logs/BeadsTracker/beads-tracker.log`: live
updates (under `[events]`, including whether the events journal could be turned on), re-reads
of the issue list (`[store]`), and the timings and errors of each Claude brief (`[brief]`). Open it in Console, or follow it in Terminal:

```bash
tail -f ~/Library/Logs/BeadsTracker/beads-tracker.log
```

Each Claude brief's request and response are saved as JSON files in
`~/Library/Logs/BeadsTracker/briefs/`; see [The Claude brief](reviewing.md#the-claude-brief).

When you [report a problem](https://github.com/cngarrison/beads-tracker/issues), the relevant
lines of the log help. Check them first for anything you'd rather not share, such as issue
titles.
