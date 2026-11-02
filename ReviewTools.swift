// ReviewTools.swift
// Detail-panel review aids: the "Needs you" extraction of questions and decisions (built-in
// rules, or Claude Haiku with the user's API key), quick replies appended to Notes, and the
// review settings popover.

import SwiftUI
import AppKit
import Security

// MARK: - Review items

enum ReviewItemKind: String {
    case question, decision
}

/// A question or decision found in an issue's content. `quote` is the text as written in the
/// bead; the detail card highlights every rendered block that contains it. The other fields
/// come only from Claude's brief: the question rewritten in plain words, its background, and
/// the choices it offers.
struct ReviewItem: Identifiable, Hashable {
    let section: String   // one of `reviewSectionNames`
    let kind: ReviewItemKind
    let quote: String
    var title: String? = nil
    var context: String? = nil
    var options: [ReviewOption] = []
    var recommended: String? = nil   // label of the option the text recommends
    /// The item's own number or letter in the issue, e.g. "(3)", "2.", "b)" or "Q4".
    var label: String? = nil
    /// From Claude's brief: the line that already answers this item, when Claude judged it answered.
    var answeredBy: String? = nil
    var id: String { section + "\u{1F}" + quote }
    /// What a reply's "(re: ...)" names: the plain question when there is one.
    var replyRef: String { title ?? quote }

    /// The question as shown on the card, led by its label when the text doesn't already start with it.
    var displayText: String {
        let text = title ?? plainQuote(quote)
        guard let label, !text.hasPrefix(label) else { return text }
        return "\(label) \(text)"
    }
}

struct ReviewOption: Hashable {
    let label: String
    let detail: String
    /// Updates Claude suggests making to the issue when this option is picked, unchecked: the
    /// card checks them against the issue as it is then (`FreeformUpdate.check`).
    var changes: [SuggestedChange] = []
}

/// One issue update Claude suggests for a brief option, as Claude returned it.
struct SuggestedChange: Hashable {
    let kind: String
    let value: String
    let reason: String

    /// In the form `FreeformUpdate.check` reads.
    var raw: [String: Any] { ["kind": kind, "value": value, "link_type": "", "reason": reason] }
}

/// Claude's plain-language rewrite of an issue for review.
struct ReviewBrief {
    let summary: String
    let points: [String]
    let items: [ReviewItem]
    var timing: BriefTiming? = nil
}

/// Where the time went making one brief, to tell the app, the network and the model apart.
struct BriefTiming {
    let model: String
    let effort: String
    let maxTokens: Int
    var prepare: TimeInterval = 0        // building the request (app)
    var connect: TimeInterval? = nil     // DNS, TCP and TLS, when a new connection was opened
    var waiting: TimeInterval? = nil     // request sent -> first byte back: the model working
    var download: TimeInterval? = nil    // first byte -> last byte
    var request: TimeInterval = 0        // the whole HTTP call as the app saw it
    var parse: TimeInterval = 0          // decoding the answer (app)
    var total: TimeInterval = 0          // Refresh -> brief on screen (set by NeedsYouAI)
    var inputTokens: Int? = nil
    var outputTokens: Int? = nil         // includes the model's thinking
    var requestID: String? = nil
    var recordURL: URL? = nil            // the saved request/response (BriefRecorder)

    /// Time spent in the app itself: everything except the HTTP call.
    var app: TimeInterval { max(0, total - request) }

    var summary: String {
        var parts = ["\(Self.secs(total)) total", "Claude API \(Self.secs(request))", "app \(Self.secs(app))"]
        if let i = inputTokens, let o = outputTokens { parts.append("\(i.formatted()) in / \(o.formatted()) out tokens") }
        return parts.joined(separator: " \u{00B7} ")
    }

    var detail: String {
        var lines = ["Model: \(model), \(effort) effort, \(maxTokens.formatted())-token output limit",
                     "Preparing request: \(Self.secs(prepare))"]
        if let connect { lines.append("Connecting (DNS, TCP, TLS): \(Self.secs(connect))") }
        if let waiting { lines.append("Waiting for Claude (sent to first byte): \(Self.secs(waiting))") }
        if let download { lines.append("Receiving the answer: \(Self.secs(download))") }
        lines.append("Whole API call: \(Self.secs(request))")
        lines.append("Reading the answer: \(Self.secs(parse))")
        lines.append("Total, Refresh to brief: \(Self.secs(total))")
        if let o = outputTokens, let waiting, waiting > 0 {
            lines.append("Output rate: \(Int(Double(o) / waiting)) tokens/s (thinking included)")
        }
        if let requestID { lines.append("Request ID: \(requestID)") }
        return lines.joined(separator: "\n")
    }

    var logLine: String {
        func ms(_ t: TimeInterval?) -> String { t.map { "\(Int($0 * 1000))ms" } ?? "-" }
        return "model=\(model) effort=\(effort) max_tokens=\(maxTokens) total=\(ms(total)) prepare=\(ms(prepare)) connect=\(ms(connect)) "
            + "wait=\(ms(waiting)) download=\(ms(download)) request=\(ms(request)) parse=\(ms(parse)) "
            + "in=\(inputTokens.map(String.init) ?? "-") out=\(outputTokens.map(String.init) ?? "-") "
            + "request-id=\(requestID ?? "-")"
    }

    static func secs(_ t: TimeInterval) -> String { String(format: t < 10 ? "%.1f s" : "%.0f s", t) }
}

/// Collects URLSession's per-request timings (DNS, connect, TLS, server wait, download).
private final class TaskMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var metrics: URLSessionTaskMetrics?
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        self.metrics = metrics
    }
}

