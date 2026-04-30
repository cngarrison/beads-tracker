// BeadsRunner.swift
// CLI interaction layer — all `bd` subprocess calls.

import AppKit

// MARK: - Beads Runner

enum BeadsRunner {

    // MARK: Create

    static func create(
        title: String, description: String, type: IssueType, priority: Priority,
        assignee: String, labels: String, externalRef: String,
        designNotes: String, acceptanceCriteria: String, dependencies: String,
        workingDirectory: String
    ) throws -> String {
        var args = ["bd", "create"]
        args += ["--title", title]
        args += ["--type", type.rawValue]
        args += ["--priority", priority.rawValue]
        if !description.isEmpty        { args += ["--description", description] }
        if !assignee.isEmpty           { args += ["--assignee", assignee] }
        if !labels.isEmpty             { args += ["--labels", labels] }
        if !externalRef.isEmpty        { args += ["--external-ref", externalRef] }
        if !designNotes.isEmpty        { args += ["--design", designNotes] }
        if !acceptanceCriteria.isEmpty { args += ["--acceptance", acceptanceCriteria] }
        if !dependencies.isEmpty       { args += ["--deps", dependencies] }

        let (stdout, stderr, status) = try run(args, in: workingDirectory)
        if status != 0 {
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BeadsError.commandFailed(msg.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : msg)
        }
        let combined = stdout + stderr
        let pat = #"Created issue:\s+(\S+)"#
        if let re = try? NSRegularExpression(pattern: pat),
           let m  = re.firstMatch(in: combined, range: NSRange(combined.startIndex..., in: combined)),
           let r  = Range(m.range(at: 1), in: combined) {
            return String(combined[r])
        }
        return "(created)"
    }

    // MARK: List

