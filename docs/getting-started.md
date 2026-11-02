# Getting started

[User guide](README.md) › Getting started

## Requirements

- macOS 13 (Ventura) or later
- [`bd`](https://steveyegge.github.io/beads/getting-started/installation) installed. Apps
  opened from the Dock or Finder don't see your shell's `PATH`, so if `bd` lives in Homebrew
  you may need the one-time fix in [Troubleshooting](troubleshooting.md#bd-not-found).
- A repository that uses beads (one with a `.beads/` directory). Run `bd init` in it first if
  it doesn't have one.

## Install

Download the latest `.dmg` from
[GitHub Releases](https://github.com/cngarrison/beads-tracker/releases), open it and drag
**Beads Tracker** into **Applications**. The app is signed and notarized, so macOS opens it
without an unidentified-developer warning.

To build it yourself instead, see [Build from source](../README.md#build-from-source).

## Open a repository

Click **Choose…** at the right of the top bar and pick a directory that contains a `.beads/`
folder. The issue list loads, and the window title changes to the repository's name.

The folder menu beside **Choose…** lists the last ten repositories you opened; pick one to
switch to it. **Clear Recents** empties the list.

Beads Tracker works with whatever storage your repository already uses (embedded or
server-mode Dolt). It runs `bd` for every change, so what you see is what `bd` sees.

## Windows

Open another window with **File › New Window** (`⌘N`), for example one per project. Each window
keeps its own repository, filters, selection and panel width, and macOS restores them when you
relaunch. Windows showing the same repository share one copy of its issues, so a change made in
one appears in the other at once.

## Live updates

When you open a repository the app turns on `bd`'s events journal for it
(`bd config set events-journal true`) and follows it, so changes made by anyone (you in
Terminal, or your agents) appear in the list as they happen. The **Live** indicator in the
list's toolbar (a green dot) shows this is working; **Manual** (a grey dot) means live updates
aren't available, and the list changes only when it is re-read (see
[Troubleshooting](troubleshooting.md#the-list-says-manual-instead-of-live)).

Some changes don't go through the journal, such as `bd dolt pull`, so the app also re-reads the
whole list in the background every few minutes. The list stays on screen while it does. Click
**Refresh** (↺, `⌘R`) to re-read now.

## Next

- [Browsing and filtering](browsing.md)
- [Creating and editing issues](creating-and-editing.md)
