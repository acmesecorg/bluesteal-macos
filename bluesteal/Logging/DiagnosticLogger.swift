//
//  DiagnosticLogger.swift
//  bluesteal
//
//  One-purpose log writer used by the Diagnostic scan mode: dumps the *full*
//  CoreBluetooth advertisement dictionary for every nearby BLE peripheral, so
//  we can identify what wire format an external authenticator (e.g. native
//  iOS) puts on the air during a hybrid sign-in flow.
//
//  The output file lives next to the main JSONL log under
//      ~/Library/Logs/bluesteal/diag-<yyyy-MM-dd>-<pid>.jsonl
//  and is opened lazily on first write. Per-run PID suffix means each launch
//  starts a clean file even if multiple runs happen on the same day.
//

import Foundation
import CoreBluetooth

/// Append-only writer that captures full BLE advertisement dictionaries
/// for diagnostic purposes. Not used in the normal classify-and-forward
/// pipeline.
final class DiagnosticLogger {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "bluesteal.diagnostic.logger")
    private let dateFormatter: ISO8601DateFormatter

    /// In-memory dedup. Keyed by `peripheralID|payloadDigest` — keeps the file
    /// readable when an iPhone parks an iBeacon next to you. Window is short
    /// so changes to a peripheral's advert are still captured.
    private var lastEmit: [String: Date] = [:]
    private let dedupWindow: TimeInterval = 5.0

    init() {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/bluesteal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let pid = ProcessInfo.processInfo.processIdentifier
        self.fileURL = dir.appendingPathComponent("diag-\(fmt.string(from: Date()))-\(pid).jsonl")

        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    var logFileURL: URL { fileURL }

    /// Log one advertisement event. Called from the CoreBluetooth delegate
    /// callback on the main queue; the file write itself is dispatched to a
    /// background serial queue to keep the BLE thread responsive.
    func log(peripheralID: UUID,
             rssi: Int,
             advertisementData: [String: Any]) {
        let coerced = jsonSafe(advertisementData) as? [String: Any] ?? [:]
        let digest = coercedDigest(coerced)
        let key = "\(peripheralID.uuidString)|\(digest)"

        let now = Date()
        if let last = lastEmit[key], now.timeIntervalSince(last) < dedupWindow {
            return
        }
        lastEmit[key] = now

        var record: [String: Any] = [
            "ts": dateFormatter.string(from: now),
            "peer": peripheralID.uuidString,
            "rssi": rssi,
            "advert": coerced
        ]
        // Add a top-level hint when the advert contains a *non* short-form
        // service UUID — these are the prime suspects for EID-as-UUID
        // encoding by an iOS or macOS authenticator.
        if let uuids = coerced["kCBAdvDataServiceUUIDs"] as? [String] {
            let longForm = uuids.filter { $0.count > 8 }
            if !longForm.isEmpty {
                record["candidateEidUUIDs"] = longForm
            }
        }
        // Same hint for the iOS overflow area, where backgrounded apps' UUIDs
        // end up. The iOS authenticator daemon almost certainly emits in the
        // foreground area, but capture the overflow path too just in case.
        if let overflow = coerced["kCBAdvDataOverflowServiceUUIDs"] as? [String],
           !overflow.isEmpty {
            record["overflowUUIDs"] = overflow
        }

        guard let data = try? JSONSerialization.data(withJSONObject: record,
                                                     options: [.sortedKeys]) else {
            return
        }
        let line = data + Data([0x0a])
        queue.async { [fileURL] in
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: line)
                }
            } else {
                try? line.write(to: fileURL, options: .atomic)
            }
        }
    }

    // MARK: - JSON coercion

    /// Recursively convert a CoreBluetooth advertisement dictionary into a
    /// JSON-serialisable shape. The tricky values are `Data` (→ hex string),
    /// `CBUUID` (→ uppercase string), and the dictionary keyed by `CBUUID`
    /// returned for `kCBAdvDataServiceData` (→ string-keyed dict).
    private func jsonSafe(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = jsonSafe(v) }
            return out
        }
        if let dict = value as? [CBUUID: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k.uuidString] = jsonSafe(v) }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { jsonSafe($0) }
        }
        if let uuids = value as? [CBUUID] {
            return uuids.map { $0.uuidString }
        }
        if let uuid = value as? CBUUID {
            return uuid.uuidString
        }
        if let data = value as? Data {
            return data.hexEncoded
        }
        if let number = value as? NSNumber {
            return number
        }
        if let string = value as? String {
            return string
        }
        // Last-ditch — string-describe so the line still serialises.
        return String(describing: value)
    }

    private func coercedDigest(_ dict: [String: Any]) -> String {
        // Cheap stable digest: serialise with sorted keys and hash. Used only
        // for dedup so collisions across genuinely-different adverts are
        // acceptable as long as they're rare.
        guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                     options: [.sortedKeys]) else {
            return UUID().uuidString
        }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
