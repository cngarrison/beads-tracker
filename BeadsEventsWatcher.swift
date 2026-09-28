// BeadsEventsWatcher.swift
// Owns the lifecycle of a `bd events tail --follow` subprocess for one open
// workspace: enables the events journal, streams JSON-lines output, debounces
// event bursts into a single refresh signal, tracks per-workspace checkpoints,
// and exposes a Live/Manual health flag + one-time "Live updates enabled" toast.

import Foundation
import AppKit

// MARK: - Event record decoding

/// Minimal decode of a `bd events tail` JSON-line record. v1 only uses events
// as refresh signals (see design point 4) so we don't decode the nested
/// issue/dep/comment payloads.
private struct EventRecord: Decodable {
    let seq: Int
    let op: String
}

/// Shape of the JSON error line emitted when the requested `--since` checkpoint
/// has been pruned from the journal (retention exceeded).
private struct EventsTruncationError: Decodable {
    let code: String
    let error: String?
    let floor: Int?
    let head: Int?
    let since: Int?
}

// MARK: - BeadsEventsWatcher

/// One instance per open workspace/window. Create as a `@StateObject` in the
/// view that owns `workingDirectory` (IssueListView) so its lifetime tracks
/// the view's lifetime.
@MainActor
final class BeadsEventsWatcher: ObservableObject {
    /// True when the tail process for the current workspace is running and healthy.
    @Published private(set) var isLive: Bool = false
    /// Transient toast/banner text (nil = no toast currently shown).
    @Published var toastMessage: String? = nil

    private var process: Process?
    private var stdoutBuffer = Data()
    private var workingDirectory: String = ""
    private var intentionallyStopped = false
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 3
    private var debounceWorkItem: DispatchWorkItem?
    private var onRefreshNeeded: (() -> Void)?

    /// Workspace paths already shown the "Live updates enabled" toast this app launch.
    /// In-memory only (not persisted), shared across all watcher instances/windows,
    /// so it's tracked once per launch rather than once per window.
    private static var notifiedWorkspaces = Set<String>()

    private static let checkpointsKey = "eventsCheckpoints"

    // MARK: Checkpoint persistence (UserDefaults dictionary keyed by workspace path)

    private static func checkpoint(for path: String) -> Int? {
        let dict = UserDefaults.standard.dictionary(forKey: checkpointsKey) as? [String: Int]
        return dict?[path]
    }

    private static func setCheckpoint(_ seq: Int, for path: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: checkpointsKey) as? [String: Int]) ?? [:]
        dict[path] = seq
        UserDefaults.standard.set(dict, forKey: checkpointsKey)
    }

    // MARK: Lifecycle

    /// Enable the events journal (fire-and-forget; failure is swallowed since the
    /// fallback path below handles it) and start tailing for the given workspace.
    func start(workingDirectory: String, onRefreshNeeded: @escaping () -> Void) {
        stop()  // tear down any previous process (different workspace / restart)
        guard !workingDirectory.isEmpty else { return }
        self.workingDirectory = workingDirectory
        self.onRefreshNeeded = onRefreshNeeded
        self.intentionallyStopped = false
        self.consecutiveFailures = 0

        Task.detached(priority: .utility) {
            try? BeadsRunner.enableEventsJournal(workingDirectory: workingDirectory)
            await self.beginTailing()
        }
    }

    /// Terminate the tail process (SIGTERM) and stop retrying. Call on workspace
    /// change or view teardown to avoid leaking subprocesses.
    func stop() {
        intentionallyStopped = true
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        isLive = false
    }

    // MARK: Tailing

    private func beginTailing() async {
        guard !intentionallyStopped else { return }
        let dir = workingDirectory
        // TODO(shortcut): when there's no stored checkpoint yet for this workspace, we
        // start from --since 0 and simply coalesce the (potentially large) history-replay
        // burst into a single harmless refresh, rather than first issuing a separate
        // "peek current head" call. This is an accepted v1 simplification (no cheap
        // "get current head without --follow" command was assumed available) — the app
        // already does one `bd list` on open today anyway, so the extra refresh is not
        // harmful, just occasionally redundant.
        let since = Self.checkpoint(for: dir) ?? 0
        spawnTailProcess(since: since)
    }

    private func spawnTailProcess(since: Int) {
        guard !intentionallyStopped else { return }
        let dir = workingDirectory
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["bd", "events", "tail", "--since", String(since), "--follow"]
        p.environment = BeadsRunner.pathHelperEnvironment()
        if !dir.isEmpty { p.currentDirectoryURL = URL(fileURLWithPath: dir) }

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        stdoutBuffer = Data()

        // Stream stdout incrementally (unlike other BeadsRunner calls which wait for
        // full completion) since --follow never terminates on its own.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in
                self?.consumeChunk(chunk)
            }
        }
        // Drain stderr so the pipe buffer never blocks the process; content is not
        // otherwise inspected (truncation is detected via stdout JSON error lines).
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.handleProcessTermination(status: proc.terminationStatus)
            }
        }

        do {
            try p.run()
            process = p
            isLive = true
            consecutiveFailures = 0
            maybeShowFirstEnableToast()
        } catch {
            process = nil
            isLive = false
            registerFailureAndMaybeRetry()
        }
    }

    private func consumeChunk(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        // Split on newlines; keep any trailing partial line buffered until it completes.
        while let range = stdoutBuffer.range(of: Data([0x0A])) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<range.upperBound)
            guard let line = String(data: lineData, encoding: .utf8),
                  !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        let data = Data(line.utf8)

        // Truncation error takes priority — distinctive "code" field.
        if let trunc = try? JSONDecoder().decode(EventsTruncationError.self, from: data),
           trunc.code == "events_journal_truncated" {
            handleTruncation(trunc)
            return
        }

        guard let record = try? JSONDecoder().decode(EventRecord.self, from: data) else { return }
        Self.setCheckpoint(record.seq, for: workingDirectory)
        scheduleDebouncedRefresh()
    }

    private func handleTruncation(_ trunc: EventsTruncationError) {
        showToast("Reconnected \u{2014} refreshing workspace")
        onRefreshNeeded?()

        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        isLive = false

        if let head = trunc.head {
            // Resume following from the reported head rather than replaying full history.
            Self.setCheckpoint(head, for: workingDirectory)
            spawnTailProcess(since: head)
        } else {
            // No reliable head value in the payload — fall back to manual-refresh mode
            // for this workspace session (today's existing behavior).
            intentionallyStopped = true
        }
    }

    private func handleProcessTermination(status: Int32) {
        guard !intentionallyStopped else { return }
        isLive = false
        registerFailureAndMaybeRetry()
    }

    private func registerFailureAndMaybeRetry() {
        consecutiveFailures += 1
        guard consecutiveFailures <= maxConsecutiveFailures else {
            // Give up for this workspace session — fall back to manual-refresh mode.
            intentionallyStopped = true
            return
        }
        let delay = Double(consecutiveFailures) * 1.5
        let dir = workingDirectory
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.workingDirectory == dir, !self.intentionallyStopped else { return }
            let since = Self.checkpoint(for: dir) ?? 0
            self.spawnTailProcess(since: since)
        }
    }

    private func scheduleDebouncedRefresh() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onRefreshNeeded?()
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func maybeShowFirstEnableToast() {
        let dir = workingDirectory
        guard !Self.notifiedWorkspaces.contains(dir) else { return }
        Self.notifiedWorkspaces.insert(dir)
        showToast("Live updates enabled for this workspace.")
    }

    private func showToast(_ message: String) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.toastMessage == message { self?.toastMessage = nil }
        }
    }
}
