// WorkspaceStore.swift
// In-memory copy of one workspace's issues, shared by every window showing that
// workspace: baselined from `bd list --all`, patched from `bd events tail` (via
// BeadsEventsWatcher), and re-read in the background to pick up changes the journal
// doesn't record. Views filter and nest `issues` locally; no filter change runs `bd`.

import Foundation
import AppKit
import Combine

// MARK: - Stored issue

/// An issue's own fields, decoded from either a `bd list --json` row or a journal event's
/// `issue` snapshot (same keys). Relationship fields (`parent`, dependency counts) are not
/// stored: events don't carry them, so WorkspaceStore derives them from its edge set.
struct StoredIssue: Decodable, Equatable {
    let id: String
    let title: String
    let status: String
    let priority: Int
    let issueType: String?
    let assignee: String?
    let owner: String?
    let labels: [String]?
    let description: String?
    let design: String?
    let acceptanceCriteria: String?
    let notes: String?
    let createdAt: String?
    let updatedAt: String
    let startedAt: String?
    let due: String?
    let deferUntil: String?
    enum CodingKeys: String, CodingKey {
        case id, title, status, priority, assignee, owner, labels, description, design, notes
        case issueType = "issue_type"
        case acceptanceCriteria = "acceptance_criteria"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case startedAt = "started_at"
        case due = "due_at"
        case deferUntil = "defer_until"
    }
}

/// One `bd list --json` row: the issue plus its outgoing dependency edges.
private struct ListRow: Decodable {
    struct Edge: Decodable {
        let issueID: String
        let dependsOnID: String
        let type: String
        enum CodingKeys: String, CodingKey {
            case type
            case issueID = "issue_id"
            case dependsOnID = "depends_on_id"
        }
    }
    let issue: StoredIssue
    let dependencies: [Edge]

    enum CodingKeys: String, CodingKey { case dependencies }

    init(from decoder: Decoder) throws {
        issue = try StoredIssue(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dependencies = try c.decodeIfPresent([Edge].self, forKey: .dependencies) ?? []
    }
}

// MARK: - WorkspaceStore

@MainActor
final class WorkspaceStore: ObservableObject {
    let path: String
    let watcher = BeadsEventsWatcher()

    /// Every issue in the workspace, flat, in `bd list` order (priority, then newest
    /// first), with parent and dependency counts derived. Views nest it with
    /// `BeadsRunner.buildTree(_:)` after filtering.
    @Published private(set) var issues: [BeadsIssue] = []
    /// True once the first baseline succeeded; later re-reads keep the list on screen.
    @Published private(set) var hasLoaded = false
    @Published private(set) var isLoading = false
    /// Issues received so far during the first load (spinner text).
    @Published private(set) var loadingCount = 0
    /// Last baseline failure, cleared by the next success.
    @Published private(set) var errorMessage: String? = nil
    /// Number of journal events applied; lets callers tell whether their change arrived.
    private(set) var appliedEventCount = 0

    private var records: [String: StoredIssue] = [:]
    private var outgoing: [String: [String: String]] = [:]   // issue → (depends-on → type)
    private var incoming: [String: [String: String]] = [:]   // depends-on → (issue → type)

    /// Non-nil while a baseline is in flight: events arriving meanwhile are held here and
    /// applied, in order, on top of the new data.
    private var heldEvents: [JournalEvent]? = nil
    private var rebaselineQueued = false
    /// RFC3339 second at which the current data's `bd list` was launched. Any event with an
    /// earlier `ts` was committed before that read, so the data already reflects it; skipping
    /// those makes replayed and late-arriving events harmless.
    private var baselineStartedAt = ""
    private var lastBaselineAt: Date? = nil
    /// Bumped by stop() so an in-flight baseline can't apply after the store is torn down.
    private var generation = 0
    private var publishWorkItem: DispatchWorkItem? = nil
    private var rebaselineTimer: Timer? = nil
    private var activationObserver: NSObjectProtocol? = nil
    private var watcherForward: AnyCancellable? = nil

