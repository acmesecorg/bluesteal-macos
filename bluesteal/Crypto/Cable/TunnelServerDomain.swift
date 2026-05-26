//
//  TunnelServerDomain.swift
//  bluesteal
//
//  Swift port of Windows Crypto/Cable/TunnelServerDomain.cs.
//  Resolves a 16-bit tunnel-server domain id to a hostname. For bluesteal v1
//  the id is clamped to 0 (Google), but the hashed-domain derivation is ported
//  faithfully so the two platforms stay byte-compatible if that changes.
//

import Foundation
import CryptoKit

enum TunnelServerDomain {
    private static let assignedDomains = [
        "cable.ua5v.com", // 0 - Google
        "cable.auth.com"  // 1 - Apple
    ]

    private static let salt = Array("caBLEv2 tunnel server domain\0\0\0".utf8)
    private static let tlds = [".com", ".org", ".net", ".info"]
    private static let base32Alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    static func get(_ id: UInt16) -> String? {
        if id < 256 {
            return Int(id) < assignedDomains.count ? assignedDomains[Int(id)] : nil
        }

        var buf = salt // 31 bytes
        // Write id as little-endian UInt16 into bytes [28,29]
        buf[28] = UInt8(id & 0xFF)
        buf[29] = UInt8((id >> 8) & 0xFF)

        let digest = Array(SHA256.hash(data: Data(buf)))

        var result: UInt64 = 0
        for i in 0..<8 { result |= UInt64(digest[i]) << (8 * i) } // little-endian read

        let tld = tlds[Int(result & 3)]
        result >>= 2

        var s = "cable."
        while result != 0 {
            s.append(base32Alphabet[Int(result & 31)])
            result >>= 5
        }
        s += tld
        return s
    }
}