let reviewSectionNames = ["Description", "Design", "Acceptance Criteria", "Notes", "Comments"]

/// The searchable sections of an issue, in display order, as (section name, markdown).
func reviewSections(_ d: BeadsIssueDetail) -> [(String, String)] {
    var sections: [(String, String)] = []
    if let v = d.description, !v.isEmpty        { sections.append(("Description", v)) }
    if let v = d.design, !v.isEmpty             { sections.append(("Design", v)) }
    if let v = d.acceptanceCriteria, !v.isEmpty { sections.append(("Acceptance Criteria", v)) }
    if let v = d.notes, !v.isEmpty              { sections.append(("Notes", v)) }
    if let c = d.comments, !c.isEmpty           { sections.append(("Comments", c.map(\.text).joined(separator: "\n\n"))) }
    return sections
}

/// Case-insensitive count of `term` across the rendered sections of an issue (the find bar's total).
func findMatchCount(_ term: String, in d: BeadsIssueDetail) -> Int {
    guard !term.isEmpty else { return 0 }
    var count = 0
    for (_, text) in reviewSections(d) {
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: term, options: .caseInsensitive, range: range) {
            count += 1
            range = found.upperBound..<text.endIndex
        }
    }
    return count
}

// MARK: - Reply identity and formatting

/// Initials used to sign replies ("CNG 2026-11-01: ..."). Falls back to the initials of the
/// macOS account's full name when none are set in the review settings.
func replyInitials(_ stored: String) -> String {
    let trimmed = stored.trimmingCharacters(in: .whitespaces)
    if !trimmed.isEmpty { return trimmed }
    let initials = NSFullUserName().split(separator: " ").compactMap(\.first).map { String($0).uppercased() }.joined()
    return initials.isEmpty ? "Me" : initials
}

func replyDateStamp(_ date: Date = Date()) -> String {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyy-MM-dd"
    return fmt.string(from: date)
}

/// The quote with inline markdown markers and list/heading prefixes removed, for display.
func plainQuote(_ quote: String) -> String {
    var s = quote.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespaces)
}

/// Short reference to a quote, written into the reply so it can be matched back later.
func quoteSnippet(_ quote: String) -> String {
    let plain = plainQuote(quote).replacingOccurrences(of: "\n", with: " ")
    guard plain.count > 60 else { return plain }
    var cut = String(plain.prefix(60))
    if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 30 {
        cut = String(cut[..<space])
    }
    return cut + "\u{2026}"
}

/// The Notes line for a reply: "CNG 2026-11-01 (re: (3) "Which option…"): answer".
/// `ref` is the question or quote replied to (nil for a free note); `label` is the item's own
/// number or letter, kept so the reply can be matched to the question it answers.
func formatReply(_ answer: String, ref: String?, label: String? = nil, initials: String, date: Date = Date()) -> String {
    let head = "\(initials) \(replyDateStamp(date))"
    let body = answer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let ref else { return "\(head): \(body)" }
    return "\(head) (re: \(replyReference(ref, label: label))): \(body)"
}

/// `(3) "Which option…"`, or just the quoted snippet when there is no label.
func replyReference(_ ref: String, label: String?) -> String {
    guard let label, !label.isEmpty else { return "\"\(quoteSnippet(ref))\"" }
    var text = plainQuote(ref)
    if text.hasPrefix(label) { text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespaces) }
    return "\(label) \"\(quoteSnippet(text))\""
}

/// True when the notes already hold a reply that references this item.
func isAnswered(_ item: ReviewItem, notes: String?) -> Bool {
    if item.answeredBy != nil { return true }
    guard let notes, !notes.isEmpty else { return false }
    var key = replyReference(item.replyRef, label: item.label)
    if key.hasSuffix("\u{2026}\"") { key.removeLast(2) }
    if notes.contains("(re: \(key)") { return true }
    // Replies recorded before labels were kept: (re: "snippet…")
    var plain = quoteSnippet(item.replyRef)
    if plain.hasSuffix("\u{2026}") { plain.removeLast() }
    return notes.contains("(re: \"\(plain)")
}

// MARK: - Built-in rules

