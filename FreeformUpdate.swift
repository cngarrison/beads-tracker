// FreeformUpdate.swift
// Freeform update: Claude Haiku turns a plain-words request about one issue ("bump to P1, this
// blocks bt-elk, defer it to next week") into a list of single changes. The user ticks the ones
// to make; the app runs each as its own `bd` command and reports how each went.

import SwiftUI

/// One proposed change to an issue, already checked against the issue and the ids sent.
struct UpdateAction: Identifiable {
    enum Kind: String, CaseIterable {
        // Claude may propose these; `note` is always the request itself, added by the app.
        case title, priority, type, status, assignee
        case description, design, acceptance
        case addToDescription = "append_description", addToDesign = "append_design"
        case addToAcceptance = "append_acceptance"
        case addLabel = "add_label", removeLabel = "remove_label"
        case due, deferUntil = "defer", parent, link, unlink, note, close

        /// For the text fields: what the field is called, its `bd update` flag, and whether the
        /// change adds to the end of it (rather than replacing it).
        var textField: (name: String, flag: String, adds: Bool)? {
            switch self {
            case .description:      return ("description", "--description", false)
            case .addToDescription: return ("description", "--description", true)
            case .design:           return ("design", "--design", false)
            case .addToDesign:      return ("design", "--design", true)
            case .acceptance:       return ("acceptance criteria", "--acceptance", false)
            case .addToAcceptance:  return ("acceptance criteria", "--acceptance", true)
            default:                return nil
            }
        }
    }

    let id = UUID()
    let kind: Kind
    /// The new value: a priority digit, status, date (YYYY-MM-DD, or "" to clear), issue id, label,
    /// text for a text field (the whole field, or the part to add), note text, or the close reason.
    let value: String
    /// For `link`: blocked-by, blocks, related or discovered-from.
    var linkType: String = ""
    /// What changes, before → after, for the checklist.
    let summary: String
    /// Claude's one-sentence reason.
    var reason: String = ""
}

struct UpdateProposal {
    var actions: [UpdateAction]
    /// Parts of the request Claude could not turn into a change.
    var unclear: [String]
    /// Proposed changes left out, and why (unknown id, already so, not a valid value).
    var skipped: [String]
}

enum FreeformUpdate {
    static let statuses = ["open", "in_progress", "blocked", "deferred"]
    static let linkTypes = FreeformCreate.linkTypes

    /// Order changes run in: fields, then links, then the note, and closing last.
    private static let runOrder: [UpdateAction.Kind] = [
        .title, .description, .addToDescription, .design, .addToDesign, .acceptance, .addToAcceptance,
        .type, .priority, .status, .assignee, .addLabel, .removeLabel, .due, .deferUntil,
        .parent, .link, .unlink, .note, .close,
    ]

    /// Longest text field sent to Claude in full. A longer one is cut short, so it can only be
    /// added to, never replaced (the replacement would lose what Claude didn't see).
    private static let fullTextLimit = 4000

    private static func fieldText(of field: String, in d: BeadsIssueDetail) -> String {
        switch field {
        case "description": return d.description ?? ""
        case "design":      return d.design ?? ""
        default:            return d.acceptanceCriteria ?? ""
        }
    }

    /// Text added to the end of a field, on a new line.
    private static func appended(_ addition: String, to current: String) -> String {
        current.isEmpty ? addition : current + "\n" + addition
    }

    private static func snippet(_ s: String, _ limit: Int = 160) -> String {
        let flat = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "\u{2026}" : flat
    }

    private static func day(_ iso: String?) -> String { iso.map { String($0.prefix(10)) } ?? "" }

    private static func statusLabel(_ s: String) -> String { s.replacingOccurrences(of: "_", with: " ") }

    private static func parentID(_ d: BeadsIssueDetail) -> String? {
        d.dependencies?.first(where: { $0.dependencyType == "parent-child" })?.id
    }

    /// The issue's links other than parent/child: (other id, type, true when this issue depends on it).
    private static func links(_ d: BeadsIssueDetail) -> [(id: String, type: String, outgoing: Bool)] {
        let out = (d.dependencies ?? []).filter { $0.dependencyType != "parent-child" }
            .map { (id: $0.id, type: $0.dependencyType ?? "blocks", outgoing: true) }
        let inc = (d.dependents ?? []).filter { $0.dependencyType != "parent-child" }
            .map { (id: $0.id, type: $0.dependencyType ?? "blocks", outgoing: false) }
        return out + inc
    }