    /// The journal only records this clone's own mutations: `bd dolt pull`, merges and
    /// `bd sql` writes never appear as events. Re-reading on this interval, and when the app
    /// is reactivated after `staleAfter`, picks those up.
    private static let rebaselineInterval: TimeInterval = 300
    private static let staleAfter: TimeInterval = 60
    /// Event bursts (several agents at once) are coalesced into one published update.
    private static let publishDelay: TimeInterval = 0.15

    init(path: String) {
        self.path = path
        // Re-publish the watcher's Live/Manual and toast changes to observers of the store.
        watcherForward = watcher.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func start() {
        BTLog.log("store start path=\(path)", category: "store")
        watcher.start(workingDirectory: path,
                      onEvent: { [weak self] event in self?.apply(event) },
                      onResync: { [weak self] in self?.rebaseline() })
        rebaseline()
        rebaselineTimer = Timer.scheduledTimer(withTimeInterval: Self.rebaselineInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rebaseline() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let last = self.lastBaselineAt,
                      Date().timeIntervalSince(last) > Self.staleAfter else { return }
                self.rebaseline()
            }
        }
    }

    func stop() {
        BTLog.log("store stop path=\(path)", category: "store")
        generation += 1
        watcher.stop()
        rebaselineTimer?.invalidate()
        rebaselineTimer = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        publishWorkItem?.cancel()
        publishWorkItem = nil
        heldEvents = nil
    }

    // MARK: Baseline

    /// Re-reads the whole workspace in the background and swaps it in without blanking the
    /// list (row identity is the issue ID, so SwiftUI only redraws rows that changed). A call
    /// while one is already running queues exactly one more.
    func rebaseline() {
        guard heldEvents == nil else { rebaselineQueued = true; return }
        heldEvents = []
        isLoading = true
        loadingCount = 0
        // Cleared while retrying so a failed first load shows the spinner, not the old error.
        errorMessage = nil
        let gen = generation
        let dir = path
        let startedAt = Self.rfc3339Second(Date())
        Task {
            let (progress, listTask) = BeadsRunner.listWithProgress(workingDirectory: dir, extraArgs: ["--all"])
            for await count in progress where !hasLoaded { loadingCount = count }
            let result = await Task.detached(priority: .userInitiated) {
                try Self.decodeList(try await listTask.value)
            }.result
            guard gen == generation else { return }
            finishBaseline(result, startedAt: startedAt)
        }
    }

    private func finishBaseline(_ result: Result<([StoredIssue], [ListRow.Edge]), Error>, startedAt: String) {
        let held = heldEvents ?? []
        heldEvents = nil
        isLoading = false
        switch result {
        case .success(let (rows, edges)):
            records = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            outgoing = [:]
            incoming = [:]
            for e in edges { addEdge(from: e.issueID, to: e.dependsOnID, type: e.type) }
            baselineStartedAt = startedAt
            lastBaselineAt = Date()
            errorMessage = nil
            hasLoaded = true
            BTLog.log("baseline OK path=\(path) issues=\(rows.count) edges=\(edges.count) held=\(held.count)", category: "store")
        case .failure(let error):
            // Keep whatever we had; the held events still apply on top of it.
            errorMessage = error.localizedDescription
            BTLog.log("baseline FAILED path=\(path): \(error)", category: "store")
        }
        for event in held { apply(event) }
        publishNow()
        if rebaselineQueued {
            rebaselineQueued = false
            rebaseline()
        }
    }

    nonisolated private static func decodeList(_ data: Data) throws -> ([StoredIssue], [ListRow.Edge]) {
        let rows = try JSONDecoder().decode([ListRow].self, from: data)
        return (rows.map(\.issue), rows.flatMap(\.dependencies))
    }

    // MARK: Events

