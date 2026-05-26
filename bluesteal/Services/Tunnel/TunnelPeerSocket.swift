//
//  TunnelPeerSocket.swift
//  bluesteal
//
//  Peer-side (consumer/Chromium role) tunnel socket. Opens
//  /cable/connect/<routing>/<tid>. On initial join it races ±2-minute
//  tunnel_id candidates in parallel; first successful upgrade wins, losers are
//  cancelled and closed. Swift port of Windows TunnelPeerSocket.cs.
//

import Foundation

final class TunnelPeerSocket: TunnelSocket, @unchecked Sendable {

    nonisolated override init(tracer: RelayTracer) { super.init(tracer: tracer) }

    static func connect(host: String, routingId: [UInt8], tunnelId: [UInt8],
                        tracer: RelayTracer) async throws -> TunnelPeerSocket {
        precondition(routingId.count == 3, "routingId must be 3 bytes")
        precondition(tunnelId.count == 16, "tunnelId must be 16 bytes")

        let socket = TunnelPeerSocket(tracer: tracer)
        let url = URL(string: "wss://\(host)/cable/connect/\(Data(routingId).hexUpper)/\(Data(tunnelId).hexUpper)")!

        tracer.log("tunnel", "ws_connecting", ["role": "peer", "url": url.absoluteString])

        // Peer mirrors Chromium: no Origin header.
        let response = try await socket.connect(url: url, origin: nil)
        let negotiated = response?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") ?? ""
        guard negotiated == "fido.cable" else { throw TunnelError.subprotocolNotNegotiated(negotiated) }

        tracer.log("tunnel", "ws_open", ["role": "peer", "url": url.absoluteString])
        return socket
    }

    /// Races N candidate tunnel_ids in parallel; first successful WebSocket
    /// open wins. Throws if every candidate fails.
    static func connectRace(host: String, routingId: [UInt8],
                            candidateTunnelIds: [[UInt8]],
                            tracer: RelayTracer) async throws -> TunnelPeerSocket {
        guard !candidateTunnelIds.isEmpty else { throw TunnelError.raceFailed }

        tracer.log("tunnel", "peer.race.start", ["n": candidateTunnelIds.count,
                                                 "routingId": Data(routingId).hexUpper])

        return try await withThrowingTaskGroup(of: (Int, TunnelPeerSocket?).self) { group in
            for (i, tid) in candidateTunnelIds.enumerated() {
                group.addTask {
                    do {
                        let s = try await connect(host: host, routingId: routingId,
                                                  tunnelId: tid, tracer: tracer)
                        return (i, s)
                    } catch {
                        return (i, nil)
                    }
                }
            }

            var winner: TunnelPeerSocket?
            var losers: [TunnelPeerSocket] = []
            for try await (i, sock) in group {
                guard let sock else { continue }
                if winner == nil {
                    winner = sock
                    tracer.log("tunnel", "peer.race.win", ["candidateIndex": i])
                    group.cancelAll()
                } else {
                    tracer.log("tunnel", "peer.race.cancel", ["candidateIndex": i, "reason": "loser"])
                    losers.append(sock)
                }
            }
            for l in losers { l.close() }

            guard let winner else {
                tracer.log("tunnel", "peer.race.failed", nil)
                throw TunnelError.raceFailed
            }
            return winner
        }
    }
}
