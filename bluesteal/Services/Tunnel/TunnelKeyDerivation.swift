//
//  TunnelKeyDerivation.swift
//  bluesteal
//
//  Swift port of Windows Services/Tunnel/TunnelKeyDerivation.cs.
//  Derives all cryptographic material from the 5-char pairing code and handles
//  the 11-char composite OOB token (CODE-ROUTING, e.g. "BSTL1-7C4A9C").
//

import Foundation
import CryptoKit

/// Wraps the derived responder static keypair so call sites don't depend on
/// CryptoKit types directly.
struct CableP256Key {
    let privateKey: P256.KeyAgreement.PrivateKey
    var publicKeyX962: [UInt8] { [UInt8](CableP256.exportPublicKeyX962(privateKey)) }
}

/// All cryptographic material derived from a 5-char code.
struct TunnelKeys {
    let tunnelServerId: UInt16
    let tunnelId: [UInt8]        // legacy salt-empty id (kept for parity; unused)
    let psk: [UInt8]
    let responderStatic: CableP256Key
}

enum TunnelKeyDerivation {
    private static func label(_ s: String) -> Data { Data(s.utf8) }

    private static let tokenCodeChars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let tokenHexChars = Set("0123456789ABCDEF")

    static func derive(code: String) -> TunnelKeys {
        precondition(!code.trimmingCharacters(in: .whitespaces).isEmpty)
        let ikm = Data(code.utf8)

        // tunnel_server_id derived but clamped to 0 (Google) for v1.
        _ = HKDFShim.derive(ikm: ikm, salt: Data(), info: label("bluesteal/tunnel-server-id"), length: 2)
        let tunnelServerId: UInt16 = 0

        let tunnelId = [UInt8](HKDFShim.derive(ikm: ikm, salt: Data(), info: label("bluesteal/tunnel-id"), length: 16))
        let psk = [UInt8](HKDFShim.derive(ikm: ikm, salt: Data(), info: label("bluesteal/psk"), length: 32))
        let seed = HKDFShim.derive(ikm: ikm, salt: Data(), info: label("bluesteal/responder-static"), length: 32)
        let responder = CableP256.deriveKeyFromSeed(seed)

        return TunnelKeys(tunnelServerId: tunnelServerId,
                          tunnelId: tunnelId,
                          psk: psk,
                          responderStatic: CableP256Key(privateKey: responder))
    }

    // MARK: - Minute-based tunnel id

    /// UTC minutes since the Unix epoch.
    static func currentUtcMinute() -> Int64 {
        Int64(Date().timeIntervalSince1970) / 60
    }

    /// 16-byte rotating tunnel_id for a given UTC minute. Derived from the code
    /// alone (salt = little-endian Int64 minute) so host and peer agree without
    /// extra OOB data.
    static func deriveTunnelId(code: String, minute: Int64) -> [UInt8] {
        var le = minute.littleEndian
        let salt = withUnsafeBytes(of: &le) { Data($0) }
        return [UInt8](HKDFShim.derive(ikm: Data(code.utf8), salt: salt,
                                       info: label("bluesteal/tunnel-minute"), length: 16))
    }

    // MARK: - OOB token

    /// "BSTL1" + [0x7C,0x4A,0x9C] → "BSTL1-7C4A9C".
    static func formatToken(code: String, routingId: [UInt8]) -> String {
        precondition(routingId.count == 3, "routingId must be 3 bytes")
        return "\(code)-\(Data(routingId).hexUpper)"
    }

    /// Parses an 11-char composite token into (code, 3-byte routingId).
    static func parseToken(_ token: String) -> (code: String, routingId: [UInt8])? {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let (code, routingHex) = matchToken(t),
              let routing = Data(hexString: routingHex) else { return nil }
        return (code, [UInt8](routing))
    }

    /// True if the input looks like an 11-char tunnel token (vs a 5-char code).
    static func isTunnelToken(_ input: String) -> Bool {
        matchToken(input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()) != nil
    }

    /// Validates `^[A-Z0-9]{5}-[0-9A-F]{6}$` (input already uppercased).
    private static func matchToken(_ s: String) -> (code: String, routingHex: String)? {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let code = String(parts[0]), routing = String(parts[1])
        guard code.count == 5, routing.count == 6,
              code.allSatisfy({ tokenCodeChars.contains($0) }),
              routing.allSatisfy({ tokenHexChars.contains($0) }) else { return nil }
        return (code, routing)
    }
}
