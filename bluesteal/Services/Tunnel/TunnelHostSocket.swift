//
//  TunnelHostSocket.swift
//  bluesteal
//
//  Host-side (authenticator role) tunnel socket. Opens /cable/new/<tid> and
//  reads the server-assigned routing_id from the X-caBLE-Routing-ID response
//  header. Swift port of Windows TunnelHostSocket.cs + TunnelClient.cs.
//

import Foundation

final class TunnelHostSocket: TunnelSocket, @unchecked Sendable {
    private(set) var routingId: [UInt8] = []

    nonisolated override init(tracer: RelayTracer) { super.init(tracer: tracer) }

    static func connect(host: String, tunnelId: [UInt8], tracer: RelayTracer) async throws -> TunnelHostSocket {
        precondition(tunnelId.count == 16, "tunnelId must be 16 bytes")
        let socket = TunnelHostSocket(tracer: tracer)
        let url = URL(string: "wss://\(host)/cable/new/\(Data(tunnelId).hexUpper)")!

        tracer.log("tunnel", "ws_connecting", ["role": "host", "host": host,
                                               "tunnelId": Data(tunnelId).hexUpper])

        let response = try await socket.connect(url: url, origin: "wss://\(host)")
        guard let response else { throw TunnelError.noResponse }

        let negotiated = response.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") ?? ""
        guard negotiated == "fido.cable" else { throw TunnelError.subprotocolNotNegotiated(negotiated) }

        // HTTPURLResponse header lookup is case-insensitive; the server returns
        // the value as "X-Cable-Routing-Id".
        guard let hex = response.value(forHTTPHeaderField: "X-caBLE-Routing-ID"),
              let routing = Data(hexString: hex), routing.count == 3 else {
            throw TunnelError.missingRoutingId
        }
        socket.routingId = [UInt8](routing)

        tracer.log("tunnel", "ws_open", ["role": "host",
                                         "routingId": Data(socket.routingId).hexUpper,
                                         "url": url.absoluteString])
        return socket
    }
}
