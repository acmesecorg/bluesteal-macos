import Foundation
import CryptoKit

/// P-256 ECDH helpers for caBLE Noise. Swift port of Windows `P256.cs`.
/// Uses CryptoKit's `P256.KeyAgreement`; the only non-trivial piece is
/// `deriveKeyFromSeed`, which replicates BoringSSL's `EC_KEY_derive_from_secret`
/// (HKDF → 48-byte big-endian integer → reduce mod the P-256 group order).
enum CableP256 {
    static let x962Length = 65

    /// P-256 group order n, big-endian, 32 bytes.
    private static let order: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84,
        0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51
    ]

    static func deriveKeyFromSeed(_ seed: Data) -> P256.KeyAgreement.PrivateKey {
        precondition(seed.count == 32, "seed must be 32 bytes")
        let salt = Data("EC_KEY_derive_from_secret".utf8)
        let hkdf = HKDFShim.derive(ikm: seed, salt: salt, info: Data(), length: 48)
        var scalar = reduceModOrder([UInt8](hkdf))
        if scalar.allSatisfy({ $0 == 0 }) { scalar[31] = 1 }
        // CryptoKit validates the scalar ∈ [1, n-1]; reduceModOrder guarantees it.
        return try! P256.KeyAgreement.PrivateKey(rawRepresentation: Data(scalar))
    }

    static func exportPublicKeyX962(_ key: P256.KeyAgreement.PrivateKey) -> Data {
        key.publicKey.x963Representation
    }

    static func importPublicKeyX962(_ x962: Data) throws -> P256.KeyAgreement.PublicKey {
        try P256.KeyAgreement.PublicKey(x963Representation: x962)
    }

    /// Raw ECDH shared secret (the 32-byte X coordinate), matching .NET's
    /// `DeriveRawSecretAgreement`.
    static func computeSharedSecret(_ priv: P256.KeyAgreement.PrivateKey,
                                    _ pub: P256.KeyAgreement.PublicKey) -> Data {
        let secret = try! priv.sharedSecretFromKeyAgreement(with: pub)
        return secret.withUnsafeBytes { Data($0) }
    }

    static func computeSharedSecret(_ priv: P256.KeyAgreement.PrivateKey,
                                    peerX962: Data) -> Data {
        let pub = try! importPublicKeyX962(peerX962)
        return computeSharedSecret(priv, pub)
    }

    // MARK: - 48-byte BE value mod order n (bit-by-bit long division)

    private static func reduceModOrder(_ value: [UInt8]) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 33) // 264-bit accumulator (r[0] = overflow byte)
        for byte in value {
            var bit = 7
            while bit >= 0 {
                let b = (byte >> UInt8(bit)) & 1
                // r = (r << 1) | b
                var carry = UInt16(b)
                var i = 32
                while i >= 0 {
                    let v = (UInt16(r[i]) << 1) | carry
                    r[i] = UInt8(v & 0xFF)
                    carry = v >> 8
                    i -= 1
                }
                if geqOrder(r) { subOrder(&r) }
                bit -= 1
            }
        }
        return Array(r[1...]) // low 32 bytes
    }

    private static func geqOrder(_ r: [UInt8]) -> Bool {
        if r[0] != 0 { return true }
        for i in 0..<32 {
            if r[i + 1] != order[i] { return r[i + 1] > order[i] }
        }
        return true // equal
    }

    private static func subOrder(_ r: inout [UInt8]) {
        var borrow = 0
        var i = 31
        while i >= 0 {
            let diff = Int(r[i + 1]) - Int(order[i]) - borrow
            if diff < 0 { r[i + 1] = UInt8(diff + 256); borrow = 1 }
            else { r[i + 1] = UInt8(diff); borrow = 0 }
            i -= 1
        }
        r[0] = UInt8(Int(r[0]) - borrow)
    }
}
