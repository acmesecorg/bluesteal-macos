import Foundation
import CryptoKit

/// caBLE post-handshake AEAD framer. Swift port of Windows `Crypter.cs`.
/// 32-byte padding, BE sequence number at nonce offset 8, empty AAD.
final class Crypter {
    private static let paddingGranularity = 32
    private static let maxSequence: UInt32 = (1 << 24) - 1

    private let readKey: [UInt8]
    private let writeKey: [UInt8]
    private var readSeq: UInt32 = 0
    private var writeSeq: UInt32 = 0

    init(readKey: [UInt8], writeKey: [UInt8]) {
        precondition(readKey.count == 32 && writeKey.count == 32)
        self.readKey = readKey
        self.writeKey = writeKey
    }

    func encrypt(_ plaintext: [UInt8]) -> [UInt8]? {
        let paddedSize = ((plaintext.count + 1 + Self.paddingGranularity - 1) / Self.paddingGranularity) * Self.paddingGranularity
        let numZeros = paddedSize - plaintext.count - 1

        var padded = [UInt8](repeating: 0, count: paddedSize)
        for (i, b) in plaintext.enumerated() { padded[i] = b }
        padded[paddedSize - 1] = UInt8(numZeros)

        guard writeSeq <= Self.maxSequence else { return nil }

        var nonce = [UInt8](repeating: 0, count: 12)
        writeUInt32BE(writeSeq, into: &nonce, at: 8)
        writeSeq &+= 1

        let sealed = try! AES.GCM.seal(Data(padded),
                                       using: SymmetricKey(data: Data(writeKey)),
                                       nonce: try! AES.GCM.Nonce(data: Data(nonce)))
        return [UInt8](sealed.ciphertext) + [UInt8](sealed.tag)
    }

    func decrypt(_ ciphertext: [UInt8]) -> [UInt8]? {
        guard ciphertext.count >= 16, readSeq <= Self.maxSequence else { return nil }

        var nonce = [UInt8](repeating: 0, count: 12)
        writeUInt32BE(readSeq, into: &nonce, at: 8)

        let ct = Array(ciphertext[0..<(ciphertext.count - 16)])
        let tag = Array(ciphertext[(ciphertext.count - 16)...])
        let plaintext: [UInt8]
        do {
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: Data(nonce)),
                                            ciphertext: Data(ct), tag: Data(tag))
            plaintext = [UInt8](try AES.GCM.open(box, using: SymmetricKey(data: Data(readKey))))
        } catch {
            return nil
        }
        readSeq &+= 1

        guard !plaintext.isEmpty else { return nil }
        let paddingLength = Int(plaintext[plaintext.count - 1])
        guard paddingLength + 1 <= plaintext.count else { return nil }
        return Array(plaintext[0..<(plaintext.count - paddingLength - 1)])
    }

    func isCounterparty(of other: Crypter) -> Bool {
        readKey == other.writeKey && writeKey == other.readKey
    }

    private func writeUInt32BE(_ value: UInt32, into buf: inout [UInt8], at offset: Int) {
        buf[offset]     = UInt8((value >> 24) & 0xFF)
        buf[offset + 1] = UInt8((value >> 16) & 0xFF)
        buf[offset + 2] = UInt8((value >> 8) & 0xFF)
        buf[offset + 3] = UInt8(value & 0xFF)
    }
}