private let fencePattern = "^\\s*```"
private let listMarkerPattern = #"^\s*(?:[-*+>]\s+|\d+[.)]\s+|#{1,6}\s+)"#
/// A numbered or lettered marker at the start of an item: "(3)", "3.", "3)", "(b)", "b)", "B.", "Q4", "Q4:".
private let itemLabelPattern = try! NSRegularExpression(
    pattern: #"^\s*(?:[-*+>]\s+)?(\(\d{1,3}\)|\d{1,3}[.)]|\([A-Za-z]\)|[A-Za-z][.)]|Q\d{1,3}[.:)]?)\s+"#)

/// The item's own number or letter, from the start of the text, if it has one.
func itemLabel(_ text: String) -> String? {
    let ns = text as NSString
    guard let m = itemLabelPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return ns.substring(with: m.range(at: 1))
}
private let sentenceSplit = try! NSRegularExpression(pattern: #"(?<=[.?!])\s+(?=\S)"#)

private func decisionPatterns(_ who: String) -> [NSRegularExpression] {
    let w = NSRegularExpression.escapedPattern(for: who)
    return [
        #"\bdecisions?\s+(?:for|needed|required|pending|wanted)\b"#,
        #"\b(?:needs?|awaiting|requires?|wants?)\s+(?:a\s+|your\s+|human\s+)?(?:human|decision|approval|sign-?off|input|design|discussion)\b"#,
        #"\bfor\s+"# + w + #"\b"#,
        #"\b"# + w + #"\s+to\s+(?:decide|choose|confirm|approve|review|answer)\b"#,
        #"\b(?:decide|choose|pick)\s+(?:whether|between|which|if|how)\b"#,
        #"^decide\b"#,
        #"\bopen\s+questions?\b"#,
        #"\bTBD\b"#,
        #"\bto\s+be\s+decided\b"#,
        #"\bneeds\s+you\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
}

/// Detection ignores inline code and URLs, whose "?" is not a question.
private func codeAndURLsRemoved(_ s: String) -> String {
    s.replacingOccurrences(of: "`[^`]*`", with: "", options: .regularExpression)
     .replacingOccurrences(of: #"\S+://\S+"#, with: "", options: .regularExpression)
}

private func sentences(of line: String) -> [String] {
    let ns = line as NSString
    var start = 0
    var result: [String] = []
    for m in sentenceSplit.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
        result.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
        start = m.range.location + m.range.length
    }
    result.append(ns.substring(from: start))
    return result
}

private func matchesAny(_ patterns: [NSRegularExpression], _ s: String) -> Bool {
    let range = NSRange(s.startIndex..., in: s)
    return patterns.contains { $0.firstMatch(in: s, range: range) != nil }
}

/// Line-based heuristics: sentences that ask a question, lines that ask for a decision, and the
/// list items under a decision lead-in ("Decisions for CNG:"). Lines that are the user's own
/// replies or input ("CNG 2026-10-31: ...", "From CNG: ...") and code blocks are skipped.
func heuristicReviewItems(_ d: BeadsIssueDetail, initials: String) -> [ReviewItem] {
    let decisions = decisionPatterns(initials)
    let ownLine = try? NSRegularExpression(
        pattern: #"^(?:From\s+)?"# + NSRegularExpression.escapedPattern(for: initials) + #"\b(?!\s+to\b)"#)
    var items: [ReviewItem] = []
    var seen = Set<String>()

    func add(_ section: String, _ kind: ReviewItemKind, _ quote: String, label: String?) {
        let q = quote.trimmingCharacters(in: .whitespaces)
        guard q.count >= 8, seen.insert(section + q).inserted else { return }
        items.append(ReviewItem(section: section, kind: kind, quote: q, label: itemLabel(q) ?? label))
    }

    for (section, text) in reviewSections(d) {
        var inFence = false
        var inLeadIn = false
        for rawLine in text.components(separatedBy: "\n") {
            if rawLine.range(of: fencePattern, options: .regularExpression) != nil { inFence.toggle(); continue }
            if inFence { continue }
            let isListItem = rawLine.range(of: #"^\s*(?:[-*+]\s+|\d+[.)]\s+|\(\d+\)\s*)"#, options: .regularExpression) != nil
            let line = rawLine.replacingOccurrences(of: listMarkerPattern, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }   // a blank line may sit between a lead-in and its list
            if rawLine.hasPrefix("#") {
                inLeadIn = matchesAny(decisions, line)
                continue
            }
            if let ownLine, ownLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                inLeadIn = false
                continue
            }
            let lineLabel = itemLabel(rawLine)
            let probe = codeAndURLsRemoved(line)
            if matchesAny(decisions, probe) {
                // A bare lead-in ("Open questions:") is not an item itself; its list items are.
                inLeadIn = line.hasSuffix(":")
                if !inLeadIn {
                    // Quote just the sentences that ask, unless the ask spans sentences.
                    let asking = sentences(of: line).filter { matchesAny(decisions, codeAndURLsRemoved($0)) }
                    add(section, .decision, asking.isEmpty ? line : asking.joined(separator: " "), label: lineLabel)
                }
                continue
            }
            if inLeadIn && isListItem {
                add(section, probe.contains("?") ? .question : .decision, line, label: lineLabel)
                continue
            }
            inLeadIn = false
            guard probe.contains("?") else { continue }
            let questions = sentences(of: line).filter { codeAndURLsRemoved($0).contains("?") }
            if !questions.isEmpty { add(section, .question, questions.joined(separator: " "), label: lineLabel) }
        }
    }
    return items
}

// MARK: - Claude brief

struct ReviewError: LocalizedError {
    let message: String
    /// The saved request/response for this brief, when one was written.
    var recordURL: URL? = nil
    var errorDescription: String? { message }
}

/// Saves each brief's full request and raw response as JSON, so a surprising brief can be
/// inspected and compared with another run. Files go to ~/Library/Logs/BeadsTracker/briefs/;
/// the newest 200 are kept.
enum BriefRecorder {
    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/BeadsTracker/briefs", isDirectory: true)
    private static let keep = 200

    static func save(issueID: String, request: [String: Any], response: Any?, error: String?,
                     timing: BriefTiming) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            return f.string(from: Date())
        }()
        let safeID = issueID.replacingOccurrences(of: "/", with: "_")
        let url = directory.appendingPathComponent("\(stamp)-\(safeID).json")
        var record: [String: Any] = [
            "issue_id": issueID,
            "saved_at": ISO8601DateFormatter().string(from: Date()),
            "timing": timing.logLine,
            "request": request,
        ]
        if let response { record["response"] = response }
        if let error { record["error"] = error }
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? data.write(to: url)) != nil
        else { return nil }
        prune()
        return url
    }

    private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }),
              files.count > keep else { return }
        for old in files.dropFirst(keep) { try? fm.removeItem(at: old) }
    }
}

