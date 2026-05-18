//
//  AdvertStore.swift
//  bluesteal
//

import Foundation
import CoreBluetooth
import Observation

/// Aggregates raw scanner events into a deduped, ordered list of `CableAdvert`s
/// and appends every detection to the JSONL log.
@Observable
final class AdvertStore {
    private(set) var adverts: [CableAdvert] = []
    private(set) var totalDetections: Int = 0
    private var index: [String: Int] = [:]   // CableAdvert.id -> array index

    private let logger: JSONLLogger

    /// Called for every fresh-or-updated advert after the store mutates. The
    /// relay bridge uses this to forward live state to a paired instance
    /// without polling.
    var onIngest: ((CableAdvert) -> Void)?

    init(logger: JSONLLogger) {
        self.logger = logger
    }

    func ingest(_ event: RawAdvertEvent) {
        // Service-data path: one row per caBLE service-data entry (FFF9 / FDE2).
        for (uuid, payload) in event.serviceData where AdvertClassifier.isCableUUID(uuid) {
            let variant = AdvertClassifier.classify(uuid: uuid, payload: payload)
            upsert(payload: payload, variant: variant, serviceUUID: uuid, event: event)
        }

        // Manufacturer-data path: Google caBLE v1 advert under company ID 0x00E0.
        if let mfgData = event.manufacturerData,
           let (variant, eid) = AdvertClassifier.classifyManufacturerData(mfgData) {
            upsert(payload: eid, variant: variant, serviceUUID: nil, event: event)
        }
    }

    private func upsert(payload: Data,
                        variant: AdvertVariant,
                        serviceUUID: CBUUID?,
                        event: RawAdvertEvent) {
        let payloadHex = payload.hexEncoded
        let id = CableAdvert.makeID(peripheralID: event.peripheralID,
                                    payloadHex: payloadHex)
        totalDetections += 1

        let emitted: CableAdvert
        if let idx = index[id] {
            adverts[idx].lastSeen = event.timestamp
            adverts[idx].count += 1
            adverts[idx].rssi = event.rssi
            emitted = adverts[idx]
        } else {
            let advert = CableAdvert(
                id: id,
                peripheralID: event.peripheralID,
                serviceUUID: serviceUUID,
                payload: payload,
                variant: variant,
                firstSeen: event.timestamp,
                lastSeen: event.timestamp,
                count: 1,
                rssi: event.rssi,
                localName: event.localName,
                advertisedServiceUUIDs: event.advertisedServiceUUIDs,
                manufacturerData: event.manufacturerData,
                txPowerLevel: event.txPowerLevel,
                isConnectable: event.isConnectable
            )
            adverts.insert(advert, at: 0)
            rebuildIndex()
            emitted = advert
        }

        logger.append(event: event, uuid: serviceUUID, payload: payload, variant: variant)
        onIngest?(emitted)
    }

    func clear() {
        adverts.removeAll()
        index.removeAll()
        totalDetections = 0
    }

    private func rebuildIndex() {
        index.removeAll(keepingCapacity: true)
        for (i, a) in adverts.enumerated() {
            index[a.id] = i
        }
    }
}
