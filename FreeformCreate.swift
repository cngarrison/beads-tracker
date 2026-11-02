// FreeformCreate.swift
// Freeform create: Claude Haiku turns a plain-words description into a proposed new issue
// (title, type, priority, links, possible duplicates). The proposal only fills in the Create
// form; nothing is created until the user clicks Create.

import Foundation

/// An existing issue Claude thinks may already cover the request.
struct DuplicateCandidate: Identifiable, Hashable {
    let id: String
    let title: String
    let status: String
    let reason: String
}

/// Claude's proposal, already checked: every issue id in it is one the app sent.
struct IssueProposal {
    var fields: IssueFormFields
    var duplicates: [DuplicateCandidate]
    /// Ids Claude returned that were not in the list sent, so were left out.
    var droppedIDs: [String]
}

enum FreeformCreate {
    /// Dependency types Claude may propose, as `bd create --deps` spells them.
    static let linkTypes = ["blocked-by", "blocks", "related", "discovered-from"]

    private static let openLimit = 300
    private static let closedMatchLimit = 40
    private static let recentClosedLimit = 15

    private static let stopWords: Set<String> = [
        "this", "that", "with", "from", "have", "when", "then", "than", "they", "them", "there",
        "what", "which", "will", "would", "should", "could", "about", "into", "also", "just",
        "like", "some", "more", "make", "need", "needs", "issue", "issues", "pretty", "really",
    ]

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count >= 4 && !stopWords.contains($0) })
    }

    /// The existing issues Claude may refer to: any the request names by id, every issue not
    /// closed, closed issues whose words overlap the request (so a follow-up can link to the
    /// work it follows), and the most recently changed closed ones.
    static func candidates(from issues: [BeadsIssue], text: String) -> [BeadsIssue] {
        let lowered = text.lowercased()
        let wanted = words(text)
        let named = issues.filter {
            lowered.range(of: #"(?<![\w.-])"# + NSRegularExpression.escapedPattern(for: $0.id.lowercased()) + #"(?![\w-]|\.\w)"#,
                          options: .regularExpression) != nil
        }
        let open = issues.filter { $0.status != "closed" }.prefix(openLimit)
        let closed = issues.filter { $0.status == "closed" }
        let matching = closed
            .map { issue -> (BeadsIssue, Int) in
                let score = 2 * words(issue.title).intersection(wanted).count
                    + words(String((issue.description ?? "").prefix(600))).intersection(wanted).count
                return (issue, score)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(closedMatchLimit)
            .map(\.0)
        let recent = closed.sorted { $0.updatedAt > $1.updatedAt }.prefix(recentClosedLimit)

        var seen = Set<String>()
        return (named + Array(open) + matching + Array(recent)).filter { seen.insert($0.id).inserted }
    }

    /// One line per candidate: id, status, type, priority, parent, title and the start of the description.
    static func candidateLine(_ i: BeadsIssue) -> String {
        let snippet = (i.description ?? "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        var line = "\(i.id) | \(i.status) | \(i.issueType ?? "task") | P\(i.priority)"
        if let p = i.parentID { line += " | parent \(p)" }
        line += " | \(i.title)"
        if !snippet.isEmpty { line += " | " + String(snippet.prefix(100)) }
        return line
    }

    /// The request as it is kept in the new issue's Notes, so nothing typed is lost.
    /// Not shaped like a reply line ("CNG 2026-11-02: ..."), so the Needs-you review does not
    /// take it as an answer.
    static func originalRequestNote(_ text: String, initials: String, date: Date = Date()) -> String {
        let quoted = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        return "Original request from \(initials), \(replyDateStamp(date)):\n\(quoted)"
    }

    private static func systemPrompt(initials who: String) -> String {
        """
        You turn a request from \(who), the owner of a bd (beads) issue tracker, into one new \
        issue. \(who) writes quickly and informally; the issue should read clearly to the AI \
        coding agents and people who pick it up later. \(who) reviews and edits your proposal \
        before anything is created.

        The existing issues are listed one per line as: id | status | type | priority | parent \
        (if any) | title | start of description. Refer to existing issues only by ids from that \
        list, copied exactly. Never make up an id.

        - title: one line, under about 80 characters, saying what the issue is.
        - description: why the issue exists and what needs to be done, in clear sentences. Keep \
        every fact \(who) gives, in \(who)'s terms. Do not add causes, file names, steps or \
        details the request does not give.
        - type: "bug" for something broken, "feature" for a new or changed capability, "chore" \
        for upkeep, "epic" only for a group of work the request says will be split up, otherwise \
        "task".
        - priority: "0" critical, "1" high (urgent, blocking, "soon"), "2" normal, "3" low, \
        "4" backlog ("someday", "nice to have"). "2" unless the request says otherwise.
        - labels: only labels the request asks for; otherwise empty.
        - design: the approach, only when the request describes one; otherwise "".
        - acceptance: what done looks like, only when the request says; otherwise "".
        - parent: the id of the existing issue (usually an epic) the request says this belongs \
        under ("part of", "under", "child of"); otherwise "".
        - links: dependencies on existing issues that the request states or clearly implies. \
        "blocked-by": the new issue cannot be done until that one is. "blocks": that issue waits \
        for the new one. "discovered-from": the new issue is a follow-up found while working on \
        that one (often a closed issue). "related": connected, with no ordering. Give each a \
        one-sentence reason. Do not repeat the parent here.
        - duplicates: existing issues, open or closed, that may already cover the same problem \
        or work, each with a one-sentence reason. Empty when none is a close match.
        """
    }

    private static var schema: [String: Any] {
        let linkSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "type":   ["type": "string", "enum": linkTypes],
                "id":     ["type": "string"],
                "reason": ["type": "string"],
            ],
            "required": ["type", "id", "reason"],
            "additionalProperties": false,
        ]
        let duplicateSchema: [String: Any] = [
            "type": "object",
            "properties": ["id": ["type": "string"], "reason": ["type": "string"]],
            "required": ["id", "reason"],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "title":       ["type": "string"],
                "description": ["type": "string"],
                "type":        ["type": "string", "enum": IssueType.allCases.map(\.rawValue)],
                "priority":    ["type": "string", "enum": Priority.allCases.map(\.rawValue)],
                "labels":      ["type": "array", "items": ["type": "string"]],
                "design":      ["type": "string"],
                "acceptance":  ["type": "string"],
                "parent":      ["type": "string"],
                "links":       ["type": "array", "items": linkSchema],
                "duplicates":  ["type": "array", "items": duplicateSchema],
            ],
            "required": ["title", "description", "type", "priority", "labels", "design", "acceptance",
                         "parent", "links", "duplicates"],
            "additionalProperties": false,
        ]
    }

    /// Asks Claude for a proposal and applies it on top of `current` (fields Claude does not
    /// propose, such as assignee and external reference, are kept).
    static func propose(text: String, current: IssueFormFields, candidates: [BeadsIssue], initials: String,
                        model: String, effort: String, maxTokens: Int, apiKey: String) async throws -> IssueProposal {
        let list = candidates.map(candidateLine).joined(separator: "\n")
        let user = "<issues>\n\(list)\n</issues>\n\n<request>\n\(text)\n</request>"
        let (parsed, timing) = try await AnthropicReview.structured(
            recordID: "new-issue", task: "propose an issue", retry: "try again", logCategory: "freeform",
            answerKey: "proposal", system: systemPrompt(initials: initials), user: user, schema: schema,
            model: model, effort: effort, maxTokens: maxTokens, apiKey: apiKey)
        BTLog.log("proposal \(timing.logLine) candidates=\(candidates.count)", category: "freeform")

        func str(_ any: Any?) -> String { ((any as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let known = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var dropped: [String] = []
        func checked(_ id: String) -> String? {
            guard !id.isEmpty else { return nil }
            if known[id] != nil { return id }
            dropped.append(id)
            return nil
        }

        var f = current
        f.title              = str(parsed["title"])
        f.description        = str(parsed["description"])
        f.issueType          = IssueType(rawValue: str(parsed["type"])) ?? .task
        f.priority           = Priority(rawValue: str(parsed["priority"])) ?? .p2
        f.labels             = (parsed["labels"] as? [String] ?? []).map { str($0) }.filter { !$0.isEmpty }
                                   .joined(separator: ", ")
        f.designNotes        = str(parsed["design"])
        f.acceptanceCriteria = str(parsed["acceptance"])
        f.parent             = checked(str(parsed["parent"])) ?? ""
        var seenLinks = Set<String>()
        f.dependencies = (parsed["links"] as? [[String: Any]] ?? []).compactMap { link -> String? in
            let type = str(link["type"])
            guard linkTypes.contains(type), let id = checked(str(link["id"])), id != f.parent,
                  seenLinks.insert(id).inserted else { return nil }
            return "\(type):\(id)"
        }.joined(separator: ", ")
        f.notes = originalRequestNote(text, initials: initials)
        f.freeformText = text

        let duplicates = (parsed["duplicates"] as? [[String: Any]] ?? []).compactMap { d -> DuplicateCandidate? in
            guard let id = checked(str(d["id"])), let issue = known[id] else { return nil }
            return DuplicateCandidate(id: id, title: issue.title, status: issue.status, reason: str(d["reason"]))
        }
        if !dropped.isEmpty { BTLog.log("dropped unknown ids: \(dropped.joined(separator: ", "))", category: "freeform") }
        return IssueProposal(fields: f, duplicates: duplicates, droppedIDs: dropped)
    }
}
