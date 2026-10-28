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

// MARK: - Process registry

/// App-wide record of every live `bd events tail` process, so they can all be
/// terminated on app quit (`AppDelegate.applicationWillTerminate`) — `deinit` never
/// runs at quit, which left tail processes running after the app exited (bt-elk).
/// Lock-protected rather than MainActor-isolated so `deinit` can unregister too.
final class TailProcessRegistry: @unchecked Sendable {
    static let shared = TailProcessRegistry()
    private let lock = NSLock()
    private var processes: [String: Process] = [:]

    func register(_ process: Process, for owner: String) {
        lock.lock(); defer { lock.unlock() }
        processes[owner] = process
    }

    func unregister(_ owner: String) {
        lock.lock(); defer { lock.unlock() }
        processes[owner] = nil
    }

    func terminateAll() {
        lock.lock()
        let all = processes
        processes = [:]
        lock.unlock()
        for (owner, p) in all where p.isRunning {
            BTLog.log("[\(owner)] terminateAll: terminating pid=\(p.processIdentifier)", category: "events")
            p.terminationHandler = nil
            p.terminate()
        }
    }
}

/// Resumes a continuation exactly once, whichever of several racing tasks gets there first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    /// Returns true if this call was the one that resumed.
    @discardableResult
    func resume() -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
        return c != nil
    }
}

// MARK: - BeadsEventsWatcher

/// One instance per open workspace/window. Create as a `@StateObject` in the
/// view that owns `workingDirectory` (IssueListView) so its lifetime tracks
/// the view's lifetime.
@MainActor
final class BeadsEventsWatcher: ObservableObject {
    /// Short unique ID for this instance, included in all log lines so multiple
    /// windows/instances can be distinguished when their logs interleave in the
    /// shared diagnostic log file.
    private let instanceID = String(UUID().uuidString.prefix(8))
    /// True when the tail process for the current workspace is running and healthy.
    @Published private(set) var isLive: Bool = false
    /// Transient toast/banner text (nil = no toast currently shown).
    @Published var toastMessage: String? = nil

    private var process: Process?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var workingDirectory: String = ""
    private var intentionallyStopped = false
    /// Bumped by every start()/stop(). Async work (journal enable, retries) captures the
    /// value it was started under and bails if it no longer matches, so an in-flight
    /// start() superseded by a newer one can't spawn a second, orphaned tail process.
    private var generation = 0
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
        // Check for an empty workspace path BEFORE tearing anything down. Diagnosed:
        // a spurious re-invocation of start() with an empty workingDirectory (e.g. from
        // a transient/stale value briefly reported by the caller) was previously calling
        // stop() unconditionally first, silently killing an already-running healthy
        // watcher, then bailing out via this guard without restarting it — root cause of
        // the app always launching in "Manual" mode. Guarding first makes this immune to
        // spurious empty-path calls regardless of their origin.
        guard !workingDirectory.isEmpty else { return }
        stop()  // tear down any previous process (different workspace / restart)
        self.workingDirectory = workingDirectory
        self.onRefreshNeeded = onRefreshNeeded
        self.intentionallyStopped = false
        self.consecutiveFailures = 0
        let gen = generation

