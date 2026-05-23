// Models.swift
// Enums, data structs, FormDraftManager, and AppDelegate.

import SwiftUI
import AppKit

// MARK: - Date Helpers

/// Convert an ISO8601 date string to a human-readable relative time (e.g., "2h ago", "3d ago").
func relativeAge(from isoString: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    
    var date: Date?
    // Try with fractional seconds first
    date = formatter.date(from: isoString)
    
    // Fallback to standard format without fractional seconds
    if date == nil {
        formatter.formatOptions = [.withInternetDateTime]
        date = formatter.date(from: isoString)
    }
    
    guard let date = date else { return isoString }
    
    let now = Date()
    let interval = now.timeIntervalSince(date)
    
    // Future dates
    if interval < 0 {
        let futureInterval = -interval
        if futureInterval < 60 { return "in <1m" }
        if futureInterval < 3600 { return "in \(Int(futureInterval / 60))m" }
        if futureInterval < 86400 { return "in \(Int(futureInterval / 3600))h" }
        if futureInterval < 2592000 { return "in \(Int(futureInterval / 86400))d" }
        if futureInterval < 31536000 { return "in \(Int(futureInterval / 2592000))mo" }
        return "in \(Int(futureInterval / 31536000))y"
    }
    
    // Past dates
    if interval < 60 { return "<1m ago" }
    if interval < 3600 { return "\(Int(interval / 60))m ago" }
    if interval < 86400 { return "\(Int(interval / 3600))h ago" }
    if interval < 2592000 { return "\(Int(interval / 86400))d ago" }
    if interval < 31536000 { return "\(Int(interval / 2592000))mo ago" }
    return "\(Int(interval / 31536000))y ago"
}

/// Format an ISO8601 date string as an absolute date (e.g., "23 May 2026").
/// Short date for compact badges, e.g. "30 May" or "2 Jun 2025"
func shortDate(from isoString: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: isoString) else { return isoString }
    let fmt = DateFormatter()
    let cal = Calendar.current
    fmt.dateFormat = cal.isDate(date, equalTo: Date(), toGranularity: .year) ? "d MMM" : "d MMM yyyy"
    return fmt.string(from: date)
}

func absoluteDate(from isoString: String) -> String {
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    
    var date: Date?
    date = isoFormatter.date(from: isoString)
    
    if date == nil {
        isoFormatter.formatOptions = [.withInternetDateTime]
        date = isoFormatter.date(from: isoString)
    }
    
    guard let date = date else { return isoString }
    
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
}

// MARK: - Domain Enums

enum IssueType: String, CaseIterable, Identifiable, Codable {
    case task, bug, feature, epic, chore
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum Priority: String, CaseIterable, Identifiable, Codable {
    case p0 = "0", p1 = "1", p2 = "2", p3 = "3", p4 = "4"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .p0: return "P0 \u{2013} Critical"
        case .p1: return "P1 \u{2013} High"
        case .p2: return "P2 \u{2013} Medium (default)"
        case .p3: return "P3 \u{2013} Low"
        case .p4: return "P4 \u{2013} Backlog"
        }
    }
}

enum BeadsError: LocalizedError {
    case commandFailed(String)
    var errorDescription: String? {
        switch self {
        case .commandFailed(let msg):
            return msg.isEmpty ? "`bd` command failed with no output" : msg
        }
    }
}

// MARK: - Data Models

struct BeadsIssue: Identifiable {
    let id: String
    let title: String
    let status: String       // "open", "in_progress", "closed", "deferred", "blocked"
    let priority: Int        // 0-4
    let issueType: String?   // "task", "bug", "feature", etc.
    let parentID: String?
    let dependencyCount: Int      // issues this one depends on
    let dependentCount:  Int      // issues depending on this one
    let updatedAt: String         // ISO8601 timestamp for age display
    let due: String?              // ISO8601 due date, if set
    let deferUntil: String?       // ISO8601 defer-until date, if set
    var children: [BeadsIssue]?   // nil = leaf node

    var statusSymbol: String {
        switch status {
        case "open":        return "\u{25CB}"  // ○
        case "in_progress": return "\u{25D0}"  // ◐
        case "closed":      return "\u{2713}"  // ✓
        case "deferred":    return "\u{2744}"  // ❄
        default:            return "\u{25CF}"  // ● blocked/unknown
        }
    }

    var statusColor: Color {
        switch status {
        case "open":        return .primary
        case "in_progress": return .blue
        case "closed":      return .green
        case "deferred":    return .purple
        default:            return .orange
        }
    }

    var priorityLabel: String { "P\(priority)" }
}

