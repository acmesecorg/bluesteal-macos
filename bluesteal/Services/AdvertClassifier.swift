//
//  AdvertClassifier.swift
//  bluesteal
//

import Foundation
import CoreBluetooth

/// Pure classification: given a service-data UUID and its raw bytes, return the
/// caBLE variant. Mirrors the dispatch in Chromium `fido_cable_discovery.cc`:
///
/// - GoogleCableUUID (0xFDE2): if `service_data[0] >> 5 & 1` is set, treat as v1
///   with an 18-byte `[flags, version, EID16]` payload; if 20 bytes, treat as v2.
/// - FIDOCableUUID  (0xFFF9): 20-byte v2 payload (`AES-ECB(EID) ‖ HMAC[:4]`),
///   per CTAP 2.2 hybrid §11 and `v2_constants.h` (`kAdvertSize = 16+4`).
nonisolated enum AdvertClassifier {
    static let fidoCableUUID = CBUUID(string: "FFF9")
    static let googleCableUUID = CBUUID(string: "FDE2")

    static let cableUUIDs: [CBUUID] = [fidoCableUUID, googleCableUUID]

    static func isCableUUID(_ uuid: CBUUID) -> Bool {
        uuid == fidoCableUUID || uuid == googleCableUUID
    }

    static func classify(uuid: CBUUID, payload: Data) -> AdvertVariant {
        let n = payload.count
        if uuid == fidoCableUUID {
            return n == 20 ? .fidoV2 : .unknown(reason: "fff9 len=\(n)")
        }
        if uuid == googleCableUUID {
            if n == 18, let first = payload.first, (first >> 5) & 1 == 1 {
                return .googleV1
            }
            if n == 20 {
                return .googleV2
            }
            return .unknown(reason: "fde2 len=\(n)")
        }
        return .unknown(reason: "non-cable uuid \(uuid.uuidString)")
    }
}
