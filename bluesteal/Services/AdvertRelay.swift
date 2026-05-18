//
//  AdvertRelay.swift
//  bluesteal
//
//  Bridges the local AdvertStore with a paired RelayClient. The host pushes
//  every deduped CableAdvert to the peer; the peer mirrors them into a
//  receive-side list so the existing AdvertRowView can render them with
//  zero changes.
//

import Foundation
import CoreBluetooth
import Observation

@MainActor
@Observable
final class AdvertRelay {
    /// Adverts received from the paired host, newest-first.
    private(set) var received: [CableAdvert] = []

    /// Heartbeat-driven aging: last time the host claimed it was still seeing
    /// adverts. Not used to drop entries yet; surfaced for the UI later.
    private(set) var lastHostHeartbeat: Date?

    private var receivedIndex: [String: Int] = [:]

    private let store: AdvertStore
    private let relay: RelayClient

    private var heartbeatTask: Task<Void, Never>?

    /// Called for every local advert just before it's sent to the peer.
    /// Mirrors Windows's `AdvertStore.OnIngest` subscription path —
    /// secondary observers (e.g. `DuplicatePayloadDetector`) hang off this
    /// rather than `AdvertStore.onIngest` because that property only
    /// supports a single subscriber on the Swift side.
    var onLocalIngest: ((CableAdvert) -> Void)?

    /// Called for every advert received from the peer after the inbound
    /// list mutates — both new inserts and updates. Mirrors Windows's
    /// `AdvertRelay.OnReceived` event.
    var onReceived: ((CableAdvert) -> Void)?

    init(store: AdvertStore, relay: RelayClient) {
        self.store = store
        self.relay = relay
        wireUp()
    }

    private func wireUp() {
        // Outbound: anything our scanner sees, forward to the peer (and to
        // any local observers — the duplicate-payload detector hooks here).
        store.onIngest = { [weak self] advert in
            guard let self else { return }
            self.relay.send(.advert(.init(from: advert)))
            self.onLocalIngest?(advert)
        }
        // Inbound: anything the peer sends us, mirror into the received list.
        relay.onMessage = { [weak self] message in
            self?.handleInbound(message)
        }
    }

    func startHeartbeats() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                if case .open = self.relay.state {
                    let ids = self.store.adverts.map(\.id)
                    self.relay.send(.heartbeat(.init(ts: Date(), knownIds: ids)))
                }
            }
        }
    }

    func stopHeartbeats() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func handleInbound(_ message: RelayMessage) {
        switch message {
        case .advert(let wire):
            guard let advert = CableAdvert(wire: wire) else { return }
            if let idx = receivedIndex[advert.id] {
                received[idx] = advert
            } else {
                received.insert(advert, at: 0)
                rebuildReceivedIndex()
            }
            // Notify on both insert and update paths — the duplicate-payload
            // detector wants to see every received advert event, not just
            // first observations.
            onReceived?(advert)
        case .heartbeat(let h):
            lastHostHeartbeat = h.ts
        case .bye:
            // RelayClient tears down on bye.
            break
        }
    }

    private func rebuildReceivedIndex() {
        receivedIndex.removeAll(keepingCapacity: true)
        for (i, a) in received.enumerated() { receivedIndex[a.id] = i }
    }
}

// MARK: - Wire <-> domain conversions

extension CableAdvert {
    nonisolated init?(wire: RelayMessage.Advert) {
        guard let peripheralID = UUID(uuidString: wire.peripheralID),
              let payload = Data(hex: wire.payloadHex) else { return nil }
        // Defensive: an older Windows peer (pre-Phase-1 schema) sends "0000"
        // as a placeholder for "no service UUID" instead of omitting the
        // field. Treat it as nil so the row doesn't end up with a phantom
        // 0x0000 CBUUID.
        let serviceUUID: CBUUID? = wire.serviceUUID.flatMap { $0 == "0000" ? nil : CBUUID(string: $0) }
        let variant = AdvertVariant(wireName: wire.variant)
        let manufacturerData = wire.manufacturerHex.flatMap(Data.init(hex:))
        let advertisedServiceUUIDs = (wire.advertisedServiceUUIDs ?? []).map { CBUUID(string: $0) }
        self.init(
            id: wire.id,
            peripheralID: peripheralID,
            serviceUUID: serviceUUID,
            payload: payload,
            variant: variant,
            firstSeen: wire.firstSeen,
            lastSeen: wire.lastSeen,
            count: wire.count,
            rssi: wire.rssi,
            localName: wire.localName,
            advertisedServiceUUIDs: advertisedServiceUUIDs,
            manufacturerData: manufacturerData,
            txPowerLevel: wire.txPowerLevel,
            isConnectable: wire.isConnectable
        )
    }
}

extension AdvertVariant {
    nonisolated init(wireName: String) {
        switch wireName {
        case "fidoV2":      self = .fidoV2
        case "googleV1":    self = .googleV1
        case "googleV2":    self = .googleV2
        case "googleMfgV1": self = .googleMfgV1
        default:            self = .unknown(reason: wireName)
        }
    }
}

extension Data {
    /// Hex string -> bytes. Accepts lowercase or uppercase; rejects odd lengths
    /// and non-hex characters.
    nonisolated init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(byte)
            i = j
        }
        self = bytes
    }
}
