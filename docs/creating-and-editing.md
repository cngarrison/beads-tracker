# Creating and editing issues

[User guide](README.md) › Creating and editing issues

## Creating an issue

![The create form](images/beads-tracker-create.png)

Click **Create** at the left of the top bar. If you have saved an Anthropic API key (see
[Reviewing issues](reviewing.md#settings)), the sheet opens in **Describe** mode; otherwise it
opens the form. Switch between the two with **Describe | Form** at the top of the sheet.

### Describing an issue in your own words

In **Describe** mode, write what you want in plain words: what's wrong or wanted, how urgent it
is, and any issues it belongs under, depends on or follows on from. For example: *"Quit hangs
when an events tail is running. Pretty urgent; follow-up to the events watcher work."* Then
click **Fill In Form** (`⌘↵`).

Claude fills in the form: title, description, type, priority, labels, parent, dependencies,
and design notes or acceptance criteria if you described them. Nothing is created yet. The form
opens with a banner saying Claude filled it in; check and change anything, then click **Create
Issue** as usual. **Edit Description** goes back to your text to change it and try again.

- **Possible duplicates.** If existing issues, open or closed, look like they already cover
  the same thing, a banner lists them with Claude's reason. **Link as Related** adds a
  `related:` dependency on that issue.
- **Your original text is kept.** It is put in the new issue's **Notes**, quoted under
  "Original request from *your initials*, *date*", so nothing you wrote is lost.
- **Only real issue ids.** Claude gets a list of this project's issues to link to: every issue
  that isn't closed, closed issues whose words match your description, the most recently
  changed closed issues, and any issue you name by id. Any id it returns that isn't on that
  list is left out, and the banner says which.

This sends your description and that issue list (ids, titles and the start of each
description) to the Anthropic API, using the model, effort and output limit from the review
settings, billed to your API key. Each request and Claude's answer are saved in
`~/Library/Logs/BeadsTracker/briefs/` (files ending `-new-issue.json`). **Stop** cancels a
request that is taking too long.

### Filling in the form

Fill in at least the **Title** (marked `*`), then click **Create Issue** or press `⌘↵`.
**Create & Add Another** creates the issue and keeps the sheet open for the next one; **Clear**
empties the form and your description.

A green banner shows the new issue's ID, with **Copy ID** to put it on the clipboard.

The form mirrors `bd create-form`:

| Field | `bd create` flag | Notes |
|---|---|---|
| Title | `--title` | Required |
| Description | `--description` | Multi-line |
| Type | `--type` | task, bug, feature, epic or chore |
| Priority | `--priority` | P0 (critical) to P4 (backlog); P2 by default |
| Assignee | `--assignee` | Username or email |
| Labels | `--labels` | Comma-separated |
| External Reference | `--external-ref` | e.g. `gh-123` |
| Parent | `--parent` | The epic or issue this one belongs under; the new issue gets a child id such as `bd-a3f8.1` |
| Dependencies | `--deps` | Comma-separated, e.g. `blocks:bd-15, related:bd-20` |
| Design Notes | `--design` | Multi-line |
| Acceptance Criteria | `--acceptance` | Multi-line |
| Notes | `--notes` | Multi-line; holds your original text when Claude filled in the form |

### Drafts

If you quit while the create form (or your description in Describe mode) has unsaved content, Beads Tracker asks first: **Save Draft
& Quit** keeps what you typed, **Discard & Quit** throws it away, and **Cancel** keeps the app
open. Next time you open the form, a banner offers to **Resume** the draft or **Discard** it.

## Editing an issue

Open the edit sheet with the pencil on a detail card, **Edit** in the detail panel's toolbar,
**Edit…** in a row's right-click menu, or by double-clicking a row. Change any of the fields
above, then click **Save** (`⌘↵`); **Cancel** (`Esc`) leaves the issue as it was.

The sheet also has:

- **Dates**: set or clear the **Due** and **Defer** dates.
- **Dependencies**: add one by typing an issue ID and picking its type (blocks, tracks,
  related, parent-child or discovered-from), or remove one with its button. These are applied
  straight away.
- **Notes**: saved with the other fields when you click **Save**. To add a signed, dated line
  without opening the sheet, use the note button on a card instead (see
  [Reply in Notes](reviewing.md#reply-in-notes)).
- **Comments**: type a comment and click **Add**. If you click **Save** with a comment typed but
  not added, the app asks whether to add it or discard it.

## Changing status

With one issue selected, the **Status** menu in the detail panel's toolbar sets it to Open, In
Progress, Blocked, Deferred or Closed. A row's right-click menu also has **Claim** (assign it
to you and mark it in progress, as `bd update --claim` does) and **Close**.

## Next

- [Reviewing issues](reviewing.md)
