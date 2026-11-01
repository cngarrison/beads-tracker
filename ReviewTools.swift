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
    var id: String { section + "\u{1F}" + quote }
    /// What a reply's "(re: ...)" names: the plain question when there is one.
    var replyRef: String { title ?? quote }
}

struct ReviewOption: Hashable {
    let label: String
    let detail: String
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

/// The Notes line for a reply: "CNG 2026-11-01 (re: "Which option…"): answer".
/// `ref` is the question or quote replied to; nil for a free note.
func formatReply(_ answer: String, ref: String?, initials: String, date: Date = Date()) -> String {
    let head = "\(initials) \(replyDateStamp(date))"
    let body = answer.trimmingCharacters(in: .whitespacesAndNewlines)
    if let ref { return "\(head) (re: \"\(quoteSnippet(ref))\"): \(body)" }
    return "\(head): \(body)"
}

/// True when the notes already hold a reply that references this item.
func isAnswered(_ item: ReviewItem, notes: String?) -> Bool {
    guard let notes, !notes.isEmpty else { return false }
    var key = quoteSnippet(item.replyRef)
    if key.hasSuffix("\u{2026}") { key.removeLast() }
    return notes.contains("(re: \"\(key)")
}

// MARK: - Built-in rules

private let fencePattern = "^\\s*```"
private let listMarkerPattern = #"^\s*(?:[-*+>]\s+|\d+[.)]\s+|#{1,6}\s+)"#
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

    func add(_ section: String, _ kind: ReviewItemKind, _ quote: String) {
        let q = quote.trimmingCharacters(in: .whitespaces)
        guard q.count >= 8, seen.insert(section + q).inserted else { return }
        items.append(ReviewItem(section: section, kind: kind, quote: q))
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
            let probe = codeAndURLsRemoved(line)
            if matchesAny(decisions, probe) {
                // A bare lead-in ("Open questions:") is not an item itself; its list items are.
                inLeadIn = line.hasSuffix(":")
                if !inLeadIn {
                    // Quote just the sentences that ask, unless the ask spans sentences.
                    let asking = sentences(of: line).filter { matchesAny(decisions, codeAndURLsRemoved($0)) }
                    add(section, .decision, asking.isEmpty ? line : asking.joined(separator: " "))
                }
                continue
            }
            if inLeadIn && isListItem {
                add(section, probe.contains("?") ? .question : .decision, line)
                continue
            }
            inLeadIn = false
            guard probe.contains("?") else { continue }
            let questions = sentences(of: line).filter { codeAndURLsRemoved($0).contains("?") }
            if !questions.isEmpty { add(section, .question, questions.joined(separator: " ")) }
        }
    }
    return items
}

// MARK: - Claude brief