        BTLog.log("[\(instanceID)] start() workingDirectory=\(workingDirectory)", category: "events")
        let id = instanceID
        Task.detached(priority: .utility) {
            // NOTE: `BeadsRunner.enableEventsJournal` uses a *blocking* stdout read
            // (`readDataToEndOfFile()`) under the hood. If the underlying `bd` command
            // triggers Dolt's `dolt.auto-start` to spin up a background/daemon server
            // process that inherits our pipe's write-end file descriptor, that read can
            // block forever (the pipe never sees EOF while the daemon keeps it open) —
            // this exact scenario was diagnosed as the root cause of the watcher getting
            // permanently stuck before ever reaching beginTailing(). Race it against a
            // timeout so a hang here can never block real-time sync from starting.
            //
            // Both racers are unstructured tasks resuming a shared continuation: a task
            // group can't be used here because withTaskGroup waits for every child before
            // returning (cancelAll() can't interrupt a blocking read), which made the
            // timeout ineffective.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let once = ResumeOnce(cont)
                Task.detached(priority: .utility) {
                    do {
                        try BeadsRunner.enableEventsJournal(workingDirectory: workingDirectory)
                        BTLog.log("[\(id)] enableEventsJournal OK", category: "events")
                    } catch {
                        BTLog.log("[\(id)] enableEventsJournal FAILED: \(error)", category: "events")
                    }
                    once.resume()
                }
                Task.detached(priority: .utility) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if once.resume() {   // false if the real call already finished
                        BTLog.log("[\(id)] enableEventsJournal TIMED OUT after 5s — proceeding to tail anyway (see BTLog.swift doc comment / memory notes on pipe-deadlock root cause)", category: "events")
                    }
                }
            }
            await self.beginTailing(generation: gen)
        }
    }

    /// Terminate the tail process (SIGTERM) and stop retrying. Call on workspace
    /// change (start() calls this internally to tear down the previous workspace's
    /// process) to avoid leaking subprocesses.
    ///
    /// NOT called from `.onDisappear` — SwiftUI can fire that on a transient view
    /// teardown/recreate during initial layout, which would poison this persisted
    /// @StateObject before its in-flight `start()` ever completes (diagnosed root
    /// cause of the app always launching in "Manual" mode). True end-of-life cleanup
    /// is instead handled by `deinit` below, which only fires on real deallocation,
    /// and by IssueListView's window-close observer, which calls stop() directly.
    func stop() {
        BTLog.log("[\(instanceID)] stop() called, workingDirectory=\(workingDirectory)", category: "events")
        intentionallyStopped = true
        generation += 1
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        terminateProcess()
        isLive = false
    }

    deinit {
        // Best-effort process cleanup on true deallocation only (see stop() doc comment
        // above for why this isn't done via .onDisappear). Not actor-isolated; avoid
        // touching @Published/MainActor-isolated state here.
        process?.terminationHandler = nil
        process?.terminate()
        TailProcessRegistry.shared.unregister(instanceID)
    }

    private func terminateProcess() {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        TailProcessRegistry.shared.unregister(instanceID)
    }

    // MARK: Tailing

    private func beginTailing(generation gen: Int) async {
        guard !intentionallyStopped, gen == generation else {
            BTLog.log("[\(instanceID)] beginTailing: bailing early, intentionallyStopped=\(intentionallyStopped) generation \(gen) vs \(generation) (stopped or superseded)", category: "events")
            return
        }
        let dir = workingDirectory
        // TODO(shortcut): when there's no stored checkpoint yet for this workspace, we
        // start from --since 0 and simply coalesce the (potentially large) history-replay
        // burst into a single harmless refresh, rather than first issuing a separate
        // "peek current head" call. This is an accepted v1 simplification (no cheap
        // "get current head without --follow" command was assumed available) — the app
        // already does one `bd list` on open today anyway, so the extra refresh is not
        // harmful, just occasionally redundant.
        let since = Self.checkpoint(for: dir) ?? 0
        BTLog.log("[\(instanceID)] beginTailing dir=\(dir) since=\(since)", category: "events")
        spawnTailProcess(since: since)
    }

    private func spawnTailProcess(since: Int) {
        guard !intentionallyStopped else { return }
        // Never let a previous process be overwritten (and so orphaned) by a new one.
        terminateProcess()
        let dir = workingDirectory
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["bd", "events", "tail", "--since", String(since), "--follow"]
        p.environment = BeadsRunner.pathHelperEnvironment()
        if !dir.isEmpty { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
        BTLog.log("[\(instanceID)] spawnTailProcess args=\(p.arguments ?? []) dir=\(dir)", category: "events")

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        stdoutBuffer = Data()
        stderrBuffer = Data()

        // Stream stdout incrementally (unlike other BeadsRunner calls which wait for
        // full completion) since --follow never terminates on its own.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            Task { @MainActor in
                self.consumeChunk(chunk)
            }
        }
        // Accumulate stderr (previously drained/discarded) so we can log it if the
        // process exits unexpectedly — this is our main diagnostic signal for spawn
        // failures that aren't visible any other way (see BTLog.swift doc comment).
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            Task { @MainActor in self.stderrBuffer.append(chunk) }
        }

        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            Task { @MainActor in
                self.handleProcessTermination(status: proc.terminationStatus)
            }
        }

        do {
            try p.run()
            process = p
            TailProcessRegistry.shared.register(p, for: instanceID)
            isLive = true
            consecutiveFailures = 0
            BTLog.log("spawnTailProcess OK pid=\(p.processIdentifier)", category: "events")
            maybeShowFirstEnableToast()
        } catch {
            process = nil
            isLive = false
            BTLog.log("spawnTailProcess THREW: \(error)", category: "events")
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

        guard let record = try? JSONDecoder().decode(EventRecord.self, from: data) else {
            BTLog.log("handleLine: failed to decode as EventRecord or truncation error, raw line: \(line)", category: "events")
            return
        }
        Self.setCheckpoint(record.seq, for: workingDirectory)
        scheduleDebouncedRefresh()
    }

    private func handleTruncation(_ trunc: EventsTruncationError) {
        showToast("Reconnected \u{2014} refreshing workspace")
        onRefreshNeeded?()

        terminateProcess()
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
        let stderrText = String(data: stderrBuffer, encoding: .utf8) ?? "<undecodable>"
        BTLog.log("process terminated status=\(status) intentionallyStopped=\(intentionallyStopped) stderr=\(stderrText.isEmpty ? "<empty>" : stderrText)", category: "events")
        guard !intentionallyStopped else { return }
        process = nil
        TailProcessRegistry.shared.unregister(instanceID)
        isLive = false
        registerFailureAndMaybeRetry()
    }

    private func registerFailureAndMaybeRetry() {
        consecutiveFailures += 1
        BTLog.log("registerFailureAndMaybeRetry consecutiveFailures=\(consecutiveFailures)/\(maxConsecutiveFailures)", category: "events")
        guard consecutiveFailures <= maxConsecutiveFailures else {
            // Give up for this workspace session — fall back to manual-refresh mode.
            BTLog.log("giving up permanently for this session (workingDirectory=\(workingDirectory))", category: "events")
            intentionallyStopped = true
            return
        }
        let delay = Double(consecutiveFailures) * 1.5
        let dir = workingDirectory
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.workingDirectory == dir, self.generation == gen, !self.intentionallyStopped else { return }
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
