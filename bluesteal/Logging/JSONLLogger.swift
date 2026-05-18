//
//  JSONLLogger.swift
//  bluesteal
//

import Foundation
import CoreBluetooth

/// Append-only JSONL writer for `~/Library/Logs/bluesteal/<yyyy-MM-dd>.jsonl`.
/// One line per detection. Shape is forward-compatible with the future
/// WebSocket relay phase — a tail-and-push loop is all that's needed.
///
/// Under the app sandbox, `NSHomeDirectory()` resolves to the container
/// `~/Library/Containers/<bundle-id>/Data`, so `Library/Logs/bluesteal`
/// inside there is writable without `com.apple.security.files.user-selected.*`.
final class JSONLLogger {
    private let directory: URL
    private let dateFormatter: ISO8601DateFormatter
    private let fileDateFormatter: DateFormatter

    init() {
        self.directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/bluesteal", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)

        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        self.fileDateFormatter = DateFormatter()
        self.fileDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        self.fileDateFormatter.dateFormat = "yyyy-MM-dd"
    }

    var currentLogFileURL: URL {
        directory.appendingPathComponent("\(fileDateFormatter.string(from: Date())).jsonl")
    }

    func append(event: RawAdvertEvent,
                uuid: CBUUID?,
                payload: Data,
                variant: AdvertVariant) {
        let record: [String: Any] = [
            "ts": dateFormatter.string(from: event.timestamp),
            "peer": event.peripheralID.uuidString,
            "rssi": event.rssi,
            "uuid": uuid?.uuidString as Any,
            "variant": variant.wireName,
            "payloadHex": payload.hexEncoded,
            "name": event.localName as Any,
            "manufacturerHex": event.manufacturerData?.hexEncoded as Any,
            "serviceUUIDs": event.advertisedServiceUUIDs.map { $0.uuidString },
            "txPower": event.txPowerLevel as Any,
            "isConnectable": event.isConnectable as Any
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: record,
                                                     options: [.sortedKeys]) else {
            return
        }
        let line = data + Data([0x0a])  // newline
        write(line)
    }

    private func write(_ line: Data) {
        let url = currentLogFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            }
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }
}
