import Foundation
import CryptoKit

struct HandshakeResult {
    let crypter: Crypter
    let handshakeHash: [UInt8]
}

/// caBLE NKpsk0 handshake. Swift port of Windows `HandshakeInitiator.cs` /
/// `HandshakeResponder.cs`, restricted to the NKpsk0 paths bluesteal uses.
/// (Initiator = peer/desktop with the responder's static pubkey; responder =
/// host with its static private key.)
///
/// NOTE: deriving the responder static key from a shared secret deviates from
/// real NKpsk0's threat model — here Noise is used purely as an AEAD framing
/// layer, not for authenticator authentication.
enum CableHandshake {

    // MARK: - Initiator (peer)

    final class Initiator {
        private let noise = Noise()
        private let psk: [UInt8]
        private let peerIdentity: [UInt8]   // responder static public key (X9.62)
        private var ephemeral: P256.KeyAgreement.PrivateKey

        init(psk: [UInt8], peerIdentity: [UInt8],
             ephemeral: P256.KeyAgreement.PrivateKey? = nil) {
            precondition(psk.count == 32)
            precondition(peerIdentity.count == CableP256.x962Length)
            self.psk = psk
            self.peerIdentity = peerIdentity
            self.ephemeral = ephemeral ?? P256.KeyAgreement.PrivateKey()
        }

        func buildInitialMessage() -> [UInt8] {
            noise.initialize(.nkpsk0)
            noise.mixHash([0])
            noise.mixHash(peerIdentity)
            noise.mixKeyAndHash(psk)

            let ephPub = [UInt8](CableP256.exportPublicKeyX962(ephemeral))
            noise.mixHash(ephPub)
            noise.mixKey(ephPub)

            let es = [UInt8](CableP256.computeSharedSecret(ephemeral, peerX962: Data(peerIdentity)))
            noise.mixKey(es)

            let ct = noise.encryptAndHash([])
            return ephPub + ct
        }

        func processResponse(_ response: [UInt8]) -> HandshakeResult? {
            guard response.count == CableP256.x962Length + 16 else { return nil }
            let peerPointBytes = Array(response[0..<CableP256.x962Length])
            let ct = Array(response[CableP256.x962Length...])

            guard let peerPoint = try? CableP256.importPublicKeyX962(Data(peerPointBytes)) else { return nil }
            let ee = [UInt8](CableP256.computeSharedSecret(ephemeral, peerPoint))

            noise.mixHash(peerPointBytes)
            noise.mixKey(peerPointBytes)
            noise.mixKey(ee)

            guard let pt = noise.decryptAndHash(ct), pt.isEmpty else { return nil }

            let (writeKey, readKey) = noise.trafficKeys()
            return HandshakeResult(crypter: Crypter(readKey: readKey, writeKey: writeKey),
                                   handshakeHash: noise.handshakeHash())
        }
    }

    // MARK: - Responder (host)

    static func respond(psk: [UInt8],
                        identity: P256.KeyAgreement.PrivateKey,
                        message: [UInt8],
                        ephemeral: P256.KeyAgreement.PrivateKey? = nil)
        -> (result: HandshakeResult, response: [UInt8])? {

        guard message.count >= CableP256.x962Length else { return nil }
        let peerPointBytes = Array(message[0..<CableP256.x962Length])
        let ct = Array(message[CableP256.x962Length...])

        guard let peerPoint = try? CableP256.importPublicKeyX962(Data(peerPointBytes)) else { return nil }

        let noise = Noise()
        noise.initialize(.nkpsk0)
        noise.mixHash([0])
        noise.mixHashPoint([UInt8](CableP256.exportPublicKeyX962(identity)))
        noise.mixKeyAndHash(psk)

        noise.mixHash(peerPointBytes)
        noise.mixKey(peerPointBytes)

        let es = [UInt8](CableP256.computeSharedSecret(identity, peerPoint))
        noise.mixKey(es)

        guard let pt = noise.decryptAndHash(ct), pt.isEmpty else { return nil }

        let ourEph = ephemeral ?? P256.KeyAgreement.PrivateKey()
        let ourEphPub = [UInt8](CableP256.exportPublicKeyX962(ourEph))
        noise.mixHash(ourEphPub)
        noise.mixKey(ourEphPub)

        let ee = [UInt8](CableP256.computeSharedSecret(ourEph, peerPoint))
        noise.mixKey(ee)

        let respCt = noise.encryptAndHash([])
        let response = ourEphPub + respCt

        let (readKey, writeKey) = noise.trafficKeys()
        let result = HandshakeResult(crypter: Crypter(readKey: readKey, writeKey: writeKey),
                                     handshakeHash: noise.handshakeHash())
        return (result, response)
    }
}