enum AnthropicReview {
    static let defaultModel = "claude-haiku-5-5"
    static let defaultEffort = "low"
    /// Effort levels the current models accept; more effort means more thinking, so a slower brief.
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    /// The effort chosen in the review settings ("reviewEffort"), or the default.
    static var effort: String {
        let stored = UserDefaults.standard.string(forKey: "reviewEffort") ?? ""
        return efforts.contains(stored) ? stored : defaultEffort
    }

    /// Output token limit choices. Thinking counts toward the limit as well as the brief itself.
    static let maxTokensChoices = [8_000, 16_000, 32_000, 64_000, 128_000]
    static let defaultMaxTokens = 32_000

    /// The output limit chosen in the review settings ("reviewMaxTokens"), or the default.
    static var maxTokens: Int {
        let stored = UserDefaults.standard.integer(forKey: "reviewMaxTokens")
        return maxTokensChoices.contains(stored) ? stored : defaultMaxTokens
    }

    /// The model chosen in the review settings ("reviewModel"), or the default.
    static var model: String {
        let stored = (UserDefaults.standard.string(forKey: "reviewModel") ?? "").trimmingCharacters(in: .whitespaces)
        return stored.isEmpty ? defaultModel : stored
    }

    private static func request(_ path: String, apiKey: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/" + path)!)
        // A long brief at a high output limit can take minutes; the answer isn't streamed.
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        return req
    }

    /// Sends a request; returns the JSON body, or throws the API's error message.
    private static func send(_ req: URLRequest, delegate: URLSessionTaskDelegate? = nil) async throws -> [String: Any] {
        let (data, status) = try await sendRaw(req, delegate: delegate)
        return try checked(data, status: status)
    }