// Structured detail returned by `bd show --json <id>`
struct BeadsIssueDetail: Decodable {
    let id: String
    let title: String
    let description: String?
    let design: String?
    let acceptanceCriteria: String?   // JSON key "acceptance_criteria"
    let status: String
    let priority: Int
    let issueType: String?
    let assignee: String?             // JSON key "assignee" (display name)
    let owner: String?                // email address
    let labels: [String]?             // JSON key "labels"
    let notes: String?
    let comments: [BeadsComment]?
    let dependencies:       [BeadsDependency]?  // upstream: what this issue depends on
    let dependents:         [BeadsDependency]?  // downstream: children (parent-child) + issues blocked by this
    let epicTotalChildren:  Int?
    let epicClosedChildren: Int?
    let createdAt: String?
    let updatedAt: String
    let startedAt: String?
    let due: String?
    let deferUntil: String?
    enum CodingKeys: String, CodingKey {
        case id, title, description, design, status, owner, assignee, labels, notes, comments, dependencies, dependents
        case priority, issueType = "issue_type"
        case acceptanceCriteria  = "acceptance_criteria"
        case epicTotalChildren   = "epic_total_children"
        case epicClosedChildren  = "epic_closed_children"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case startedAt = "started_at"
        case due = "due_at"
        case deferUntil = "defer_until"
    }
}

struct BeadsDependency: Decodable, Identifiable {
    let id: String
    let title: String
    let status: String
    let priority: Int
    let dependencyType: String?   // "blocks", "blocked-by", "discovered-from", etc.
    enum CodingKeys: String, CodingKey {
        case id, title, status, priority
        case dependencyType = "dependency_type"
    }
}

struct BeadsComment: Decodable, Identifiable {
    let id: String
    let author: String
    let text: String
    let createdAt: String
    enum CodingKeys: String, CodingKey {
        case id, author, text
        case createdAt = "created_at"
    }
}

// Shared form field state — used by both CreateIssueView and IssueEditSheet
struct IssueFormFields: Codable {
    var title              = ""
    var description        = ""
    var issueType: IssueType = .task
    var priority: Priority   = .p2
    var assignee           = ""
    var labels             = ""
    var externalRef        = ""
    var designNotes        = ""
    var acceptanceCriteria = ""
    var dependencies       = ""
    var notes              = ""

    var hasUnsavedContent: Bool {
        !title.isEmpty || !description.isEmpty || !assignee.isEmpty ||
        !labels.isEmpty || !externalRef.isEmpty || !designNotes.isEmpty ||
        !acceptanceCriteria.isEmpty || !dependencies.isEmpty || !notes.isEmpty
    }

    static func from(_ detail: BeadsIssueDetail) -> IssueFormFields {
        var f = IssueFormFields()
        f.title              = detail.title
        f.description        = detail.description ?? ""
        f.designNotes        = detail.design ?? ""
        f.acceptanceCriteria = detail.acceptanceCriteria ?? ""
        f.assignee           = detail.assignee ?? detail.owner ?? ""  // prefer display name
        f.labels             = detail.labels?.joined(separator: ", ") ?? ""
        f.notes              = detail.notes ?? ""
        if let t = detail.issueType, let it = IssueType(rawValue: t) { f.issueType = it }
        if let p = Priority(rawValue: String(detail.priority))        { f.priority  = p }
        return f
    }
}

// MARK: - Draft Manager

/// Singleton observable object that owns the Create-form field state and
/// provides UserDefaults-backed draft persistence.
class FormDraftManager: ObservableObject {
    static let shared = FormDraftManager()
    private let draftKey = "createFormDraft"

    @Published var fields = IssueFormFields()

    // MARK: Persistence

    func saveDraft() {
        guard let data = try? JSONEncoder().encode(fields) else { return }
        UserDefaults.standard.set(data, forKey: draftKey)
    }

    func hasDraft() -> Bool {
        UserDefaults.standard.data(forKey: draftKey) != nil
    }

    func resumeDraft() {
        guard let data = UserDefaults.standard.data(forKey: draftKey),
              let saved = try? JSONDecoder().decode(IssueFormFields.self, from: data) else { return }
        fields = saved
    }

    func clearDraft() {
        UserDefaults.standard.removeObject(forKey: draftKey)
    }

    func clearFields() {
        fields = IssueFormFields()
    }
}

// MARK: - App Delegate (quit protection)

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let manager = FormDraftManager.shared
        guard manager.fields.hasUnsavedContent else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Discard unsaved issue?"
        alert.informativeText = "The Create form has unsaved content."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save Draft & Quit")
        alert.addButton(withTitle: "Discard & Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:   // Save Draft & Quit
            manager.saveDraft()
            return .terminateNow
        case .alertSecondButtonReturn:  // Discard & Quit
            manager.clearDraft()
            return .terminateNow
        default:                        // Cancel
            return .terminateCancel
        }
    }
}
