//
//  AdvertVariant.swift
//  bluesteal
//

import Foundation

/// Classification of a single caBLE / FIDO hybrid advertisement service-data entry.
///
/// Two 16-bit service UUIDs carry the hybrid-transport advert: the FIDO-assigned
/// `0xFFF9` and the Google-assigned `0xFDE2`. The payload shape differs by version
/// and (historically) by UUID. See Chromium `fido_cable_discovery.cc` and
/// `v2_constants.h` (`kAdvertSize = 16 + 4`).
enum AdvertVariant: Equatable, Hashable {
    /// FIDO caBLE v2: UUID `0xFFF9`, 20-byte payload (AES-ECB(EID) ‖ HMAC[:4]).
    case fidoV2
    /// Google caBLE v1: UUID `0xFDE2`, 18-byte payload `[flags, version, 16B EID]`
    /// with bit 5 of `flags` set.
    case googleV1
    /// Google caBLE v2: UUID `0xFDE2`, 20-byte payload (same shape as fidoV2).
    case googleV2
    /// Google caBLE v1 carried as manufacturer data: company ID `0x00E0`,
    /// header `[length=20, type=0x15, flags=0x20, version=0x01]`, 16-byte EID.
    /// Observed on the Windows-publisher branch of Chromium's hybrid flow.
    case googleMfgV1
    /// Service data present under a caBLE UUID but doesn't match a known shape.
    case unknown(reason: String)

    var badge: String {
        switch self {
        case .fidoV2: return "FIDO-v2"
        case .googleV1: return "Google-v1"
        case .googleV2: return "Google-v2"
        case .googleMfgV1: return "Google-Mfg"
        case .unknown: return "?"
        }
    }

    /// String suitable for JSONL `variant` field.
    var wireName: String {
        switch self {
        case .fidoV2: return "fidoV2"
        case .googleV1: return "googleV1"
        case .googleV2: return "googleV2"
        case .googleMfgV1: return "googleMfgV1"
        case .unknown(let reason): return "unknown(\(reason))"
        }
    }
}