    private func apply(_ event: JournalEvent) {
        if heldEvents != nil { heldEvents?.append(event); return }
        guard event.ts >= baselineStartedAt else { return }   // already in the baseline
        appliedEventCount += 1

        switch event.op {
        case "delete":
            remove(event.issueID)
        case "dep_add":
            if let issue = event.issue { upsert(issue) }
            // An upsert: the journal also emits dep_add for an idempotent re-add.
            if let dep = event.dep { addEdge(from: event.issueID, to: dep.target, type: dep.kind) }
        case "dep_remove":
            if let issue = event.issue { upsert(issue) }
            if let dep = event.dep { removeEdge(from: event.issueID, to: dep.target) }
        default:
            // create, update, close, reopen, claim, comment, label ops: all carry the
            // issue's full post-mutation snapshot.
            if let issue = event.issue { upsert(issue) }
        }
        schedulePublish()
    }

    private func upsert(_ issue: StoredIssue) {
        if issue.status == "tombstone" { remove(issue.id); return }
        // Never let an older snapshot (late or replayed event) overwrite newer data.
        if let current = records[issue.id], current.updatedAt > issue.updatedAt { return }
        records[issue.id] = issue
    }

    private func remove(_ id: String) {
        records[id] = nil
        for to in (outgoing[id] ?? [:]).keys { incoming[to]?[id] = nil }
        for from in (incoming[id] ?? [:]).keys { outgoing[from]?[id] = nil }
        outgoing[id] = nil
        incoming[id] = nil
    }

    private func addEdge(from: String, to: String, type: String) {
        outgoing[from, default: [:]][to] = type
        incoming[to, default: [:]][from] = type
    }

    private func removeEdge(from: String, to: String) {
        outgoing[from]?[to] = nil
        incoming[to]?[from] = nil
    }

    // MARK: Own changes

    /// Call after this app changes an issue. When live, the change's own journal event
    /// updates the store; if none has been applied shortly after (watcher not live, or the
    /// journal couldn't be enabled), re-read instead.
    func expectOwnChange() {
        guard watcher.isLive else { rebaseline(); return }
        let before = appliedEventCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.appliedEventCount == before else { return }
            self.rebaseline()
        }
    }

    // MARK: Publishing