    private static func sendRaw(_ req: URLRequest, delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: req, delegate: delegate)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// The response body as JSON, or the API's error message as a thrown error.
    private static func checked(_ data: Data, status: Int) throws -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, let json else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            throw ReviewError(message: "Claude API: \(message)")
        }
        return json
    }

    /// IDs of the models the API key can use, newest first (Models API).
    static func models(apiKey: String) async throws -> [String] {
        let json = try await send(request("models?limit=100", apiKey: apiKey))
        return (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    private static func systemPrompt(initials who: String) -> String {
        """
        You prepare a review brief for \(who), the human owner of an issue tracker. The issues \
        are written by AI coding agents in dense shorthand: file paths, commit hashes, branch \
        names, test counts, issue ids. \(who) reads your brief instead of the raw text, so write \
        for a busy person: plain language, short sentences, and no paths, hashes, ids or test \
        counts unless one matters to a decision.

        summary: two to four sentences on what the issue is about and where it stands now.

        points: up to five short bullets with the facts that matter most (what was done, what is \
        left, risks). Leave it empty when the summary already covers them.

        items: every question, decision or choice, approval or sign-off, and request for \
        direction the issue puts to \(who), whether or not \(who) has answered it yet. Include \
        findings or follow-ups that need \(who) to decide what happens next even when they are \
        not phrased as questions. Not items: work the agents will do themselves, and rhetorical \
        questions. Keep the items in document order; return none only when the issue puts \
        nothing to \(who) at all.

        \(who)'s answers appear as lines starting "\(who) YYYY-MM-DD", "\(who) decision" or \
        "From \(who)", often with (re: "...") naming the question they answer. Mark an item \
        answered only when such a line clearly answers that specific item; answering a related \
        or earlier question does not count. When in doubt, it is open.

        For each item:
        - title: the question as one plain sentence ending in "?".
        - context: one to three plain sentences with the background needed to answer it.
        - options: the concrete choices, from the text or the obvious ones (for example, go \
        ahead or hold off), each with a short label and a one-sentence consequence. Empty for \
        an open question.
        - changes: for each option, the updates to the issue itself that picking it implies, \
        so the issue's state follows the decision; empty when the option needs only the reply. \
        Kinds and values: status ("open", "in_progress", "blocked" or "deferred"); close (a \
        short reason, for an option that drops or finishes the issue); priority ("0" critical \
        to "4" backlog); defer and due (a date as YYYY-MM-DD, worked out from today for \
        relative dates, or "" to clear; defer hides the issue from ready work until then); \
        add_label and remove_label (one label each). Suggest only what the option clearly \
        implies, such as hold off until a date (defer), drop it (close) or make it urgent \
        (priority), each with a one-sentence reason. Never a change that leaves a value as it is.
        - recommended: the label of the option the text recommends, or "" when it recommends none.
        - quote: a short excerpt copied exactly from the text (one sentence or clause) where \
        the item is raised.
        - section: the section that quote is in.
        - status: "answered" when one of \(who)'s lines answers it, otherwise "open".
        - answered_by: for an answered item, that line of \(who)'s, copied exactly; "" when open.
        - label: the item's own number or letter where the text raises it, copied exactly \
        ("(3)", "2.", "b)", "Q4"), so \(who)'s answer can name it; "" when it has none. When \
        one numbered line or paragraph holds several questions, give each its own number.
        """
    }

    /// Sends one Messages request whose answer must match `schema` (structured output), and
    /// returns the answer parsed from its text block, with timings. Every outcome saves the
    /// request and what came back (BriefRecorder, named after `recordID`); a successful answer
    /// is saved under `answerKey` so it reads as JSON. `task` and `retry` complete the error
    /// messages ("Claude declined to <task>", "..., then <retry>").
    static func structured(recordID: String, task: String, retry: String, logCategory: String, answerKey: String,
                           system: String, user: String, schema: [String: Any],
                           model: String, effort: String, maxTokens: Int, apiKey: String)
        async throws -> ([String: Any], BriefTiming) {
        var timing = BriefTiming(model: model, effort: effort, maxTokens: maxTokens)
        let started = Date()
        var req = request("messages", apiKey: apiKey)
        req.httpMethod = "POST"
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "output_config": ["effort": effort, "format": ["type": "json_schema", "schema": schema]],
            "messages": [["role": "user", "content": user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        timing.prepare = Date().timeIntervalSince(started)

        let collector = TaskMetricsCollector()
        let sent = Date()
        // Every outcome below saves the request and what came back (BriefRecorder).
        func record(_ response: Any?, error: String?) -> URL? {
            BriefRecorder.save(issueID: recordID, request: body, response: response, error: error, timing: timing)
        }
        func fail(_ message: String, response: Any?) -> ReviewError {
            ReviewError(message: message, recordURL: record(response, error: message))
        }
        let json: [String: Any]
        do {
            let (data, status) = try await sendRaw(req, delegate: collector)
            do {
                json = try checked(data, status: status)
            } catch {
                timing.request = Date().timeIntervalSince(sent)
                let raw: Any = (try? JSONSerialization.jsonObject(with: data)) ?? String(decoding: data, as: UTF8.self)
                BTLog.log("failed \(timing.logLine): \(error.localizedDescription)", category: logCategory)
                throw fail(error.localizedDescription, response: raw)
            }
        } catch let error as ReviewError {
            throw error
        } catch {
            timing.request = Date().timeIntervalSince(sent)
            BTLog.log("failed \(timing.logLine): \(error.localizedDescription)", category: logCategory)
            throw fail(error.localizedDescription, response: nil)
        }
        let received = Date()
        timing.request = received.timeIntervalSince(sent)
        if let t = collector.metrics?.transactionMetrics.last {
            if let start = t.domainLookupStartDate ?? t.connectStartDate, let end = t.connectEndDate {
                timing.connect = end.timeIntervalSince(start)
            }
            if let reqEnd = t.requestEndDate, let respStart = t.responseStartDate {
                timing.waiting = respStart.timeIntervalSince(reqEnd)
            }
            if let respStart = t.responseStartDate, let respEnd = t.responseEndDate {
                timing.download = respEnd.timeIntervalSince(respStart)
            }
            timing.requestID = (t.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "request-id")
        }
        if let usage = json["usage"] as? [String: Any] {
            timing.inputTokens = usage["input_tokens"] as? Int
            timing.outputTokens = usage["output_tokens"] as? Int
        }

        switch json["stop_reason"] as? String {
        case "refusal":
            BTLog.log("refused \(timing.logLine)", category: logCategory)
            throw fail("Claude declined to \(task).", response: json)
        case "max_tokens":
            BTLog.log("cut off \(timing.logLine)", category: logCategory)
            throw fail("Claude's answer was cut off at the \(maxTokens.formatted())-token output limit "
                + "(its thinking counts toward the limit) after \(BriefTiming.secs(timing.request)). "
                + "Raise Output limit or lower Effort in Review settings, then \(retry).", response: json)
        default: break
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        else { throw fail("Claude returned an unreadable answer.", response: json) }
        timing.parse = Date().timeIntervalSince(received)
        var saved = json
        saved[answerKey] = parsed
        timing.recordURL = record(saved, error: nil)
        return (parsed, timing)
    }

    /// Kinds of issue update a brief option may suggest (`UpdateAction.Kind` raw values).
    static let optionChangeKinds = ["status", "close", "priority", "defer", "due", "add_label", "remove_label"]

    /// `state` is the issue's current fields (status, priority, dates...), so Claude can suggest
    /// updates that change them.
    static func brief(issueID: String, title: String, state: String, sections: [(String, String)], initials: String,
                      model: String, effort: String, maxTokens: Int, apiKey: String) async throws -> ReviewBrief {
        let document = sections
            .map { "<section name=\"\($0.0)\">\n\($0.1)\n</section>" }
            .joined(separator: "\n\n")
        let changeSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "kind":   ["type": "string", "enum": optionChangeKinds],
                "value":  ["type": "string"],
                "reason": ["type": "string"],
            ],
            "required": ["kind", "value", "reason"],
            "additionalProperties": false,
        ]
        let optionSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "label": ["type": "string"],
                "detail": ["type": "string"],
                "changes": ["type": "array", "items": changeSchema],
            ],
            "required": ["label", "detail", "changes"],
            "additionalProperties": false,
        ]
        let itemSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "kind":        ["type": "string", "enum": ["question", "decision"]],
                "title":       ["type": "string"],
                "context":     ["type": "string"],
                "options":     ["type": "array", "items": optionSchema],
                "recommended": ["type": "string"],
                "quote":       ["type": "string"],
                "section":     ["type": "string", "enum": reviewSectionNames],
                "label":       ["type": "string"],
                "status":      ["type": "string", "enum": ["open", "answered"]],
                "answered_by": ["type": "string"],
            ],
            "required": ["kind", "title", "context", "options", "recommended", "quote", "section", "label",
                         "status", "answered_by"],
            "additionalProperties": false,
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "points":  ["type": "array", "items": ["type": "string"]],
                "items":   ["type": "array", "items": itemSchema],
            ],
            "required": ["summary", "points", "items"],
            "additionalProperties": false,
        ]
        let (parsed, timing) = try await structured(
            recordID: issueID, task: "review this issue", retry: "Refresh", logCategory: "brief", answerKey: "brief",
            system: systemPrompt(initials: initials),
            user: "Issue: \(title)\nToday is \(FreeformUpdate.todayLine()).\n\n<state>\n\(state)\n</state>\n\n\(document)",
            schema: schema,
            model: model, effort: effort, maxTokens: maxTokens, apiKey: apiKey)

        func str(_ any: Any?) -> String { ((any as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let items: [ReviewItem] = (parsed["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard let kind = (item["kind"] as? String).flatMap(ReviewItemKind.init(rawValue:)) else { return nil }
            let title = str(item["title"])
            let quote = str(item["quote"])
            guard !title.isEmpty || !quote.isEmpty else { return nil }
            let options = (item["options"] as? [[String: Any]] ?? []).compactMap { o -> ReviewOption? in
                let label = str(o["label"])
                let changes = (o["changes"] as? [[String: Any]] ?? []).compactMap { c -> SuggestedChange? in
                    let kind = str(c["kind"])
                    return optionChangeKinds.contains(kind)
                        ? SuggestedChange(kind: kind, value: str(c["value"]), reason: str(c["reason"])) : nil
                }
                return label.isEmpty ? nil : ReviewOption(label: label, detail: str(o["detail"]), changes: changes)
            }
            let recommended = str(item["recommended"])
            let label = str(item["label"])
            let answeredBy = str(item["answered_by"])
            let answered = str(item["status"]) == "answered"
            return ReviewItem(section: str(item["section"]), kind: kind,
                              quote: quote.isEmpty ? title : quote,
                              title: title.isEmpty ? nil : title,
                              context: str(item["context"]),
                              options: options,
                              recommended: options.contains { $0.label == recommended } ? recommended : nil,
                              label: label.isEmpty ? itemLabel(quote) : label,
                              answeredBy: answered ? (answeredBy.isEmpty ? "(answered, no line given)" : answeredBy) : nil)
        }
        let points = (parsed["points"] as? [String] ?? []).map { str($0) }.filter { !$0.isEmpty }
        return ReviewBrief(summary: str(parsed["summary"]), points: points, items: items, timing: timing)
    }
}

/// A not-yet-recorded answer to one brief item.
struct DraftAnswer {
    var choice: String? = nil
    var comment = ""
    /// Summaries of the chosen option's suggested updates the user unticked.
    var unticked: Set<String> = []

    /// The answer as written to Notes: "Choice. comment", or either alone.
    var text: String {
        let note = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = choice else { return note }
        if note.isEmpty { return c }
        return c.last.map { ".!?".contains($0) } == true ? "\(c) \(note)" : "\(c). \(note)"
    }
}

/// Claude's briefs, one per issue, plus the answers being drafted against them. A brief is
/// made once and then kept when the issue changes; the card says it is out of date and
/// Refresh asks again. Recording answers remakes it as soon as the new Notes arrive.
@MainActor
final class NeedsYouAI: ObservableObject {
    static let shared = NeedsYouAI()

    private struct Stored {
        let brief: ReviewBrief
        let contentKey: String
    }

    @Published private var briefs: [String: Stored] = [:]        // by issue id
    @Published private var loading: Set<String> = []
    private var loadingSince: [String: Date] = [:]
    @Published private var errors: [String: ReviewError] = [:]
    @Published private var drafts: [String: [String: DraftAnswer]] = [:]   // issue id -> item id
    /// Issues whose brief is remade when their content next changes (answers just recorded).
    private var refreshOnChange: Set<String> = []

    func contentKey(for d: BeadsIssueDetail) -> String {
        var h = Hasher()
        h.combine(d.title)
        for (name, text) in reviewSections(d) { h.combine(name); h.combine(text) }
        return String(h.finalize())
    }

    func brief(for d: BeadsIssueDetail) -> ReviewBrief? { briefs[d.id]?.brief }
    func isLoading(_ d: BeadsIssueDetail) -> Bool { loading.contains(d.id) }
    func loadingSince(_ d: BeadsIssueDetail) -> Date? { loadingSince[d.id] }
    func error(for d: BeadsIssueDetail) -> ReviewError? { errors[d.id] }
    func isStale(_ d: BeadsIssueDetail) -> Bool {
        briefs[d.id].map { $0.contentKey != contentKey(for: d) } ?? false
    }

    /// Makes the issue's first brief; later ones only come from `refresh`.
    func requestIfNeeded(_ d: BeadsIssueDetail, initials: String) {
        guard briefs[d.id] == nil, errors[d.id] == nil else { return }
        refresh(d, initials: initials)
    }

    /// Remake the brief once the issue's content changes, e.g. when recorded answers arrive.
    func refreshAfterNextChange(_ issueID: String, _ on: Bool = true) {
        if on { refreshOnChange.insert(issueID) } else { refreshOnChange.remove(issueID) }
    }

    func refreshIfChanged(_ d: BeadsIssueDetail, initials: String) {
        guard refreshOnChange.contains(d.id), isStale(d) else { return }
        refreshOnChange.remove(d.id)
        refresh(d, initials: initials)
    }

    func refresh(_ d: BeadsIssueDetail, initials: String) {
        let id = d.id
        guard !loading.contains(id) else { return }
        guard let apiKey = AnthropicKeychain.load() else {
            errors[id] = ReviewError(message: "No Anthropic API key saved (Review settings).")
            return
        }
        errors[id] = nil
        loading.insert(id)
        loadingSince[id] = Date()
        let key = contentKey(for: d)
        let title = d.title
        let state = briefState(d)
        let sections = reviewSections(d)
        let model = AnthropicReview.model
        let effort = AnthropicReview.effort
        let maxTokens = AnthropicReview.maxTokens
        let started = Date()
        Task {
            do {
                var brief = try await AnthropicReview.brief(issueID: id, title: title, state: state, sections: sections,
                                                            initials: initials,
                                                            model: model, effort: effort, maxTokens: maxTokens,
                                                            apiKey: apiKey)
                brief.timing?.total = Date().timeIntervalSince(started)
                if let timing = brief.timing { BTLog.log("\(id) \(timing.logLine)", category: "brief") }
                briefs[id] = Stored(brief: brief, contentKey: key)
            } catch {
                errors[id] = (error as? ReviewError) ?? ReviewError(message: error.localizedDescription)
            }
            loading.remove(id)
            loadingSince[id] = nil
        }
    }

    /// The fields an option's suggested updates can change, as they are now.
    private func briefState(_ d: BeadsIssueDetail) -> String {
        func day(_ iso: String?) -> String { iso.map { String($0.prefix(10)) } ?? "none" }
        let labels = d.labels ?? []
        return [
            "status: \(d.status)",
            "priority: \(d.priority)",
            "labels: \(labels.isEmpty ? "none" : labels.joined(separator: ", "))",
            "due: \(day(d.due))",
            "deferred until: \(day(d.deferUntil))",
        ].joined(separator: "\n")
    }

    func draft(_ issueID: String, _ itemID: String) -> DraftAnswer {
        drafts[issueID]?[itemID] ?? DraftAnswer()
    }

    func setDraft(_ draft: DraftAnswer, _ issueID: String, _ itemID: String) {
        drafts[issueID, default: [:]][itemID] = draft
    }

    func clearDrafts(_ issueID: String, _ itemIDs: [String]) {
        for itemID in itemIDs { drafts[issueID]?[itemID] = nil }
    }
}

// MARK: - API key storage (Keychain)

enum AnthropicKeychain {
    private static let service = "BeadsTracker.anthropic-api-key"
    private static let account = "default"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

// MARK: - Views

/// A TextEditor's typing undo goes on the window's undo stack and stays there when the editor
/// is removed (a reply sent, a sheet closed). ⌘Z in another field, such as the list filter,
/// falls through to that stack once its own edits run out and messages the freed text view,
/// crashing the app (bt-djz). Every TextEditor wrapper calls this when it disappears.
func clearStaleUndo(_ undoManager: UndoManager?) {
    undoManager?.removeAllActions()
}

/// A multi-line text editor that grows with its text (Return adds a line), up to `maxHeight`,
/// then scrolls. A hidden copy of the text sets the height; the editor is laid over it.
struct GrowingTextEditor: View {
    @Binding var text: String
    var placeholder: String = ""
    var minHeight: CGFloat = 36
    var maxHeight: CGFloat = 240
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Text(text + "\n ")
            .font(.body)
            .padding(.horizontal, 5).padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: maxHeight, alignment: .topLeading)
            .opacity(0)
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .onDisappear { clearStaleUndo(undoManager) }
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body).foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
    }
}

