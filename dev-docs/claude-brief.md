# How the Claude brief works

*Developer notes. For using Needs you and the brief, see the README's "Reviewing issues" section.*

When **Needs you** is set to Claude (gear on the review bar → *Find questions and decisions
with: Claude*), BeadsTracker asks Claude to turn one issue into a short, plain-language
**brief**: a summary, a few key points, and every question or decision waiting on you, each
with options you can pick and record in Notes.

This page explains what the app sends, what it expects back, the settings that shape the
request, and what can go wrong. The code is in `ReviewTools.swift` (`AnthropicReview`,
`NeedsYouAI`); the card that shows the brief is `IssueDetailCard` in `IssueListView.swift`.

---

## The flow

1. **Trigger.** A brief is requested when Needs you is on for an issue that has no brief yet
   (a click on **Needs you** turns it on for the issues shown; **Always Show** turns it on for
   every issue). After that it is only remade when you press ↺ or **Refresh**, or once the new
   Notes arrive after you **Record answers in Notes**. Other changes to the issue mark the brief
   out of date but don't call Claude again.
2. **Request.** One call to the Anthropic Messages API (`POST https://api.anthropic.com/v1/messages`),
   with the issue's text and a system prompt (below). Your API key is read from the Keychain.
3. **Wait.** The answer is not streamed: nothing comes back until Claude has finished thinking
   and writing the whole brief. The header counts the seconds.
4. **Read.** The API guarantees the answer matches a JSON schema (structured outputs). The app
   reads it, tidies it (trims text, drops empty items, keeps `recommended` only if it names one
   of the options) and shows it.
5. **Answer.** You pick options and/or write comments; **Record answers in Notes** appends one
   signed, dated line per answer to the issue's Notes in a single `bd update --append-notes`.
6. **Refresh.** When those Notes arrive (via the live events stream), the brief is remade, and
   the items you answered should drop out.