    private func schedulePublish() {
        guard publishWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.publishWorkItem = nil
            self?.publishNow()
        }
        publishWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.publishDelay, execute: work)
    }

    private func publishNow() {
        publishWorkItem?.cancel()
        publishWorkItem = nil
        let sorted = records.values.sorted { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            let ac = a.createdAt ?? "", bc = b.createdAt ?? ""
            if ac != bc { return ac > bc }
            return a.id < b.id
        }
        let next = sorted.map(makeIssue)
        // Assigning fires objectWillChange even when equal; skip no-op re-reads.
        if next != issues { issues = next }
    }

    private func makeIssue(_ r: StoredIssue) -> BeadsIssue {
        let out = outgoing[r.id] ?? [:]
        let parent = out.filter { $0.value == "parent-child" }.keys.min()
        return BeadsIssue(id: r.id, title: r.title, status: r.status,
                          priority: r.priority, issueType: r.issueType,
                          parentID: parent,
                          dependencyCount: out.values.filter { $0 == "blocks" }.count,
                          dependentCount: (incoming[r.id] ?? [:]).values.filter { $0 == "blocks" }.count,
                          updatedAt: r.updatedAt,
                          due: r.due,
                          deferUntil: r.deferUntil,
                          children: nil,
                          description: r.description,
                          notes: r.notes)
    }

    // MARK: Detail

    /// The issue's full detail built from the store: fields from its latest snapshot and
    /// relationships from the edge set (which, unlike `bd show --json`, includes an epic's
    /// children). Comments aren't in `bd list` output; pass ones fetched via `bd show`.
    func detail(for id: String, comments: [BeadsComment]?) -> BeadsIssueDetail? {
        guard let r = records[id] else { return nil }
        func relation(_ otherID: String, _ type: String) -> BeadsDependency {
            let other = records[otherID]
            return BeadsDependency(id: otherID, title: other?.title ?? "", status: other?.status ?? "",
                                   priority: other?.priority ?? 2, dependencyType: type)
        }
        func ordered(_ edges: [String: String]?) -> [(String, String)] {
            (edges ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }
        return BeadsIssueDetail(
            id: r.id, title: r.title, description: r.description, design: r.design,
            acceptanceCriteria: r.acceptanceCriteria, status: r.status, priority: r.priority,
            issueType: r.issueType, assignee: r.assignee, owner: r.owner, labels: r.labels,
            notes: r.notes, comments: comments,
            dependencies: ordered(outgoing[id]).map { relation($0.0, $0.1) },
            dependents: ordered(incoming[id]).map { relation($0.0, $0.1) },
            epicTotalChildren: nil, epicClosedChildren: nil,
            createdAt: r.createdAt, updatedAt: r.updatedAt, startedAt: r.startedAt,
            due: r.due, deferUntil: r.deferUntil)
    }

    // MARK: Helpers

    private static func rfc3339Second(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}

// MARK: - Registry

/// One store per workspace path, shared by every window showing it (one baseline, one
/// `bd events tail`). Ref-counted: the store stops when its last window releases it.
@MainActor
final class WorkspaceStoreRegistry {
    static let shared = WorkspaceStoreRegistry()
    private var entries: [String: (store: WorkspaceStore, refs: Int)] = [:]

    func acquire(_ path: String) -> WorkspaceStore {
        if let entry = entries[path] {
            entries[path] = (entry.store, entry.refs + 1)
            return entry.store
        }
        let store = WorkspaceStore(path: path)
        entries[path] = (store, 1)
        store.start()
        return store
    }

    func release(_ path: String) {
        guard let entry = entries[path] else { return }
        if entry.refs > 1 {
            entries[path] = (entry.store, entry.refs - 1)
        } else {
            entries[path] = nil
            entry.store.stop()
        }
    }
}

// MARK: - Per-window handle

/// A window's link to the store for its current workspace. Owned by IssueListView as a
/// `@StateObject`; forwards the store's changes so the view re-renders, and mirrors
/// `issues` so the view can re-filter from `.onReceive($issues)`.
@MainActor
final class WorkspaceStoreHandle: ObservableObject {
    @Published private(set) var store: WorkspaceStore? = nil
    @Published private(set) var issues: [BeadsIssue] = []
    private var subscriptions: [AnyCancellable] = []
    /// The attached path, readable from the nonisolated `deinit`.
    private final class AttachedPath: @unchecked Sendable { var value: String? }
    private let attachedPath = AttachedPath()

    /// Switches to the store for `path` (no-op if already attached to it). Ignores an empty
    /// path, which SwiftUI can briefly report before scene storage is restored.
    func attach(_ path: String) {
        guard !path.isEmpty, path != store?.path else { return }
        detach()
        let s = WorkspaceStoreRegistry.shared.acquire(path)
        store = s
        attachedPath.value = path
        subscriptions = [
            s.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            s.$issues.sink { [weak self] in self?.issues = $0 },   // emits the current value now
        ]
    }

    /// Releases the current store (window closed). Not driven by `.onDisappear`; see
    /// BeadsEventsWatcher.stop() for why.
    func detach() {
        subscriptions = []
        guard let s = store else { return }
        store = nil
        attachedPath.value = nil
        issues = []
        WorkspaceStoreRegistry.shared.release(s.path)
    }

    deinit {
        // Backstop if the window's view state is deallocated without a close notification.
        if let path = attachedPath.value {
            Task { @MainActor in WorkspaceStoreRegistry.shared.release(path) }
        }
    }
}
