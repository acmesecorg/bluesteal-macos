import Foundation
import CryptoKit

enum HandshakeType: String {
    case knpsk0 = "Noise_KNpsk0_P256_AESGCM_SHA256"
    case nkpsk0 = "Noise_NKpsk0_P256_AESGCM_SHA256"
    case nk     = "Noise_NK_P256_AESGCM_SHA256"
}

/// Swift port of Windows `Noise.cs` — the caBLE Noise symmetric state.
final class Noise {
    private var chainingKey = [UInt8](repeating: 0, count: 32)
    private var h = [UInt8](repeating: 0, count: 32)
    private var symmetricKey = [UInt8](repeating: 0, count: 32)
    private var symmetricNonce: UInt32 = 0

    func initialize(_ type: HandshakeType) {
        let nameBytes = Array(type.rawValue.utf8) // all protocol names ≤ 32 bytes
        chainingKey = [UInt8](repeating: 0, count: 32)
        for (i, b) in nameBytes.enumerated() { chainingKey[i] = b }
        h = chainingKey
        symmetricKey = [UInt8](repeating: 0, count: 32)
        symmetricNonce = 0
    }

    func mixHash(_ data: [UInt8]) {
        var hasher = SHA256()
        hasher.update(data: Data(h))
        hasher.update(data: Data(data))
        h = Array(hasher.finalize())
    }

    func mixKey(_ ikm: [UInt8]) {
        let out = hkdf(ikm: ikm, length: 64)
        chainingKey = Array(out[0..<32])
        initializeKey(Array(out[32..<64]))
    }

    func mixKeyAndHash(_ ikm: [UInt8]) {
        let out = hkdf(ikm: ikm, length: 96)
        chainingKey = Array(out[0..<32])
        mixHash(Array(out[32..<64]))
        initializeKey(Array(out[64..<96]))
    }

    func encryptAndHash(_ plaintext: [UInt8]) -> [UInt8] {
        var nonce = [UInt8](repeating: 0, count: 12)
        writeUInt32BE(symmetricNonce, into: &nonce, at: 0)
        symmetricNonce &+= 1

        let sealed = try! AES.GCM.seal(Data(plaintext),
                                       using: SymmetricKey(data: Data(symmetricKey)),
                                       nonce: try! AES.GCM.Nonce(data: Data(nonce)),
                                       authenticating: Data(h))
        let result = [UInt8](sealed.ciphertext) + [UInt8](sealed.tag)
        mixHash(result)
        return result
    }

    func decryptAndHash(_ ciphertextWithTag: [UInt8]) -> [UInt8]? {
        guard ciphertextWithTag.count >= 16 else { return nil }
        var nonce = [UInt8](repeating: 0, count: 12)
        writeUInt32BE(symmetricNonce, into: &nonce, at: 0)
        symmetricNonce &+= 1

        let ct = Array(ciphertextWithTag[0..<(ciphertextWithTag.count - 16)])
        let tag = Array(ciphertextWithTag[(ciphertextWithTag.count - 16)...])
        do {
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: Data(nonce)),
                                            ciphertext: Data(ct), tag: Data(tag))
            let pt = try AES.GCM.open(box, using: SymmetricKey(data: Data(symmetricKey)),
                                      authenticating: Data(h))
            mixHash(ciphertextWithTag)
            return [UInt8](pt)
        } catch {
            return nil
        }
    }

    func handshakeHash() -> [UInt8] { h }

    func mixHashPoint(_ x962: [UInt8]) {
        precondition(x962.count == CableP256.x962Length)
        mixHash(x962)
    }

    /// Returns (first, second) traffic keys.
    func trafficKeys() -> ([UInt8], [UInt8]) {
        let out = hkdf(ikm: [], length: 64)
        return (Array(out[0..<32]), Array(out[32..<64]))
    }

    // MARK: - internals

    private func hkdf(ikm: [UInt8], length: Int) -> [UInt8] {
        // .NET: HKDF.DeriveKey(SHA256, ikm, out, salt=chainingKey, info=empty)
        let out = HKDFShim.derive(ikm: Data(ikm), salt: Data(chainingKey),
                                  info: Data(), length: length)
        return [UInt8](out)
    }

    private func initializeKey(_ key: [UInt8]) {
        symmetricKey = key
        symmetricNonce = 0
    }

    private func writeUInt32BE(_ value: UInt32, into buf: inout [UInt8], at offset: Int) {
        buf[offset]     = UInt8((value >> 24) & 0xFF)
        buf[offset + 1] = UInt8((value >> 16) & 0xFF)
        buf[offset + 2] = UInt8((value >> 8) & 0xFF)
        buf[offset + 3] = UInt8(value & 0xFF)
    }
}