    /// Returns a progress stream (running issue count) and a background task resolving to the full issue tree.
    /// Consume the stream on the main actor to update UI, then await the task for the final result.
    static func listWithProgress(workingDirectory: String, extraArgs: [String] = []) -> (AsyncStream<Int>, Task<[BeadsIssue], Error>) {
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let bgTask = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            return try BeadsRunner.listInternal(workingDirectory: workingDirectory, extraArgs: extraArgs) { count in
                continuation.yield(count)
            }
        }
        return (stream, bgTask)
    }

    private static func listInternal(workingDirectory: String, extraArgs: [String] = [], onProgress: @escaping (Int) -> Void) throws -> [BeadsIssue] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["bd", "list"] + extraArgs + ["--json", "--limit", "0"]
        p.environment = pathHelperEnvironment()
        if !workingDirectory.isEmpty { p.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError  = err

        // Read stdout in chunks via readabilityHandler, counting issue objects as they arrive.
        // Each issue in `bd list --json` output has exactly one top-level "id": key.
        var stdoutData = Data()
        var issueCount = 0
        let stdoutDone = DispatchSemaphore(value: 0)
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                stdoutDone.signal()
                return
            }
            stdoutData.append(chunk)
            if let s = String(data: chunk, encoding: .utf8) {
                let delta = s.components(separatedBy: "\"id\":").count - 1
                if delta > 0 { issueCount += delta; onProgress(issueCount) }
            }
        }

        // Read stderr concurrently to prevent pipe-buffer deadlock.
        var stderrData = Data()
        let stderrDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            stderrData = err.fileHandleForReading.readDataToEndOfFile()
            stderrDone.signal()
        }

        try p.run()
        stdoutDone.wait()
        p.waitUntilExit()
        stderrDone.wait()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            var msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 127 || msg.contains("command not found") {
                msg = enrichCommandNotFound(msg)
            }
            throw BeadsError.commandFailed(msg.isEmpty ? stdout : msg)
        }
        return try buildTree(from: stdout)
    }

    // MARK: Show (plain text — used by IssueDetailSheet)

    static func show(id: String, workingDirectory: String) throws -> String {
        let (stdout, stderr, status) = try run(["bd", "show", id], in: workingDirectory)
        if status != 0 {
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BeadsError.commandFailed(msg.isEmpty ? stdout : msg)
        }
        return stdout
    }

    // MARK: Show Detail (JSON — used by IssueEditSheet for pre-populating the form)

    static func showDetail(id: String, workingDirectory: String) throws -> BeadsIssueDetail {
        let (stdout, stderr, status) = try run(["bd", "show", "--json", id], in: workingDirectory)
        if status != 0 {
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BeadsError.commandFailed(msg.isEmpty ? stdout : msg)
        }
        let results = try JSONDecoder().decode([BeadsIssueDetail].self, from: Data(stdout.utf8))
        guard let first = results.first else {
            throw BeadsError.commandFailed("No detail returned for issue \(id)")
        }
        return first
    }

    // MARK: Update

    /// Update an issue.  `original` is the field state when the form was first loaded;
    /// any field that was non-empty originally but is now empty will be explicitly cleared
    /// by passing the flag with an empty string.
    static func update(id: String, fields: IssueFormFields, original: IssueFormFields = IssueFormFields(), workingDirectory: String) throws {
        var args = ["bd", "update", id]
        // Title is always passed (required field)
        args += ["--title", fields.title]
        // Type and priority are always sent (pickers always have a value)
        args += ["--type", fields.issueType.rawValue]
        args += ["--priority", fields.priority.rawValue]

        // Helper: pass a flag when the field is non-empty (set/update) OR was originally
        // non-empty but is now empty (explicit clear).  Fields that were always empty are
        // omitted so we don't accidentally blank data that was never loaded into the form.
        func shouldPass(_ current: String, _ orig: String) -> Bool {
            !current.isEmpty || !orig.isEmpty
        }

        if shouldPass(fields.description,        original.description)        { args += ["--description", fields.description] }
        if shouldPass(fields.assignee,            original.assignee)            { args += ["--assignee",     fields.assignee] }
        if shouldPass(fields.designNotes,         original.designNotes)         { args += ["--design",       fields.designNotes] }
        if shouldPass(fields.acceptanceCriteria,  original.acceptanceCriteria)  { args += ["--acceptance",   fields.acceptanceCriteria] }
        if shouldPass(fields.notes,               original.notes)               { args += ["--notes",        fields.notes] }
        // Labels — split on comma, trim whitespace, pass each with --set-labels.
        // Pass the flag (even empty) when labels were originally set, so clearing them works.
        if shouldPass(fields.labels, original.labels) {
            let labelList = fields.labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for label in labelList {
                args += ["--set-labels", label]
            }
        }
        // Note: --external-ref and --deps are intentionally omitted since
        // we cannot pre-populate them from the JSON response and would wipe existing data.

        let (stdout, stderr, status) = try run(args, in: workingDirectory)
        if status != 0 {
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BeadsError.commandFailed(msg.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : msg)
        }
    }

    // MARK: Add Comment

    static func addComment(id: String, text: String, workingDirectory: String) throws {
        let (stdout, stderr, status) = try run(["bd", "comments", "add", id, text], in: workingDirectory)
        if status != 0 {
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BeadsError.commandFailed(msg.isEmpty ? stdout : msg)
        }
    }

    // MARK: Add Dependency

    static func addDependency(issueID: String, depID: String, type depType: String, workingDirectory: String) throws {
        var args = ["bd", "link", issueID, depID]
        if !depType.isEmpty && depType != "blocks" { args += ["--type", depType] }
        let (stdout, stderr, status) = try run(args, in: workingDirectory)
        if status != 0 {
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BeadsError.commandFailed(msg.isEmpty ? stdout : msg)
        }
    }

    // MARK: Remove Dependency

    static func removeDependency(issueID: String, depID: String, workingDirectory: String) throws {
        let (stdout, stderr, status) = try run(["bd", "dep", "remove", issueID, depID], in: workingDirectory)
        if status != 0 {
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BeadsError.commandFailed(msg.isEmpty ? stdout : msg)
        }
    }

    // MARK: Claim

    static func claim(id: String, workingDirectory: String) throws {
        let (stdout, stderr, status) = try run(["bd", "update", id, "--claim"], in: workingDirectory)
        if status != 0 {
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BeadsError.commandFailed(msg.isEmpty ? stdout : msg)
        }
    }

    // MARK: Close

    static func close(id: String, workingDirectory: String) throws {
        let (stdout, stderr, status) = try run(["bd", "close", id], in: workingDirectory)
        if status != 0 {
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BeadsError.commandFailed(msg.isEmpty ? stdout : msg)
        }
    }

    // MARK: Parse (JSON → tree)

    private static func buildTree(from json: String) throws -> [BeadsIssue] {
        struct RawIssue: Decodable {
            let id: String
            let title: String
            let status: String
            let priority: Int
            let issueType: String?
            let parent: String?
            let dependencyCount: Int?
            let dependentCount:  Int?
            enum CodingKeys: String, CodingKey {
                case id, title, status, priority, parent
                case issueType = "issue_type"
                case dependencyCount = "dependency_count"
                case dependentCount  = "dependent_count"
            }
        }

        let raw = try JSONDecoder().decode([RawIssue].self, from: Data(json.utf8))

        // Build flat map and child index
        var nodeMap: [String: BeadsIssue] = [:]
        var childIndex: [String: [String]] = [:]   // parentID → [childID]
        for r in raw {
            nodeMap[r.id] = BeadsIssue(id: r.id, title: r.title, status: r.status,
                                       priority: r.priority, issueType: r.issueType,
                                       parentID: r.parent,
                                       dependencyCount: r.dependencyCount ?? 0,
                                       dependentCount:  r.dependentCount  ?? 0,
                                       children: nil)
            if let p = r.parent { childIndex[p, default: []].append(r.id) }
        }

        // Recursively attach children
        func build(_ id: String) -> BeadsIssue? {
            guard var node = nodeMap[id] else { return nil }
            let kids = childIndex[id] ?? []
            if !kids.isEmpty { node.children = kids.compactMap { build($0) } }
            return node
        }

        // Roots: no parent, or parent not present in this result set
        let rootIDs = raw.filter { r in
            guard let p = r.parent else { return true }
            return nodeMap[p] == nil   // orphan → promote to root
        }.map { $0.id }

        return rootIDs.compactMap { build($0) }
    }

    // MARK: Process helper

    /// Detects the Homebrew bin directory on this machine (works on both Intel and Apple Silicon).
    private static func brewBinPath() -> String? {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin"]   // Apple Silicon first
        return candidates.first { FileManager.default.fileExists(atPath: "\($0)/brew") }
    }

    /// Builds a PATH that includes entries from /etc/paths and /etc/paths.d/*, replicating
    /// what path_helper does for login shells — without needing to spawn one.
    private static func pathHelperEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var dirs: [String] = []

        if let s = try? String(contentsOfFile: "/etc/paths", encoding: .utf8) {
            dirs += s.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }
        if let files = try? FileManager.default.contentsOfDirectory(atPath: "/etc/paths.d") {
            for f in files.sorted() {
                if let s = try? String(contentsOfFile: "/etc/paths.d/\(f)", encoding: .utf8) {
                    dirs += s.components(separatedBy: .newlines).filter { !$0.isEmpty }
                }
            }
        }
        // Append any PATH already in the environment (lowest priority).
        dirs += (env["PATH"] ?? "").components(separatedBy: ":").filter { !$0.isEmpty }

        // Deduplicate, preserving order.
        var seen = Set<String>()
        env["PATH"] = dirs.filter { seen.insert($0).inserted }.joined(separator: ":")
        return env
    }

    /// Wraps a raw stderr/stdout message with setup instructions when `bd` cannot be found.
    private static func enrichCommandNotFound(_ message: String) -> String {
        guard message.contains("command not found") || message.contains("No such file or directory") else {
            return message
        }
        let brewBin = brewBinPath() ?? "/opt/homebrew/bin"
        return """
        \(message)

        'bd' was not found in PATH. Run this once in Terminal, then restart the app:

          echo '\(brewBin)' | sudo tee /etc/paths.d/homebrew
        """
    }

    private static func run(_ args: [String], in directory: String) throws -> (String, String, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.environment = pathHelperEnvironment()
        if !directory.isEmpty { p.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError  = err
        try p.run()
        // Read stderr concurrently to prevent pipe-buffer deadlock on large output.
        var stderrData = Data()
        let stderrDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            stderrData = err.fileHandleForReading.readDataToEndOfFile()
            stderrDone.signal()
        }
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        stderrDone.wait()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        var stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if p.terminationStatus == 127 || stderr.contains("command not found") {
            stderr = enrichCommandNotFound(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (stdout, stderr, p.terminationStatus)
    }
}