    /// The issue as Claude sees it: its current fields and links, its text fields (each in full
    /// up to `fullTextLimit`) and the end of its notes.
    private static func currentState(_ d: BeadsIssueDetail, titles: [String: String]) -> String {
        func named(_ id: String) -> String { titles[id].map { "\(id) \"\($0)\"" } ?? id }
        var lines = [
            "id: \(d.id)",
            "title: \(d.title)",
            "status: \(d.status)",
            "type: \(d.issueType ?? "task")",
            "priority: \(d.priority)",
            "assignee: \(d.assignee ?? "none")",
            "labels: \((d.labels ?? []).isEmpty ? "none" : d.labels!.joined(separator: ", "))",
            "due: \(d.due == nil ? "none" : day(d.due))",
            "deferred until: \(d.deferUntil == nil ? "none" : day(d.deferUntil))",
            "parent: \(parentID(d).map(named) ?? "none")",
        ]
        for l in links(d) {
            lines.append(l.outgoing ? "link: this issue \(l.type) \(named(l.id))"
                                    : "link: \(named(l.id)) \(l.type) this issue")
        }
        for field in ["description", "design", "acceptance criteria"] {
            let t = fieldText(of: field, in: d)
            var shown: String = t
            if t.isEmpty {
                shown = "(empty)"
            } else if t.count > fullTextLimit {
                shown = String(t.prefix(fullTextLimit)) + "\n[cut short here; add to it, don't replace it]"
            }
            lines.append("<\(field)>\n\(shown)\n</\(field)>")
        }
        if let notes = d.notes, !notes.isEmpty { lines.append("<notes (end)>\n\(notes.suffix(1500))\n</notes (end)>") }
        return lines.joined(separator: "\n")
    }

    private static func systemPrompt(initials who: String, today: String) -> String {
        """
        \(who), the owner of a bd (beads) issue tracker, describes changes to one issue in plain \
        words. Turn the request into a list of single changes. \(who) reviews the list and \
        chooses which to make; the request itself is always kept in the issue's Notes, so do \
        not repeat it as a change. Today is \(today).

        Each change has a kind, a value, a link_type ("" unless kind is link) and a one-sentence \
        reason. Kinds and values:
        - title: the new title.
        - append_description / append_design / append_acceptance: text to add at the end of the \
        issue's description, design or acceptance criteria, such as an extra criterion or a new \
        paragraph. Use these whenever the request adds to a field. Match the field's style: if \
        it is a list, add list items in the same form.
        - description / design / acceptance: the complete new text, replacing the whole field. \
        Only when the request asks to rewrite or replace that field, never for a field marked \
        as cut short.
        - priority: "0" critical, "1" high, "2" normal, "3" low, "4" backlog.
        - type: "task", "bug", "feature", "epic" or "chore".
        - status: "open", "in_progress", "blocked" or "deferred". Use close, not status, to close.
        - close: close the issue; the value is a short reason, or "".
        - assignee: the person to assign, as the request names them, or "" to unassign.
        - add_label / remove_label: one label per change.
        - due / defer: a date as YYYY-MM-DD, worked out from today for relative dates ("next \
        week" is next Monday), or "" to clear. defer hides the issue from ready work until then.
        - parent: the id of the issue this one should sit under, or "" to remove the parent.
        - link: the id of another issue, with link_type "blocked-by" (this issue cannot be done \
        until that one is), "blocks" (that issue waits for this one), "related", or \
        "discovered-from" (this issue was found while working on that one).
        - unlink: the id of a linked issue whose link should be removed.

        Refer to other issues only by ids from the <issues> list (id | status | type | priority \
        | parent | title | start of description), copied exactly. Never make up an id. Propose \
        only changes the request asks for or clearly implies, and none that leave a value as it \
        is. Background in the request (reasons, timing, context) is kept by the Notes line, so \
        leave it out. Put in unclear only changes the request asks for that none of these kinds \
        can make, in a few words each.
        """
    }