Briefs are kept in memory per issue for the life of the app; nothing is written to disk except
the log line and the saved request/response described under
[Saved requests and responses](#saved-requests-and-responses) and [Timing and logs](#timing-and-logs).

---

## What is sent

### Headers

| Header | Value |
|---|---|
| `x-api-key` | your Anthropic API key (from the Keychain) |
| `anthropic-version` | `2026-10-21` |
| `content-type` | `application/json` |

### Body

```json
{
  "model": "claude-haiku-5-5",
  "max_tokens": 32000,
  "system": "<system prompt, below>",
  "output_config": {
    "effort": "low",
    "format": { "type": "json_schema", "schema": { "...": "the schema below" } }
  },
  "messages": [
    { "role": "user", "content": "Issue: <title>\n\n<sections>" }
  ]
}
```

`model`, `effort` and `max_tokens` come from the review settings (see [Parameters](#parameters)).
There is no `thinking` field: on current models thinking is adaptive and always on, and
`effort` controls how much of it Claude does.

### The issue content (user message)

The user message is the issue title followed by each non-empty section, wrapped in tags:

```text
Issue: Persist the workspace cache across launches

<section name="Description">
...the issue's description, as Markdown...
</section>

<section name="Design">
...
</section>

<section name="Acceptance Criteria">
...
</section>

<section name="Notes">
...including your earlier replies, e.g. CNG 2026-11-01 (re: (2) "..."): ...
</section>

<section name="Comments">
...all comments' text, separated by blank lines...
</section>
```

Only the title and these five text sections are sent. The issue ID, status, priority, type,
assignee, labels, dates and dependencies are not.

### The system prompt

`<who>` is replaced with your initials from the review settings (e.g. `CNG`).

```text
You prepare a review brief for <who>, the human owner of an issue tracker. The issues are
written by AI coding agents in dense shorthand: file paths, commit hashes, branch names, test
counts, issue ids. <who> reads your brief instead of the raw text, so write for a busy person:
plain language, short sentences, and no paths, hashes, ids or test counts unless one matters
to a decision.

summary: two to four sentences on what the issue is about and where it stands now.

points: up to five short bullets with the facts that matter most (what was done, what is left,
risks). Leave it empty when the summary already covers them.

items: every question, decision or choice, approval or sign-off, and request for direction the
issue puts to <who>, whether or not <who> has answered it yet. Include findings or follow-ups
that need <who> to decide what happens next even when they are not phrased as questions. Not
items: work the agents will do themselves, and rhetorical questions. Keep the items in
document order; return none only when the issue puts nothing to <who> at all.

<who>'s answers appear as lines starting "<who> YYYY-MM-DD", "<who> decision" or "From <who>",
often with (re: "...") naming the question they answer. Mark an item answered only when such a
line clearly answers that specific item; answering a related or earlier question does not
count. When in doubt, it is open.

For each item:
- title: the question as one plain sentence ending in "?".
- context: one to three plain sentences with the background needed to answer it.
- options: the concrete choices, from the text or the obvious ones (for example, go ahead or
  hold off), each with a short label and a one-sentence consequence. Empty for an open
  question.
- recommended: the label of the option the text recommends, or "" when it recommends none.
- quote: a short excerpt copied exactly from the text (one sentence or clause) where the item
  is raised.
- section: the section that quote is in.
- status: "answered" when one of <who>'s lines answers it, otherwise "open".
- answered_by: for an answered item, that line of <who>'s, copied exactly; "" when open.
- label: the item's own number or letter where the text raises it, copied exactly ("(3)",
  "2.", "b)", "Q4"), so <who>'s answer can name it; "" when it has none. When one numbered
  line or paragraph holds several questions, give each its own number.
```

The prompt is about 600 tokens. It never changes between requests (apart from your initials),
so the cost of each brief is dominated by the issue's length and by what Claude writes.

---

## What comes back

### The schema

The request's `output_config.format` carries this JSON Schema. With structured outputs the API
guarantees Claude's answer is valid JSON that matches it: every field present, nothing extra,
`kind` and `section` limited to the listed values.

```json
{
  "type": "object",
  "properties": {
    "summary": { "type": "string" },
    "points":  { "type": "array", "items": { "type": "string" } },
    "items": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "kind":        { "type": "string", "enum": ["question", "decision"] },
          "title":       { "type": "string" },
          "context":     { "type": "string" },
          "options": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "label":  { "type": "string" },
                "detail": { "type": "string" }
              },
              "required": ["label", "detail"],
              "additionalProperties": false
            }
          },
          "recommended": { "type": "string" },
          "quote":       { "type": "string" },
          "section":     { "type": "string",
                           "enum": ["Description", "Design", "Acceptance Criteria", "Notes", "Comments"] },
          "label":       { "type": "string" },
          "status":      { "type": "string", "enum": ["open", "answered"] },
          "answered_by": { "type": "string" }
        },
        "required": ["kind", "title", "context", "options", "recommended", "quote", "section", "label",
                     "status", "answered_by"],
        "additionalProperties": false
      }
    }
  },
  "required": ["summary", "points", "items"],
  "additionalProperties": false
}
```

### An example answer

```json
{
  "summary": "The workspace cache now survives restarts and the tests pass. One choice is left before it ships: when to save the cache to disk.",
  "points": [
    "Warm start reads the saved cache before the first query.",
    "Saving on every change slowed bulk imports in review."
  ],
  "items": [
    {
      "kind": "decision",
      "title": "When should the cache be saved to disk?",
      "context": "Saving on every change made bulk imports noticeably slower. The reviewer suggested two alternatives.",
      "options": [
        { "label": "Debounce writes", "detail": "Fast imports, with at most a second of changes at risk in a crash." },
        { "label": "Save only on quit", "detail": "Fastest, but a crash loses the whole session's changes." }
      ],
      "recommended": "Debounce writes",
      "quote": "either debounce writes or persist only on quit (data loss risk on crash)",
      "section": "Notes",
      "label": "(1)",
      "status": "open",
      "answered_by": ""
    },
    {
      "kind": "question",
      "title": "Should the cache be shared between windows?",
      "context": "Two windows on the same repository could share one cache or keep their own.",
      "options": [
        { "label": "Share it", "detail": "Less memory; both windows see the same data." },
        { "label": "One per window", "detail": "Simpler, but uses more memory." }
      ],
      "recommended": "Share it",
      "quote": "(2) share the cache across windows on the same repo?",
      "section": "Description",
      "label": "(2)",
      "status": "answered",
      "answered_by": "CNG 2026-11-01 (re: (2) \"Should the cache be shared…\"): Share it."
    }
  ]
}
```

### How each field is used

| Field | Used for |
|---|---|
| `summary`, `points` | The text at the top of the Brief. |
| `kind` | The item's icon (question mark or branching arrow). |
| `title` | The question shown on the card, and the text named in your reply's `(re: ...)`. |
| `context` | The grey background text under the question. |
| `options` | The choices you can pick; the chosen `label` becomes the start of your answer. |
| `recommended` | Marks one option **Recommended** (ignored unless it matches an option's `label` exactly). |
| `quote` | Highlights where the item is raised in the issue text (orange bar), and **Show source**. Matching ignores case, `*`, `_`, backticks and extra spaces. |
| `section` | Which section's text to highlight, and the label under **Show source**. |
| `label` | Shown before the question, and kept in your reply: `(re: (1) "When should…?")`. If Claude leaves it empty but the quote starts with a label, the app takes it from there. |
| `status`, `answered_by` | Open items are shown to answer. Answered items go in a collapsed **Answered (n)** list with the line Claude took as the answer, and aren't highlighted in the text. |

Your answer is recorded as:

```text
CNG 2026-11-02 (re: (1) "When should the cache be saved to disk?"): Debounce writes. Keep the second of risk.
```

An item counts as answered when Claude marks it `"status": "answered"`, or when the Notes
contain a reply whose `(re: ...)` starts with the same label and opening words of the question.
Answered items are not dropped: Claude returns every item it finds, so a brief that says
nothing is waiting also shows what it considered settled, and by which line. That makes a
wrong "everything is answered" judgement visible, and the prompt asks Claude to count an
item as answered only when a line clearly answers that specific item.

---

## Parameters

All are in the gear popover on the review bar. Changes apply to new briefs; press ↺ to remake
an existing one.

| Setting | Default | Choices | Effect |
|---|---|---|---|
| **Model** | `claude-haiku-5-5` | any model your key can use (the menu lists them from the Models API) | Which Claude writes the brief. A newer Haiku needs no app update. |
| **Effort** | `low` | `low`, `medium`, `high`, `xhigh`, `max` | How much Claude thinks before writing. Lower is faster and cheaper; higher may judge tangled issues better. Measured: about 10 s at `medium` vs about 4 s at `low` on similar issues. |
| **Output limit** (`max_tokens`) | 32,000 | 8K, 16K, 32K, 64K, 128K | The most Claude may write for one brief, **thinking included**. If it is reached, the brief fails as cut off. You pay only for what is written, not for the limit. |
| **Sign replies as** | your initials | any text | Used in the prompt (to recognise your earlier answers) and at the start of every reply. |

Fixed in the code:

| Parameter | Value | Why |
|---|---|---|
| Request timeout | 600 s | Long briefs at high limits can take minutes, and nothing arrives until the end. |
| Streaming | off | Simpler; the brief is shown when complete. |
| Prompt caching | not used | The system prompt (~600 tokens) is below the size that caching helps. |
| Thinking display | API default (omitted) | Claude's thinking is billed but not shown; only the final JSON is read. |

### Tokens and cost

Measured briefs used about 1,400–5,500 input tokens and 300–1,800 output tokens (output
includes thinking). At Claude Haiku 5.5 prices ($0.10 per million input tokens and $0.50 per
million output tokens, for prompts up to 100K tokens) a typical brief costs about a tenth of
a cent; a long one with many items, a few tenths of a cent. Each stopwatch line shows the
exact token counts for that brief.

Speed is mostly output: Haiku writes roughly 150–250 tokens a second, so the time to a brief is
close to *output tokens ÷ that rate*. Lower effort (less thinking) and fewer items are what make
it faster.

---

## Saved requests and responses

Every brief, and every failed one, is saved as a JSON file in
`~/Library/Logs/BeadsTracker/briefs/`, named `<yyyyMMdd-HHmmss>-<issue id>.json`; the newest
200 are kept. **Request & response**, next to the stopwatch line (or under an error), shows
the file in the Finder. Each file holds:

| Key | Contents |
|---|---|
| `issue_id`, `saved_at` | Which issue, and when. |
| `timing` | The same figures as the `[brief]` log line (model, effort, limit, times, tokens, request ID). |
| `request` | The exact request body sent: model, `max_tokens`, system prompt, `output_config` with the schema, and the user message with the issue text. |
| `response` | The API's raw response (content blocks, `stop_reason`, `usage`), plus `brief`: Claude's answer parsed out of its text block, for reading. For an API error, the error body. |
| `error` | The message shown in the app, when the brief failed. |

Comparing two files for the same issue is the quickest way to see why one run listed questions
and another didn't: check whether the issue text in `request` differs, and which items
`response.brief.items` marked `answered`, with which `answered_by` line.

---

## Timing and logs

Under each brief, a stopwatch line shows the total time, the API call and the app's own time,
and the token counts. Hover over it for the breakdown:

- **Preparing request** and **Reading the answer**: the app (normally 0 s).
- **Connecting**: DNS, TCP and TLS, only when a new connection is opened.
- **Waiting for Claude**: from sending the request to the first byte back. Because the answer
  isn't streamed, this is the whole of Claude's thinking and writing.
- **Receiving the answer**, **Whole API call**, **Total**.
- **Output rate** (tokens per second) and the API **request ID** (useful when reporting a
  problem to Anthropic).

Each brief, and each failure, is also logged in `~/Library/Logs/BeadsTracker/beads-tracker.log`:

```text
2026-11-01T13:13:50Z [brief] bb-saas-cmvu model=claude-haiku-5-5 effort=medium max_tokens=32000 total=11025ms prepare=0ms connect=99ms wait=10858ms download=0ms request=10966ms parse=0ms in=5549 out=1810 request-id=req_...
```

```bash
tail -f ~/Library/Logs/BeadsTracker/beads-tracker.log | grep '\[brief\]'
```

---

## When it goes wrong

| Message | Cause | What to do |
|---|---|---|
| *No Anthropic API key saved* | No key in the Keychain. | Add one in the gear popover. |
| *Claude API: …* | The API returned an error (bad key, unknown model, rate limit, overloaded). The API's own message follows. | Check the key and model; retry with ↺. |
| *Claude's answer was cut off at the N-token output limit…* | Claude reached `max_tokens` (stop reason `max_tokens`), usually an issue with many items or high effort. | Raise **Output limit** or lower **Effort**, then ↺. |
| *Claude declined to review this issue.* | A safety classifier stopped the request (stop reason `refusal`). Haiku has no automatic fallback model. | Use the built-in rules for that issue, or try another model. |
| *Claude returned an unreadable answer.* | The answer had no text block or wasn't JSON (should not happen with structured outputs). | Retry with ↺; report it with the request ID if it repeats. |
| Request times out | No answer within 600 s. | Lower the effort; check the network. |

---

## Privacy

Using Claude sends the issue's title and its Description, Design, Acceptance Criteria, Notes
and Comments to the Anthropic API under your API key and your organisation's data settings.
Nothing else about the workspace is sent, and nothing is sent at all while Needs you uses the
built-in rules or is off. The key is stored in the macOS Keychain (service
`BeadsTracker.anthropic-api-key`) and sent only to `api.anthropic.com`.

---

## The built-in rules, for comparison

Without Claude, **Needs you** uses local rules in `heuristicReviewItems` (no network, instant):

- sentences containing a `?` (ignoring inline code and URLs);
- phrases asking for a decision, such as "decide whether", "decision needed", "for CNG",
  "CNG to decide", "open questions", "TBD";
- the list items under a lead-in such as "Open questions:" or a heading like "## Decisions";
- skipping code blocks and your own lines ("CNG 2026-…", "From CNG …").

They find the text but don't rewrite it: no summary, no plain question, no options. You reply
to each item with a free-text answer.
