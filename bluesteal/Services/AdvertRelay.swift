//
//  AdvertRelay.swift
//  bluesteal
//
//  Bridges the local AdvertStore with the paired peer over the caBLE tunnel.
//  Outbound: every deduped CableAdvert the scanner sees is pushed through
//  `tunnelSend`. Inbound: frames arriving from the tunnel are deserialised and
//  mirrored into `received` so the existing AdvertRowView renders them with
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
    private let tracer: RelayTracer?

    /// Outbound adverts are serialised to JSON and sent through this closure
    /// (the caBLE tunnel transport). Set by the view once the tunnel is
    /// connected; nil means not connected, so adverts are not forwarded.
    /// Mirrors Windows `AdvertRelay.TunnelSend`.
    var tunnelSend: ((Data) -> Void)?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

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

    init(store: AdvertStore, tracer: RelayTracer? = nil) {
        self.store = store
        self.tracer = tracer
        wireUp()
    }

    private func wireUp() {
        // Outbound: anything our scanner sees, forward to the peer over the
        // tunnel (and to any local observers — the duplicate-payload detector
        // hooks here). When the tunnel isn't connected, `tunnelSend` is nil and
        // adverts are simply not forwarded.
        store.onIngest = { [weak self] advert in
            guard let self else { return }
            if let tunnelSend = self.tunnelSend {
                let msg = RelayMessage.advert(.init(from: advert))
                if let data = try? self.encoder.encode(msg) { tunnelSend(data) }
            }
            self.onLocalIngest?(advert)
        }
    }

    /// Decodes a raw JSON frame delivered by the tunnel transport and routes it
    /// through the inbound path. Mirrors Windows `AdvertRelay.HandleInboundFrame`.
    func handleTunnelFrame(_ data: Data) {
        guard let message = try? decoder.decode(RelayMessage.self, from: data) else { return }
        handleInbound(message)
    }

    private func handleInbound(_ message: RelayMessage) {
        switch message {
        case .advert(let wire):
            guard let advert = CableAdvert(wire: wire) else { return }
            tracer?.log("relay", "relay.advert.recv", [
                "id": advert.id,
                "variant": advert.variant.wireName,
                "payloadHexPrefix": String(advert.payloadHex.prefix(16)),
                "rssi": advert.rssi
            ])
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
            // The tunnel transport tears itself down on bye; nothing to do here.
            break
        case .handoffOffer, .handoffAck:
            // Tunnel-transport control frames; handled inside TunnelTransport,
            // never surfaced on this inbound path.
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