/// Inline editor for a reply or note, appended to the issue's Notes on submit.
struct NoteReplyEditor: View {
    let prefix: String                       // shown above the field, e.g. "CNG 2026-11-01:"
    let onSubmit: (String) async throws -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @State private var isSaving = false
    @State private var error: String? = nil
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(prefix).font(.caption).foregroundStyle(.secondary)
            GrowingTextEditor(text: $text, minHeight: 54)
                .focused($focused)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Button {
                    submit()
                } label: {
                    if isSaving { ProgressView().scaleEffect(0.6) } else { Text("Add to Notes") }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Append to Notes (\u{2318}\u{21A9})")
            }
            .controlSize(.small)
        }
        .onAppear { focused = true }
    }

    private func submit() {
        let answer = text
        isSaving = true
        error = nil
        Task {
            do {
                try await onSubmit(answer)
                onCancel()
            } catch {
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }
}

/// One question/decision in the "Needs you" list, with its reply control.
struct ReviewItemRow: View {
    let item: ReviewItem
    let answered: Bool
    let isReplying: Bool
    let onReply: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: item.kind == .question ? "questionmark.circle" : "arrow.triangle.branch")
                .foregroundStyle(answered ? Color.secondary : Color.orange)
                .help(item.kind == .question ? "Question" : "Decision")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayText)
                    .font(.callout)
                    .foregroundStyle(answered ? .secondary : .primary)
                    .lineLimit(6)
                    .textSelection(.enabled)
                Text(item.section).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if answered {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("A reply in Notes refers to this")
            }
            Button("Reply", action: onReply)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isReplying)
                .help("Write an answer and append it to Notes")
        }
    }
}

