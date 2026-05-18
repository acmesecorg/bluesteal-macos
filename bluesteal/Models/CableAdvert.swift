//
//  CableAdvert.swift
//  bluesteal
//

import Foundation
import CoreBluetooth

/// One deduplicated record of an observed caBLE service-data advertisement.
/// Identity is `(peripheralID, payloadHex)` — the same payload re-emitted by the
/// same peripheral is folded into a single row, with `count` and `lastSeen` bumped.
struct CableAdvert: Identifiable, Equatable {
    let id: String                    // "\(peripheralID)|\(payloadHex)"
    let peripheralID: UUID
    let serviceUUID: CBUUID?          // FFF9 or FDE2; nil for manufacturer-data adverts
    let payload: Data                 // raw service-data bytes
    let variant: AdvertVariant
    let firstSeen: Date
    var lastSeen: Date
    var count: Int
    var rssi: Int                     // most-recent
    let localName: String?
    let advertisedServiceUUIDs: [CBUUID]
    let manufacturerData: Data?
    let txPowerLevel: Int?
    let isConnectable: Bool?

    var payloadHex: String { payload.hexEncoded }
    var manufacturerHex: String? { manufacturerData?.hexEncoded }

    static func makeID(peripheralID: UUID, payloadHex: String) -> String {
        "\(peripheralID.uuidString)|\(payloadHex)"
    }
}

extension Data {
    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