    private static var schema: [String: Any] {
        let actionSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "kind":      ["type": "string", "enum": UpdateAction.Kind.allCases.filter { $0 != .note }.map(\.rawValue)],
                "value":     ["type": "string"],
                "link_type": ["type": "string", "enum": [""] + linkTypes],
                "reason":    ["type": "string"],
            ],
            "required": ["kind", "value", "link_type", "reason"],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "actions": ["type": "array", "items": actionSchema],
                "unclear": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["actions", "unclear"],
            "additionalProperties": false,
        ]
    }

    /// Asks Claude for the changes, then checks each one against the issue: ids must be in
    /// `candidates`, values must be valid, and changes that would leave things as they are are
    /// skipped. The request itself is always added as a note.
    static func propose(text: String, detail d: BeadsIssueDetail, candidates: [BeadsIssue], initials: String,
                        model: String, effort: String, maxTokens: Int, apiKey: String) async throws -> UpdateProposal {
        let others = candidates.filter { $0.id != d.id }
        var titles = Dictionary(others.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        for dep in (d.dependencies ?? []) + (d.dependents ?? []) where titles[dep.id] == nil { titles[dep.id] = dep.title }
        let today = todayLine()
        let list = others.map(FreeformCreate.candidateLine).joined(separator: "\n")
        let user = "<issue>\n\(currentState(d, titles: titles))\n</issue>\n\n<issues>\n\(list)\n</issues>\n\n"
            + "<request>\n\(text)\n</request>"
        let (parsed, timing) = try await AnthropicReview.structured(
            recordID: d.id + "-update", task: "propose changes", retry: "try again", logCategory: "freeform",
            answerKey: "proposal", system: systemPrompt(initials: initials, today: today), user: user,
            schema: schema, model: model, effort: effort, maxTokens: maxTokens, apiKey: apiKey)
        BTLog.log("\(d.id) update proposal \(timing.logLine) candidates=\(others.count)", category: "freeform")

        let (checked, skipped) = check(parsed["actions"] as? [[String: Any]] ?? [], detail: d, titles: titles)
        let note = formatReply(text, ref: nil, initials: initials)
        let actions = ordered(checked + [UpdateAction(kind: .note, value: note, summary: "Append to Notes: \(note)")])
        let unclear = (parsed["unclear"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !skipped.isEmpty { BTLog.log("\(d.id) skipped: \(skipped.joined(separator: "; "))", category: "freeform") }
        return UpdateProposal(actions: actions, unclear: unclear, skipped: skipped)
    }

    /// Today with its weekday ("Monday 2026-11-02"), so Claude can work out relative dates.
    static func todayLine(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE yyyy-MM-dd"
        return f.string(from: date)
    }

    /// The changes in the order they run: fields, then links, then the note, and closing last.
    static func ordered(_ actions: [UpdateAction]) -> [UpdateAction] {
        actions.sorted { runOrder.firstIndex(of: $0.kind)! < runOrder.firstIndex(of: $1.kind)! }
    }

    /// Checks proposed changes (`kind`, `value`, `link_type`, `reason`) against the issue as it is
    /// now: ids must be in `titles` (the issues Claude was shown, plus the issue's own links),
    /// values must be ones the app sets, and changes that would leave things as they are are
    /// skipped, with why.
    static func check(_ raws: [[String: Any]], detail d: BeadsIssueDetail, titles: [String: String])
        -> (actions: [UpdateAction], skipped: [String]) {
        func str(_ any: Any?) -> String { ((any as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func named(_ id: String) -> String { titles[id].map { "\(id) \u{201C}\($0)\u{201D}" } ?? id }
        let known = Set(titles.keys)
        let labels = Set(d.labels ?? [])
        let currentParent = parentID(d) ?? ""
        let currentLinks = links(d)
        var skipped: [String] = []
        var seen = Set<String>()

        var actions: [UpdateAction] = []
        for raw in raws {
            guard let kind = UpdateAction.Kind(rawValue: str(raw["kind"])), kind != .note else { continue }
            let v = str(raw["value"])
            let linkType = str(raw["link_type"])
            let reason = str(raw["reason"])
            func skip(_ why: String) { skipped.append(why) }
            func add(_ summary: String, linkType: String = "") {
                guard seen.insert("\(kind.rawValue):\(v):\(linkType)").inserted else { return }
                actions.append(UpdateAction(kind: kind, value: v, linkType: linkType, summary: summary, reason: reason))
            }
            let isDate = v.isEmpty || v.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
            switch kind {
            case .title:
                if v.isEmpty || v == d.title { skip("Title unchanged") } else { add("Title: \u{201C}\(d.title)\u{201D} \u{2192} \u{201C}\(v)\u{201D}") }
            case .priority:
                if Priority(rawValue: v) == nil { skip("Priority \u{201C}\(v)\u{201D} is not 0\u{2013}4") }
                else if v == String(d.priority) { skip("Priority is already P\(v)") }
                else { add("Priority: P\(d.priority) \u{2192} P\(v)") }
            case .type:
                let current = d.issueType ?? "task"
                if IssueType(rawValue: v) == nil { skip("Type \u{201C}\(v)\u{201D} is not one the app sets") }
                else if v == current { skip("Type is already \(v)") }
                else { add("Type: \(current) \u{2192} \(v)") }
            case .status:
                if !statuses.contains(v) { skip("Status \u{201C}\(v)\u{201D} is not one the app sets") }
                else if v == d.status { skip("Status is already \(statusLabel(v))") }
                else { add("Status: \(statusLabel(d.status)) \u{2192} \(statusLabel(v))") }
            case .close:
                if d.status == "closed" { skip("Already closed") }
                else { add(v.isEmpty ? "Close the issue" : "Close the issue: \(v)") }
            case .assignee:
                let current = d.assignee ?? ""
                if v == current { skip(v.isEmpty ? "Already unassigned" : "Already assigned to \(v)") }
                else { add("Assignee: \(current.isEmpty ? "none" : current) \u{2192} \(v.isEmpty ? "none" : v)") }
            case .description, .design, .acceptance:
                let name = kind.textField!.name
                let current = fieldText(of: name, in: d)
                if v.isEmpty { skip("Won\u{2019}t empty the \(name)") }
                else if current.count > fullTextLimit { skip("The \(name) is too long to replace safely; ask to add to it instead") }
                else if v == current { skip("The \(name) is already that text") }
                else if current.isEmpty { add("Set \(name): \u{201C}\(snippet(v, 400))\u{201D}") }
                else { add("Replace \(name) \u{201C}\(snippet(current, 80))\u{201D} with \u{201C}\(snippet(v, 400))\u{201D}") }
            case .addToDescription, .addToDesign, .addToAcceptance:
                let name = kind.textField!.name
                if v.isEmpty { skip("Nothing to add to the \(name)") }
                else if let i = actions.firstIndex(where: { $0.kind == kind }) {
                    // Two additions to one field become one, so the second doesn't undo the first.
                    let both = actions[i].value + "\n" + v
                    actions[i] = UpdateAction(kind: kind, value: both, summary: "Add to \(name): \u{201C}\(snippet(both, 400))\u{201D}",
                                              reason: actions[i].reason)
                }
                else { add("Add to \(name): \u{201C}\(snippet(v, 400))\u{201D}") }
            case .addLabel:
                if v.isEmpty || v.contains(",") { skip("Label \u{201C}\(v)\u{201D} is not a single label") }
                else if labels.contains(v) { skip("Already labelled \(v)") }
                else { add("Add label: \(v)") }
            case .removeLabel:
                if !labels.contains(v) { skip("Not labelled \u{201C}\(v)\u{201D}") } else { add("Remove label: \(v)") }
            case .due, .deferUntil:
                let name = kind == .due ? "Due" : "Defer until"
                let current = day(kind == .due ? d.due : d.deferUntil)
                if !isDate { skip("\(name) \u{201C}\(v)\u{201D} is not a date") }
                else if v == current { skip("\(name) is already \(v.isEmpty ? "unset" : v)") }
                else { add("\(name): \(current.isEmpty ? "none" : current) \u{2192} \(v.isEmpty ? "none" : v)") }
            case .parent:
                if !v.isEmpty && !known.contains(v) { skip("Parent \(v) is not in the list sent to Claude") }
                else if v == d.id { skip("An issue can't be its own parent") }
                else if v == currentParent { skip(v.isEmpty ? "Has no parent already" : "Parent is already \(v)") }
                else {
                    add("Parent: \(currentParent.isEmpty ? "none" : named(currentParent)) \u{2192} \(v.isEmpty ? "none" : named(v))")
                }
            case .link:
                if !known.contains(v) || v == d.id { skip("Link to \(v.isEmpty ? "(no id)" : v): not in the list sent to Claude") }
                else if !linkTypes.contains(linkType) { skip("Link to \(v): no link type") }
                else if currentLinks.contains(where: { $0.id == v }) { skip("Already linked to \(v)") }
                else {
                    let summary: String
                    switch linkType {
                    case "blocked-by": summary = "Depends on \(named(v)) (it blocks this)"
                    case "blocks":     summary = "\(named(v)) depends on this (this blocks it)"
                    case "related":    summary = "Related to \(named(v))"
                    default:           summary = "Found while working on \(named(v)) (discovered-from)"
                    }
                    add(summary, linkType: linkType)
                }
            case .unlink:
                if !currentLinks.contains(where: { $0.id == v }) { skip("Not linked to \(v)") }
                else { add("Remove the link with \(named(v))") }
            case .note:
                break
            }
        }

        return (actions, skipped)
    }

    /// Makes one change with its own `bd` command. Blocking; run off the main thread.
    static func apply(_ a: UpdateAction, to d: BeadsIssueDetail, workingDirectory dir: String) throws {
        let id = d.id
        switch a.kind {
        case .title:       try BeadsRunner.update(id: id, flags: ["--title", a.value], workingDirectory: dir)
        case .description, .design, .acceptance, .addToDescription, .addToDesign, .addToAcceptance:
            let field = a.kind.textField!
            let value = field.adds ? appended(a.value, to: fieldText(of: field.name, in: d)) : a.value
            try BeadsRunner.update(id: id, flags: [field.flag, value], workingDirectory: dir)
        case .priority:    try BeadsRunner.update(id: id, flags: ["--priority", a.value], workingDirectory: dir)
        case .type:        try BeadsRunner.update(id: id, flags: ["--type", a.value], workingDirectory: dir)
        case .status:      try BeadsRunner.setStatus(id: id, status: a.value, workingDirectory: dir)
        case .assignee:    try BeadsRunner.update(id: id, flags: ["--assignee", a.value], workingDirectory: dir)
        case .addLabel:    try BeadsRunner.update(id: id, flags: ["--add-label", a.value], workingDirectory: dir)
        case .removeLabel: try BeadsRunner.update(id: id, flags: ["--remove-label", a.value], workingDirectory: dir)
        case .due:         try BeadsRunner.setDue(id: id, due: a.value, workingDirectory: dir)
        case .deferUntil:  try BeadsRunner.setDefer(id: id, deferUntil: a.value, workingDirectory: dir)
        case .parent:      try BeadsRunner.update(id: id, flags: ["--parent", a.value], workingDirectory: dir)
        case .link:
            switch a.linkType {
            case "blocked-by": try BeadsRunner.addDependency(issueID: id, depID: a.value, type: "blocks", workingDirectory: dir)
            case "blocks":     try BeadsRunner.addDependency(issueID: a.value, depID: id, type: "blocks", workingDirectory: dir)
            default:           try BeadsRunner.addDependency(issueID: id, depID: a.value, type: a.linkType, workingDirectory: dir)
            }
        case .unlink:
            // Remove the edge in whichever direction it was stored.
            if links(d).contains(where: { $0.id == a.value && $0.outgoing }) {
                try BeadsRunner.removeDependency(issueID: id, depID: a.value, workingDirectory: dir)
            } else {
                try BeadsRunner.removeDependency(issueID: a.value, depID: id, workingDirectory: dir)
            }
        case .note:
            // A blank line between entries keeps replies readable in the rendered Notes.
            let text = (d.notes ?? "").isEmpty ? a.value : "\n" + a.value
            try BeadsRunner.appendNotes(id: id, text: text, workingDirectory: dir)
        case .close:       try BeadsRunner.close(id: id, reason: a.value, workingDirectory: dir)
        }
    }
}

// MARK: - View

/// The detail card's "Describe changes" panel: a request, then Claude's proposed changes as a
/// checklist, then each change's result.
struct FreeformUpdatePanel: View {
    let detail: BeadsIssueDetail
    let workingDirectory: String
    let initials: String
    let onApplied: () -> Void
    let onClose: () -> Void

    @State private var text = ""
    @State private var proposal: UpdateProposal? = nil
    @State private var selected: Set<UUID> = []
    @State private var succeeded: Set<UUID> = []
    @State private var failures: [UUID: String] = [:]
    @State private var proposeTask: Task<Void, Never>? = nil
    @State private var started: Date? = nil
    @State private var error: String? = nil
    @State private var isApplying = false
    @State private var applied = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Describe changes to \(detail.id)", systemImage: "wand.and.stars")
                .font(.caption).foregroundStyle(.secondary)
            if let proposal {
                review(proposal)
            } else {
                request
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.06)))
        .onDisappear { proposeTask?.cancel() }
    }

    // MARK: Request

    private var request: some View {
        VStack(alignment: .leading, spacing: 6) {
            GrowingTextEditor(text: $text, minHeight: 54)
                .focused($focused)
                .disabled(proposeTask != nil)
            Text("e.g. \u{201C}bump to P1, this blocks bt-elk, defer to next week\u{201D}. Claude proposes the "
                 + "changes for you to tick; your text is added to Notes.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let started, proposeTask != nil {
                    ProgressView().scaleEffect(0.6)
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text("Asking Claude\u{2026} \(Int(context.date.timeIntervalSince(started))) s")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer()
                if proposeTask != nil {
                    Button("Stop") { proposeTask?.cancel() }
                } else {
                    Button("Cancel", action: onClose).keyboardShortcut(.escape, modifiers: [])
                }
                Button("Propose Changes") { propose() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(proposeTask != nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Ask Claude for the changes (\u{2318}\u{21A9})")
            }
            .controlSize(.small)
        }
        .onAppear { focused = true }
    }

    private func propose() {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey = AnthropicKeychain.load() else {
            error = "Add an Anthropic API key in Review settings (the gear on the review bar) to describe changes."
            return
        }
        let issues = WorkspaceStoreRegistry.shared.existing(workingDirectory)?.issues ?? []
        let candidates = FreeformCreate.candidates(from: issues, text: request)
        let d = detail, who = initials
        let model = AnthropicReview.model, effort = AnthropicReview.effort, maxTokens = AnthropicReview.maxTokens
        error = nil
        started = Date()
        proposeTask = Task { @MainActor in
            defer { proposeTask = nil }
            do {
                let p = try await FreeformUpdate.propose(text: request, detail: d, candidates: candidates, initials: who,
                                                         model: model, effort: effort, maxTokens: maxTokens, apiKey: apiKey)
                guard !Task.isCancelled else { return }
                proposal = p
                selected = Set(p.actions.map(\.id))
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: Review

    private func review(_ p: UpdateProposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(p.actions) { a in actionRow(a) }
            if !p.unclear.isEmpty {
                Label("Not turned into a change: " + p.unclear.joined(separator: "; "), systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !p.skipped.isEmpty {
                Text("Left out: " + p.skipped.joined(separator: "; "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if applied {
                    let failed = failures.count
                    Text(failed == 0 ? "Made \(succeeded.count) change\(succeeded.count == 1 ? "" : "s")."
                                     : "\(failed) of \(failed + succeeded.count) changes failed.")
                        .font(.caption).foregroundStyle(failed == 0 ? Color.secondary : Color.red)
                } else if isApplying {
                    ProgressView().scaleEffect(0.6)
                    Text("Applying\u{2026}").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if applied {
                    Button("Done", action: onClose)
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Edit Request") { proposal = nil; error = nil }
                        .disabled(isApplying)
                    Button("Cancel", action: onClose)
                        .keyboardShortcut(.escape, modifiers: [])
                        .disabled(isApplying)
                    let count = p.actions.filter { selected.contains($0.id) }.count
                    Button("Apply \(count) Change\(count == 1 ? "" : "s")") { apply(p) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(isApplying || count == 0)
                        .help("Make the ticked changes, one bd command each (\u{2318}\u{21A9})")
                }
            }
            .controlSize(.small)
        }
    }

    private func actionRow(_ a: UpdateAction) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if succeeded.contains(a.id) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if failures[a.id] != nil {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            } else {
                Toggle("", isOn: Binding(
                    get: { selected.contains(a.id) },
                    set: { if $0 { selected.insert(a.id) } else { selected.remove(a.id) } }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(isApplying || applied)
            }
            VStack(alignment: .leading, spacing: 1) {
                let isLong: Bool = a.kind == .note || a.kind.textField != nil
                Text(a.summary).font(.callout)
                    .lineLimit(isLong ? 4 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure = failures[a.id] {
                    Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else if !a.reason.isEmpty {
                    Text(a.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .opacity(applied && !selected.contains(a.id) ? 0.5 : 1)
    }

    /// Runs the ticked changes one at a time, in order, recording each one's result; a failure
    /// does not stop the rest.
    private func apply(_ p: UpdateProposal) {
        let chosen = p.actions.filter { selected.contains($0.id) }
        let d = detail, dir = workingDirectory
        isApplying = true
        error = nil
        Task { @MainActor in
            for a in chosen {
                do {
                    try await Task.detached { try FreeformUpdate.apply(a, to: d, workingDirectory: dir) }.value
                    succeeded.insert(a.id)
                } catch {
                    failures[a.id] = error.localizedDescription
                }
            }
            isApplying = false
            applied = true
            onApplied()
        }
    }
}