struct ReviewError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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
        let (data, response) = try await URLSession.shared.data(for: req, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
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

        items: everything that waits on \(who): questions to answer, decisions or choices, \
        approvals or sign-offs, and requests for direction. Include findings or follow-ups that \
        need \(who) to decide what happens next even when they are not phrased as questions. \
        Not items: work the agents will do themselves, rhetorical questions, and anything \(who) \
        has already answered. \(who)'s answers appear as lines starting "\(who) YYYY-MM-DD", \
        "\(who) decision" or "From \(who)", often with (re: "...") naming the question; an item \
        answered there is settled, even when the text around it still mentions it. Keep the \
        items in document order, and return none when nothing waits on \(who).

        For each item:
        - title: the question as one plain sentence ending in "?".
        - context: one to three plain sentences with the background needed to answer it.
        - options: the concrete choices, from the text or the obvious ones (for example, go \
        ahead or hold off), each with a short label and a one-sentence consequence. Empty for \
        an open question.
        - recommended: the label of the option the text recommends, or "" when it recommends none.
        - quote: a short excerpt copied exactly from the text (one sentence or clause) where \
        the item is raised.
        - section: the section that quote is in.
        """
    }

    static func brief(title: String, sections: [(String, String)], initials: String, model: String, effort: String,
                      maxTokens: Int, apiKey: String) async throws -> ReviewBrief {
        var timing = BriefTiming(model: model, effort: effort, maxTokens: maxTokens)
        let started = Date()
        var req = request("messages", apiKey: apiKey)
        req.httpMethod = "POST"

        let document = sections
            .map { "<section name=\"\($0.0)\">\n\($0.1)\n</section>" }
            .joined(separator: "\n\n")
        let optionSchema: [String: Any] = [
            "type": "object",
            "properties": ["label": ["type": "string"], "detail": ["type": "string"]],
            "required": ["label", "detail"],
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
            ],
            "required": ["kind", "title", "context", "options", "recommended", "quote", "section"],
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
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt(initials: initials),
            "output_config": ["effort": effort, "format": ["type": "json_schema", "schema": schema]],
            "messages": [["role": "user", "content": "Issue: \(title)\n\n\(document)"]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        timing.prepare = Date().timeIntervalSince(started)

        let collector = TaskMetricsCollector()
        let sent = Date()
        let json: [String: Any]
        do {
            json = try await send(req, delegate: collector)
        } catch {
            BTLog.log("failed model=\(model) effort=\(effort) max_tokens=\(maxTokens) after \(Int(Date().timeIntervalSince(sent) * 1000))ms: \(error.localizedDescription)", category: "brief")
            throw error
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
            BTLog.log("refused \(timing.logLine)", category: "brief")
            throw ReviewError(message: "Claude declined to review this issue.")
        case "max_tokens":
            BTLog.log("cut off \(timing.logLine)", category: "brief")
            throw ReviewError(message: "Claude's answer was cut off at the \(maxTokens.formatted())-token output limit "
                + "(its thinking counts toward the limit) after \(BriefTiming.secs(timing.request)). "
                + "Raise Output limit or lower Effort in Review settings, then Refresh.")
        default: break
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        else { throw ReviewError(message: "Claude returned an unreadable answer.") }

        func str(_ any: Any?) -> String { ((any as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let items: [ReviewItem] = (parsed["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard let kind = (item["kind"] as? String).flatMap(ReviewItemKind.init(rawValue:)) else { return nil }
            let title = str(item["title"])
            let quote = str(item["quote"])
            guard !title.isEmpty || !quote.isEmpty else { return nil }
            let options = (item["options"] as? [[String: Any]] ?? []).compactMap { o -> ReviewOption? in
                let label = str(o["label"])
                return label.isEmpty ? nil : ReviewOption(label: label, detail: str(o["detail"]))
            }
            let recommended = str(item["recommended"])
            return ReviewItem(section: str(item["section"]), kind: kind,
                              quote: quote.isEmpty ? title : quote,
                              title: title.isEmpty ? nil : title,
                              context: str(item["context"]),
                              options: options,
                              recommended: options.contains { $0.label == recommended } ? recommended : nil)
        }
        let points = (parsed["points"] as? [String] ?? []).map { str($0) }.filter { !$0.isEmpty }
        timing.parse = Date().timeIntervalSince(received)
        return ReviewBrief(summary: str(parsed["summary"]), points: points, items: items, timing: timing)
    }
}

/// A not-yet-recorded answer to one brief item.
struct DraftAnswer {
    var choice: String? = nil
    var comment = ""

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
    @Published private var errors: [String: String] = [:]
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
    func error(for d: BeadsIssueDetail) -> String? { errors[d.id] }
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
            errors[id] = "No Anthropic API key saved (Review settings)."
            return
        }
        errors[id] = nil
        loading.insert(id)
        loadingSince[id] = Date()
        let key = contentKey(for: d)
        let title = d.title
        let sections = reviewSections(d)
        let model = AnthropicReview.model
        let effort = AnthropicReview.effort
        let maxTokens = AnthropicReview.maxTokens
        let started = Date()
        Task {
            do {
                var brief = try await AnthropicReview.brief(title: title, sections: sections, initials: initials,
                                                            model: model, effort: effort, maxTokens: maxTokens,
                                                            apiKey: apiKey)
                brief.timing?.total = Date().timeIntervalSince(started)
                if let timing = brief.timing { BTLog.log("\(id) \(timing.logLine)", category: "brief") }
                briefs[id] = Stored(brief: brief, contentKey: key)
            } catch {
                errors[id] = error.localizedDescription
            }
            loading.remove(id)
            loadingSince[id] = nil
        }
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

/// A multi-line text editor that grows with its text (Return adds a line), up to `maxHeight`,
/// then scrolls. A hidden copy of the text sets the height; the editor is laid over it.
struct GrowingTextEditor: View {
    @Binding var text: String
    var placeholder: String = ""
    var minHeight: CGFloat = 36
    var maxHeight: CGFloat = 240

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
                Text(plainQuote(item.quote))
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
    @State private var showSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: item.kind == .question ? "questionmark.circle" : "arrow.triangle.branch")
                    .foregroundStyle(answered ? Color.secondary : Color.orange)
                Text(item.title ?? plainQuote(item.quote))
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
