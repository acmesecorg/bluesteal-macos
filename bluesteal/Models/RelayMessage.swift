//
//  RelayMessage.swift
//  bluesteal
//

import Foundation
import CoreBluetooth

/// On-wire messages exchanged through the WebRTC data channel once pairing
/// completes. Codable JSON; one message per channel send.
enum RelayMessage: Codable, Equatable {
    case advert(Advert)
    case heartbeat(Heartbeat)
    case bye(reason: String)

    struct Advert: Codable, Equatable {
        var id: String
        var ts: Date
        var peripheralID: String          // UUID string
        var serviceUUID: String?          // "FFF9" or "FDE2"; nil for mfg-data adverts
        var payloadHex: String
        var variant: String               // AdvertVariant.wireName
        var rssi: Int
        var count: Int
        var firstSeen: Date
        var lastSeen: Date
        var localName: String?
        var manufacturerHex: String?
        /// Bluetooth SIG company identifier (e.g. 0x00E0 for Google) when this
        /// advert was carried in manufacturer data. Nil for service-data
        /// adverts. Mirrors Windows `RelayAdvert.ManufacturerId`.
        var manufacturerId: UInt16?
        var advertisedServiceUUIDs: [String]?
        var txPowerLevel: Int?
        var isConnectable: Bool?
    }

    struct Heartbeat: Codable, Equatable {
        var ts: Date
        var knownIds: [String]
    }

    private enum CodingKeys: String, CodingKey { case type, payload, reason }
    private enum Kind: String, Codable { case advert, heartbeat, bye }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .advert(let a):
            try c.encode(Kind.advert, forKey: .type)
            try c.encode(a, forKey: .payload)
        case .heartbeat(let h):
            try c.encode(Kind.heartbeat, forKey: .type)
            try c.encode(h, forKey: .payload)
        case .bye(let reason):
            try c.encode(Kind.bye, forKey: .type)
            try c.encode(reason, forKey: .reason)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .advert:    self = .advert(try c.decode(Advert.self, forKey: .payload))
        case .heartbeat: self = .heartbeat(try c.decode(Heartbeat.self, forKey: .payload))
        case .bye:       self = .bye(reason: try c.decode(String.self, forKey: .reason))
        }
    }
}

extension RelayMessage.Advert {
    /// Lossy projection of a `CableAdvert` for the wire.
    init(from advert: CableAdvert) {
        self.id = advert.id
        self.ts = advert.lastSeen
        self.peripheralID = advert.peripheralID.uuidString
        self.serviceUUID = advert.serviceUUID?.uuidString
        self.payloadHex = advert.payloadHex
        self.variant = advert.variant.wireName
        self.rssi = advert.rssi
        self.count = advert.count
        self.firstSeen = advert.firstSeen
        self.lastSeen = advert.lastSeen
        self.localName = advert.localName
        self.manufacturerHex = advert.manufacturerHex
        // CoreBluetooth surfaces manufacturer data with a two-byte
        // little-endian company-ID prefix. Surface it as a discrete field so
        // the Windows peer doesn't have to re-parse `manufacturerHex` to
        // recover the company ID.
        if let mfg = advert.manufacturerData, mfg.count >= 2 {
            let s = mfg.startIndex
            self.manufacturerId = UInt16(mfg[s]) | (UInt16(mfg[s + 1]) << 8)
        } else {
            self.manufacturerId = nil
        }
        self.advertisedServiceUUIDs = advert.advertisedServiceUUIDs.map { $0.uuidString }
        self.txPowerLevel = advert.txPowerLevel
        self.isConnectable = advert.isConnectable
    }
}

/// Messages exchanged through the public MQTT broker during the ~5s pairing
/// handshake. Topics live under `bluesteal/v1/<code>/`.
///
/// Wire shape (tagged union, must match Windows
/// `Bluesteal/Models/SignalingMessage.cs` exactly):
///   offer:  `{"type":"offer",  "payload": {"sdp": "..."}}`
///   answer: `{"type":"answer", "payload": {"sdp": "..."}}`
///   ice:    `{"type":"ice",    "payload": {"sdp": "...", "sdpMid": "...", "sdpMLineIndex": 0}}`
///   bye:    `{"type":"bye",    "reason":  "..."}`
///
/// Swift's default Codable for an associated-value enum emits
/// `{"offer": {"sdp": "..."}}` instead — which is incompatible with the
/// Windows wire format. Custom Codable below makes them match.
enum SignalingMessage: Codable, Equatable {
    case offer(sdp: String)
    case answer(sdp: String)
    case ice(IceCandidate)
    case bye(reason: String)

    struct IceCandidate: Codable, Equatable {
        var sdp: String
        var sdpMid: String?
        var sdpMLineIndex: Int32
    }

    private enum CodingKeys: String, CodingKey { case type, payload, reason }
    private enum Kind: String, Codable { case offer, answer, ice, bye }
    private struct SdpPayload: Codable { var sdp: String }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .offer(let sdp):
            try c.encode(Kind.offer, forKey: .type)
            try c.encode(SdpPayload(sdp: sdp), forKey: .payload)
        case .answer(let sdp):
            try c.encode(Kind.answer, forKey: .type)
            try c.encode(SdpPayload(sdp: sdp), forKey: .payload)
        case .ice(let candidate):
            try c.encode(Kind.ice, forKey: .type)
            try c.encode(candidate, forKey: .payload)
        case .bye(let reason):
            try c.encode(Kind.bye, forKey: .type)
            try c.encode(reason, forKey: .reason)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .offer:  self = .offer(sdp: try c.decode(SdpPayload.self, forKey: .payload).sdp)
        case .answer: self = .answer(sdp: try c.decode(SdpPayload.self, forKey: .payload).sdp)
        case .ice:    self = .ice(try c.decode(IceCandidate.self, forKey: .payload))
        case .bye:    self = .bye(reason: try c.decode(String.self, forKey: .reason))
        }
    }
}
