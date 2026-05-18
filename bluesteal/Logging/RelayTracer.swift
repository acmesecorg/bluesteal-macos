//
//  RelayTracer.swift
//  bluesteal
//

import Foundation
import os.log

/// Append-only JSONL tracer for the WebRTC pairing pipeline.
///
/// One file per process per UTC date:
///   ~/Library/Application Support/bluesteal/Logs/relay-{yyyy-MM-dd}-{pid}.jsonl
///
/// Each line is a single JSON object with the shape:
///   { ts, pid, instanceId, role, code, category, event, data }
///
/// Mirrors `Bluesteal/Services/RelayTracer.cs` on the Windows port so the two
/// traces can be diffed line for line. Also echoes every record to `os_log`
/// (subsystem `bluesteal`, category `relay`) so Console.app shows the trace
/// live during a Debug build.
///
/// All IO happens on an internal serial queue — callers can log from any
/// thread (CoreBluetooth callbacks, CocoaMQTT delegate threads, the main
/// actor) without coordination, and a failing write never throws.
final class RelayTracer: @unchecked Sendable {
    /// Standard log directory under the sandbox container. Exposed so UI
    /// surfaces (e.g. an "Open logs" link) can find it without holding a
    /// reference to a live tracer instance.
    static var standardLogDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/bluesteal/Logs",
                                    isDirectory: true)
    }

    private let pid: Int32
    private let instanceId: String
    private let logURL: URL
    private let logDirectoryURL: URL
    private let queue = DispatchQueue(label: "bluesteal.relay.tracer", qos: .utility)
    private let logger = Logger(subsystem: "bluesteal", category: "relay")
    private let iso8601: ISO8601DateFormatter

    private var role: String = "none"
    private var code: String = ""

    init() {
        self.pid = getpid()
        self.instanceId = String(UUID().uuidString.prefix(8))

        // Under the app sandbox `NSHomeDirectory()` resolves to the container,
        // so `Library/Application Support/bluesteal/Logs` inside that container
        // is writable without any user-selected file entitlement.
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/bluesteal/Logs",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        self.logDirectoryURL = dir

        let fileDate = DateFormatter()
        fileDate.locale = Locale(identifier: "en_US_POSIX")
        fileDate.timeZone = TimeZone(identifier: "UTC")
        fileDate.dateFormat = "yyyy-MM-dd"
        self.logURL = dir.appendingPathComponent("relay-\(fileDate.string(from: Date()))-\(pid).jsonl")

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.iso8601 = iso
    }

    var logFileURL: URL { logURL }
    var logDirectory: URL { logDirectoryURL }
    var instance: String { instanceId }

    /// Sets the role + code fields that are stamped onto every subsequent
    /// record. Safe to call from any thread.
    func setContext(role: String, code: String) {
        queue.async {
            self.role = role
            self.code = code
        }
    }

    /// Append one record. `data` may be any JSON-serialisable dictionary
    /// (strings, numbers, bools, arrays, nested dicts, NSNull). Anything that
    /// `JSONSerialization` rejects is dropped silently — the tracer must
    /// never throw into production code paths.
    func log(_ category: String, _ event: String, _ data: [String: Any]? = nil) {
        let ts = iso8601.string(from: Date())
        let pid = self.pid
        let instanceId = self.instanceId
        let payload = data ?? [:]

        queue.async {
            var record: [String: Any] = [
                "ts": ts,
                "pid": Int(pid),
                "instanceId": instanceId,
                "role": self.role,
                "code": self.code,
                "category": category,
                "event": event
            ]
            if !payload.isEmpty { record["data"] = payload }

            guard JSONSerialization.isValidJSONObject(record),
                  let bytes = try? JSONSerialization.data(withJSONObject: record,
                                                          options: [.sortedKeys]),
                  let json = String(data: bytes, encoding: .utf8) else {
                self.logger.error("tracer: failed to encode \(category, privacy: .public).\(event, privacy: .public)")
                return
            }

            self.logger.log("[\(instanceId, privacy: .public) \(category, privacy: .public)] \(event, privacy: .public) \(json, privacy: .public)")

            let line = (json + "\n").data(using: .utf8) ?? Data()
            let path = self.logURL.path
            if FileManager.default.fileExists(atPath: path) {
                if let handle = try? FileHandle(forWritingTo: self.logURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: line)
                }
            } else {
                try? line.write(to: self.logURL, options: .atomic)
            }
        }
    }
}
