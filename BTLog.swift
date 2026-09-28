// BTLog.swift
// Minimal file-based diagnostic logger. Because the app is normally launched via
// `open` (see Makefile `run:` target), plain print()/stdout/stderr output is not
// visible anywhere — there's no attached Terminal to receive it. This writes
// timestamped lines to a plain log file instead, so it can be reviewed with
// `tail -f ~/Library/Logs/BeadsTracker/beads-tracker.log` while testing.

import Foundation

enum BTLog {
    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BeadsTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("beads-tracker.log")
    }()

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Append a timestamped line to the diagnostic log file. Safe to call from any
    /// thread/actor; failures to write are silently ignored (logging must never crash
    /// or block the app).
    static func log(_ message: String, category: String = "general") {
        let line = "\(formatter.string(from: Date())) [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: logURL)
        }
    }
}
