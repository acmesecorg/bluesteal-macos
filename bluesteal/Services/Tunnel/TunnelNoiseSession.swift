//
//  TunnelNoiseSession.swift
//  bluesteal
//
//  Runs the Noise NKpsk0 handshake over an opened tunnel socket, then provides
//  encrypted send/receive. Swift port of Windows TunnelNoiseSession.cs — the
//  C# decrypt-loop + Channel collapses to an inline `receive()` because
//  URLSession delivers whole messages and each session has a single consumer.
//
//  NOTE: `Crypter` is stateful (sequence numbers) and NOT thread-safe; callers
//  must serialise send/receive on one task.
//

import Foundation

final class TunnelNoiseSession {
    private let crypter: Crypter
    private let socket: TunnelSocket
    private let tracer: RelayTracer

    private init(crypter: Crypter, socket: TunnelSocket, tracer: RelayTracer) {
        self.crypter = crypter
        self.socket = socket
        self.tracer = tracer
    }

    /// Host-side (responder) handshake.
    static func handshakeAsHost(socket: TunnelHostSocket, keys: TunnelKeys,
                                tracer: RelayTracer) async throws -> TunnelNoiseSession {
        tracer.log("tunnel", "noise_handshake_start", ["role": "host"])

        let initiatorMsg = try await socket.receive()
        guard let (result, response) = CableHandshake.respond(
            psk: keys.psk, identity: keys.responderStatic.privateKey, message: initiatorMsg) else {
            throw TunnelError.handshakeFailed
        }
        try await socket.send(response)

        tracer.log("tunnel", "noise_handshake_complete", ["role": "host"])
        return TunnelNoiseSession(crypter: result.crypter, socket: socket, tracer: tracer)
    }

    /// Peer-side (initiator) handshake.
    static func handshakeAsPeer(socket: TunnelPeerSocket, keys: TunnelKeys,
                                tracer: RelayTracer) async throws -> TunnelNoiseSession {
        tracer.log("tunnel", "noise_handshake_start", ["role": "peer"])

        let initiator = CableHandshake.Initiator(psk: keys.psk,
                                                 peerIdentity: keys.responderStatic.publicKeyX962)
        let initial = initiator.buildInitialMessage()
        try await socket.send(initial)

        let responseMsg = try await socket.receive()
        guard let result = initiator.processResponse(responseMsg) else {
            throw TunnelError.handshakeFailed
        }

        tracer.log("tunnel", "noise_handshake_complete", ["role": "peer"])
        return TunnelNoiseSession(crypter: result.crypter, socket: socket, tracer: tracer)
    }

    func send(_ plaintext: [UInt8]) async throws {
        guard let ciphertext = crypter.encrypt(plaintext) else {
            throw TunnelError.crypterLimitExceeded
        }
        try await socket.send(ciphertext)
    }

    /// Decrypts the next frame. Throws on decrypt failure or socket close.
    func receive() async throws -> [UInt8] {
        let frame = try await socket.receive()
        guard let plaintext = crypter.decrypt(frame) else {
            tracer.log("tunnel", "noise_decrypt_failed", nil)
            throw TunnelError.decryptFailed
        }
        return plaintext
    }

    func close() { socket.close() }
}