/// The top of Claude's brief: what the issue is about and where it stands.
struct BriefSummaryView: View {
    let brief: ReviewBrief

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !brief.summary.isEmpty {
                Text(brief.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(brief.points, id: \.self) { point in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\u{2022}").foregroundStyle(.secondary)
                    Text(point).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One item of Claude's brief, answered in place: pick an option and/or write a comment. The
/// card records all drafted answers in Notes together.
struct DecisionItemView: View {
    let item: ReviewItem
    let answered: Bool
    let canReply: Bool
    @Binding var draft: DraftAnswer
    /// An option's suggested updates, checked against the issue as it is now.
    var changes: (ReviewOption) -> [UpdateAction] = { _ in [] }
    @State private var showSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: item.kind == .question ? "questionmark.circle" : "arrow.triangle.branch")
                    .foregroundStyle(answered ? Color.secondary : Color.orange)
                Text(item.displayText)
                    .font(.callout).fontWeight(.semibold)
                    .foregroundStyle(answered ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if answered {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("A reply in Notes refers to this")
                }
            }
            if let context = item.context, !context.isEmpty {
                Text(context)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.options.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(item.options, id: \.self) { option in
                        optionRow(option)
                        if draft.choice == option.label {
                            ForEach(changes(option), id: \.summary) { changeRow($0) }
                        }
                    }
                }
            }
            if canReply {
                GrowingTextEditor(text: $draft.comment,
                                  placeholder: item.options.isEmpty ? "Your answer" : "Comment (optional)")
            }
            Button(showSource ? "Hide source" : "Show source") { showSource.toggle() }
                .buttonStyle(.link)
                .font(.caption)
                .help("The text this item was found in (\(item.section))")
            if showSource {
                Text("\(item.section): \u{201C}\(plainQuote(item.quote))\u{201D}")
                    .font(.caption).italic().foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private func optionRow(_ option: ReviewOption) -> some View {
        let selected = draft.choice == option.label
        return Button {
            draft.choice = selected ? nil : option.label
            draft.unticked = []
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(option.label).font(.callout).fontWeight(.medium)
                        if option.label == item.recommended {
                            Text("Recommended")
                                .font(.caption2).fontWeight(.medium)
                                .foregroundStyle(.green)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.green.opacity(0.12), in: Capsule())
                        }
                    }
                    if !option.detail.isEmpty {
                        Text(option.detail)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canReply)
    }
}

extension DecisionItemView {
    /// A suggested update under the chosen option, ticked unless the user unticks it; recording
    /// the answer makes the ticked ones.
    fileprivate func changeRow(_ a: UpdateAction) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Toggle("", isOn: Binding(
                get: { !draft.unticked.contains(a.summary) },
                set: { if $0 { draft.unticked.remove(a.summary) } else { draft.unticked.insert(a.summary) } }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(!canReply)
            VStack(alignment: .leading, spacing: 1) {
                Text("Also: \(a.summary)").font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if !a.reason.isEmpty {
                    Text(a.reason).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 22)
        .help("Untick to record the answer without this change")
    }
}

/// An item Claude judged already answered, with the line it took as the answer.
struct AnsweredItemRow: View {
    let item: ReviewItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayText)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.answeredBy.map { "Answered: \u{201C}\($0)\u{201D}" } ?? "Answered by your reply in Notes")
                    .font(.caption).italic().foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Settings popover for the detail panel's review bar.
struct ReviewSettingsView: View {
    @AppStorage("replyInitials") private var initials: String = ""
    @AppStorage("needsYouSource") private var source: String = "rules"
    @AppStorage("reviewModel") private var model: String = ""
    @AppStorage("reviewEffort") private var effort: String = AnthropicReview.defaultEffort
    @AppStorage("reviewMaxTokens") private var maxTokens: Int = AnthropicReview.defaultMaxTokens
    @State private var availableModels: [String] = []
    @State private var keyInput = ""
    @State private var hasKey = AnthropicKeychain.load() != nil
    @State private var keyError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign replies as").font(.subheadline).fontWeight(.medium)
                TextField(replyInitials(""), text: $initials)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Text("Replies are added to Notes as \u{201C}\(replyInitials(initials)) \(replyDateStamp()): \u{2026}\u{201D}")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Find questions and decisions with").font(.subheadline).fontWeight(.medium)
                Picker("", selection: $source) {
                    Text("Built-in rules").tag("rules")
                    Text("Claude (plain-language brief)").tag("haiku")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("Claude sends the issue's content to the Anthropic API, using your API key.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Model").font(.subheadline).fontWeight(.medium)
                HStack {
                    TextField(AnthropicReview.defaultModel, text: $model)
                        .textFieldStyle(.roundedBorder)
                    Menu {
                        if availableModels.isEmpty {
                            Text(hasKey ? "Loading\u{2026}" : "Save an API key to list models")
                        }
                        ForEach(availableModels, id: \.self) { id in
                            Button(id) { model = id }
                        }
                        Divider()
                        Button("Default (\(AnthropicReview.defaultModel))") { model = "" }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Models your API key can use")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Effort").font(.subheadline).fontWeight(.medium)
                Picker("", selection: $effort) {
                    ForEach(AnthropicReview.efforts, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("How much Claude thinks before writing the brief. Lower is faster and cheaper; higher may judge tangled issues better.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Output limit").font(.subheadline).fontWeight(.medium)
                    Spacer()
                    Picker("", selection: $maxTokens) {
                        ForEach(AnthropicReview.maxTokensChoices, id: \.self) { n in
                            Text("\(n / 1000)K tokens").tag(n)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text("The most Claude may write for one brief, thinking included. A brief is cut off at this limit; you pay only for what is written. New briefs use these settings; Refresh a brief to remake it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Anthropic API key").font(.subheadline).fontWeight(.medium)
                if hasKey {
                    HStack {
                        Label("Saved in Keychain", systemImage: "key.fill").font(.caption)
                        Spacer()
                        Button("Remove") { AnthropicKeychain.delete(); hasKey = false }
                            .controlSize(.small)
                    }
                } else {
                    HStack {
                        SecureField("sk-ant-\u{2026}", text: $keyInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            if AnthropicKeychain.save(key) {
                                hasKey = true; keyInput = ""; keyError = nil
                            } else {
                                keyError = "Could not save the key to the Keychain."
                            }
                        }
                        .controlSize(.small)
                        .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let keyError { Text(keyError).font(.caption).foregroundStyle(.red) }
                }
            }
        }
        .padding()
        .frame(width: 320)
        .task(id: hasKey) { await loadModels() }
    }

    private func loadModels() async {
        guard hasKey, let apiKey = AnthropicKeychain.load() else { availableModels = []; return }
        availableModels = (try? await AnthropicReview.models(apiKey: apiKey)) ?? []
    }
}
