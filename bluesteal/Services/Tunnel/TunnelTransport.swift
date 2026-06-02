//
//  TunnelTransport.swift
//  bluesteal
//
//  caBLE tunnel side-channel transport with make-before-break handoff.
//  Swift port of Windows Services/Tunnel/TunnelTransport.cs.
//
//  Every 30 s (host only) the next hop is opened in parallel and promotion is
//  negotiated with the peer so the session survives the relay's ~60 s socket
//  cap. Promotion is *never* time-triggered — it requires an ack (host) or the
//  first post-ack frame (peer); timers only abort stuck pending hops.
//
//  Runs on the main actor; socket/Noise awaits suspend without blocking it.
//  Crypter state is touched only from this actor, so it stays single-threaded.
//

import Foundation
import Observation

@MainActor
@Observable
final class TunnelTransport {

    enum HopState { case steady, pendingAck, awaitingFirstFrame }

    final class Hop {
        let session: TunnelNoiseSession
        let routingId: [UInt8]
        var readTask: Task<Void, Never>?
        init(session: TunnelNoiseSession, routingId: [UInt8]) {
            self.session = session
            self.routingId = routingId
        }
        func close() { readTask?.cancel(); session.close() }
    }

    // Timing (seconds)
    private static let handoffInterval: UInt64 = 30
    private static let hostAckTimeout: UInt64 = 50
    private static let peerFirstFrameTimeout: UInt64 = 55
    private static let oldHopLinger: UInt64 = 15

    // Observable surface (RelayView reads these directly)
    private(set) var state: RelayState = .idle {
        didSet { if state != oldValue { tracer.log("tunnel", "state.change",
            ["transport": "cable-tunnel", "to": Self.label(state)]) } }
    }
    private(set) var token: String?
    private(set) var hopNumber = 0
    private(set) var messagesSent = 0
    private(set) var messagesReceived = 0
    private(set) var heartbeatCount = 0

    /// Decrypted advert/unknown frames (raw JSON bytes) for AdvertRelay.
    var onFrame: (@MainActor ([UInt8]) -> Void)?

    private let tracer: RelayTracer

    private var role: RelayRole = .host
    private var code = ""
    private var keys: TunnelKeys?
    private var host = "cable.ua5v.com"
    private var userInitiated = false
    private var peerSaidBye = false
    private var disposed = false

    private var currentHop: Hop?
    private var pendingHop: Hop?
    private var hopState: HopState = .steady
    private var pendingRoutingId: String?

    private var heartbeatTask: Task<Void, Never>?
    private var handoffTask: Task<Void, Never>?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    init(tracer: RelayTracer) { self.tracer = tracer }

    // MARK: - Public API

    @discardableResult
    func host(code: String) async throws -> String {
        resetSession()
        self.code = code
        role = .host
        let keys = TunnelKeyDerivation.derive(code: code)
        self.keys = keys
        host = TunnelServerDomain.get(keys.tunnelServerId) ?? "cable.ua5v.com"
        tracer.setContext(role: "Host", code: code)
        state = .hosting(code: code)

        let minute = TunnelKeyDerivation.currentUtcMinute()
        let tunnelId = TunnelKeyDerivation.deriveTunnelId(code: code, minute: minute)
        tracer.log("tunnel", "host.minute", ["minute": minute, "tunnelId": Data(tunnelId).hexUpper])

        do {
            let socket = try await TunnelHostSocket.connect(host: host, tunnelId: tunnelId, tracer: tracer)
            let tok = TunnelKeyDerivation.formatToken(code: code, routingId: socket.routingId)
            tracer.log("tunnel", "token.ready", ["token": tok])
            token = tok

            // Stay in .hosting (token on screen, copyable) while waiting for a
            // peer; the handshake only proceeds once the peer connects and sends
            // its initiator message, at which point we go straight to .open.
            let session = try await TunnelNoiseSession.handshakeAsHost(socket: socket, keys: keys, tracer: tracer)

            let hop = Hop(session: session, routingId: socket.routingId)
            currentHop = hop
            state = .open(role: .host)
            startReadLoop(hop)
            startHeartbeat()
            startHandoffTimer()
            return tok
        } catch {
            tracer.log("tunnel", "host.failed", ["error": "\(error)"])
            if !state.isClosed { state = .closed(reason: "host: \(error)") }
            throw error
        }
    }

    func join(token: String) async throws {
        guard let (code, routingId) = TunnelKeyDerivation.parseToken(token) else {
            throw TunnelError.raceFailed
        }
        resetSession()
        self.code = code
        role = .peer
        let keys = TunnelKeyDerivation.derive(code: code)
        self.keys = keys
        host = TunnelServerDomain.get(keys.tunnelServerId) ?? "cable.ua5v.com"
        tracer.setContext(role: "Peer", code: code)
        state = .joining(code: code)

        let minute = TunnelKeyDerivation.currentUtcMinute()
        let candidates = (-2...2).map { TunnelKeyDerivation.deriveTunnelId(code: code, minute: minute + Int64($0)) }
        tracer.log("tunnel", "peer.minute", ["minute": minute, "candidates": candidates.count])

        do {
            let socket = try await TunnelPeerSocket.connectRace(host: host, routingId: routingId,
                                                                candidateTunnelIds: candidates, tracer: tracer)
            state = .negotiating
            let session = try await TunnelNoiseSession.handshakeAsPeer(socket: socket, keys: keys, tracer: tracer)

            let hop = Hop(session: session, routingId: routingId)
            currentHop = hop
            state = .open(role: .peer)
            startReadLoop(hop)
            startHeartbeat()
            // Peer does not initiate handoffs — it responds to offers.
        } catch {
            tracer.log("tunnel", "join.failed", ["error": "\(error)"])
            if !state.isClosed { state = .closed(reason: "join: \(error)") }
            throw error
        }
    }

    func send(_ data: [UInt8]) async {
        guard !disposed, let hop = currentHop else { return }
        do {
            try await hop.session.send(data)
            messagesSent += 1
        } catch {
            tracer.log("tunnel", "send_failed", ["error": "\(error)"])
        }
    }

    func disconnect() {
        guard !disposed else { return }
        userInitiated = true
        Task { [weak self] in
            guard let self else { return }
            if case .open = self.state, let hop = self.currentHop {
                try? await self.sendControl(hop, .bye(reason: "user_disconnect"))
                self.tracer.log("tunnel", "bye.sent", ["reason": "user_disconnect"])
            }
            self.dispose()
        }
    }

    // MARK: - Read loop

    private func startReadLoop(_ hop: Hop) {
        hop.readTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let frame = try await hop.session.receive()
                    if Task.isCancelled { break }
                    self.handleFrame(frame, hop: hop)
                }
            } catch {
                self.handleReadExit(hop, error: error)
            }
        }
    }

    private func handleReadExit(_ hop: Hop, error: Error) {
        guard !disposed else { return }
        tracer.log("tunnel", "read_loop_exit", ["error": "\(error)", "hopWasPending": hop === pendingHop])
        if hop === pendingHop {
            abortPending(reason: "pending_read_error")
        } else if hop === currentHop, hopState == .steady, !state.isClosed {
            state = .closed(reason: peerSaidBye ? "peer" : "tunnel closed")
        }
    }

    private func handleFrame(_ frame: [UInt8], hop: Hop) {
        // Peer: first frame on the pending hop (after we acked) proves the host
        // has switched — promote, then process this frame on the now-current hop.
        if hop === pendingHop, role == .peer, hopState == .awaitingFirstFrame {
            tracer.log("tunnel", "hop.first_frame_received", ["nextRoutingId": pendingRoutingId ?? ""])
            promoteHop()
        }

        guard let message = try? decoder.decode(RelayMessage.self, from: Data(frame)) else {
            onFrame?(frame)
            return
        }

        switch message {
        case .heartbeat:
            heartbeatCount += 1
        case .advert:
            messagesReceived += 1
            onFrame?(frame)
        case .bye(let reason):
            tracer.log("tunnel", "bye.received", ["reason": reason])
            if reason == "hop" { break }      // expected end of an old hop
            peerSaidBye = true
            state = .closed(reason: "peer: \(reason)")
        case .handoffOffer(let offer) where role == .peer:
            tracer.log("tunnel", "hop.offer_received",
                       ["nextRoutingId": offer.nextRoutingId, "nextMinute": offer.nextMinute])
            Task { [weak self] in await self?.handleOfferAsPeer(offer) }
        case .handoffAck(let ack) where role == .host:
            tracer.log("tunnel", "hop.ack_received",
                       ["nextRoutingId": ack.nextRoutingId, "connected": ack.connected])
            handleAckAsHost(ack)
        default:
            onFrame?(frame)
        }
    }

    // MARK: - Host-side handoff

    private func startHandoffTimer() {
        guard role == .host else { return }
        handoffTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.handoffInterval * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard case .open = self.state else { break }
                guard self.hopState == .steady else { continue }
                await self.initiateHandoff()
            }
        }
    }

    private func initiateHandoff() async {
        tracer.log("tunnel", "hop.begin", nil)
        guard let keys else { return }
        do {
            let minute = TunnelKeyDerivation.currentUtcMinute()
            let tunnelId = TunnelKeyDerivation.deriveTunnelId(code: code, minute: minute)
            let socket = try await TunnelHostSocket.connect(host: host, tunnelId: tunnelId, tracer: tracer)
            let nextRoutingHex = Data(socket.routingId).hexUpper
            pendingRoutingId = nextRoutingHex

            // Offer goes out over the current hop BEFORE the handshake — the peer
            // needs the routing_id to connect and send its initiator message.
            try await sendControl(currentHop!, .handoffOffer(.init(
                nextRoutingId: nextRoutingHex, nextMinute: minute, validFrom: Date())))
            tracer.log("tunnel", "hop.offer_sent", ["nextRoutingId": nextRoutingHex, "minute": minute])

            let session = try await TunnelNoiseSession.handshakeAsHost(socket: socket, keys: keys, tracer: tracer)
            pendingHop = Hop(session: session, routingId: socket.routingId)  // host reads it only after promotion
            hopState = .pendingAck

            startAckTimeout(nextRoutingHex)
        } catch {
            tracer.log("tunnel", "hop.begin_failed", ["error": "\(error)"])
            abortPending(reason: "begin_failed")
        }
    }

    private func startAckTimeout(_ correlationId: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: (Self.hostAckTimeout - Self.handoffInterval) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.hopState == .pendingAck, self.pendingRoutingId == correlationId {
                self.tracer.log("tunnel", "hop.abort", ["reason": "ack_timeout", "nextRoutingId": correlationId])
                self.abortPending(reason: "ack_timeout")
            }
        }
    }

    private func handleAckAsHost(_ ack: RelayMessage.HandoffAck) {
        guard hopState == .pendingAck, ack.nextRoutingId == pendingRoutingId else { return }
        if ack.connected {
            tracer.log("tunnel", "hop.promote", ["role": "host", "nextRoutingId": ack.nextRoutingId])
            promoteHop()
        } else {
            tracer.log("tunnel", "hop.abort", ["reason": "peer_nack", "nextRoutingId": ack.nextRoutingId])
            abortPending(reason: "peer_nack")
        }
    }

    // MARK: - Peer-side handoff

    private func handleOfferAsPeer(_ offer: RelayMessage.HandoffOffer) async {
        guard let keys else { return }
        do {
            guard let routing = Data(hexString: offer.nextRoutingId), routing.count == 3 else {
                throw TunnelError.missingRoutingId
            }
            let tunnelId = TunnelKeyDerivation.deriveTunnelId(code: code, minute: offer.nextMinute)
            let socket = try await TunnelPeerSocket.connect(host: host, routingId: [UInt8](routing),
                                                           tunnelId: tunnelId, tracer: tracer)
            let session = try await TunnelNoiseSession.handshakeAsPeer(socket: socket, keys: keys, tracer: tracer)

            let hop = Hop(session: session, routingId: [UInt8](routing))
            pendingHop = hop
            pendingRoutingId = offer.nextRoutingId
            hopState = .awaitingFirstFrame

            try await sendControl(currentHop!, .handoffAck(.init(nextRoutingId: offer.nextRoutingId, connected: true)))
            tracer.log("tunnel", "hop.ack_sent", ["nextRoutingId": offer.nextRoutingId, "connected": true])

            startReadLoop(hop)              // catches the first post-ack frame → promotion
            startFirstFrameTimeout(offer.nextRoutingId)
        } catch {
            tracer.log("tunnel", "hop.peer_connect_failed",
                       ["error": "\(error)", "nextRoutingId": offer.nextRoutingId])
            if let hop = currentHop {
                try? await sendControl(hop, .handoffAck(.init(nextRoutingId: offer.nextRoutingId, connected: false)))
                tracer.log("tunnel", "hop.ack_sent", ["nextRoutingId": offer.nextRoutingId, "connected": false])
            }
            abortPending(reason: "peer_connect_failed")
        }
    }

    private func startFirstFrameTimeout(_ correlationId: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: (Self.peerFirstFrameTimeout - Self.handoffInterval) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.hopState == .awaitingFirstFrame, self.pendingRoutingId == correlationId {
                self.tracer.log("tunnel", "hop.abort", ["reason": "first_frame_timeout", "nextRoutingId": correlationId])
                self.abortPending(reason: "first_frame_timeout")
            }
        }
    }

    // MARK: - Promotion / abort

    private func promoteHop() {
        let old = currentHop
        currentHop = pendingHop
        pendingHop = nil
        hopState = .steady
        pendingRoutingId = nil
        hopNumber += 1

        let rid = currentHop.map { Data($0.routingId).hexUpper } ?? "?"
        tracer.log("tunnel", "hop.promote", ["newRoutingId": rid, "hopCount": hopNumber])

        // Host's promoted hop had no read loop yet; the peer's promoted hop
        // (was pending) already has one running.
        if let cur = currentHop, cur.readTask == nil { startReadLoop(cur) }

        if let old { scheduleCloseOldHop(old) }
    }

    private func abortPending(reason: String) {
        pendingHop?.close()
        pendingHop = nil
        hopState = .steady
        pendingRoutingId = nil
        _ = reason
    }

    private func scheduleCloseOldHop(_ old: Hop) {
        old.readTask?.cancel()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.oldHopLinger * 1_000_000_000)
            guard let self else { old.close(); return }
            try? await self.sendControl(old, .bye(reason: "hop"))
            self.tracer.log("tunnel", "hop.old_closed", nil)
            old.close()
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard case .open = self.state, let hop = self.currentHop else { continue }
                do {
                    try await self.sendControl(hop, .heartbeat(.init(ts: Date(), knownIds: [])))
                    self.tracer.log("tunnel", "heartbeat.sent", nil)
                } catch {
                    self.tracer.log("tunnel", "heartbeat.send_failed", ["error": "\(error)"])
                    return
                }
            }
        }
    }

    // MARK: - Helpers

    private func sendControl(_ hop: Hop, _ message: RelayMessage) async throws {
        let data = try encoder.encode(message)
        try await hop.session.send([UInt8](data))
    }

    private func dispose() {
        guard !disposed else { return }
        disposed = true
        heartbeatTask?.cancel()
        handoffTask?.cancel()
        currentHop?.close()
        pendingHop?.close()
        currentHop = nil
        pendingHop = nil
        if !state.isClosed {
            state = .closed(reason: userInitiated ? "user" : (peerSaidBye ? "peer" : "closed"))
        }
    }

    /// Wipe per-session state at the start of a new host()/join() so a previous
    /// session's hop count, message counters, token, and `disposed` flag don't
    /// bleed into the new one.
    private func resetSession() {
        hopNumber = 0
        messagesSent = 0
        messagesReceived = 0
        heartbeatCount = 0
        token = nil
        disposed = false
        userInitiated = false
        peerSaidBye = false
        pendingRoutingId = nil
        hopState = .steady
        heartbeatTask?.cancel(); heartbeatTask = nil
        handoffTask?.cancel(); handoffTask = nil
        currentHop?.close(); currentHop = nil
        pendingHop?.close(); pendingHop = nil
    }

    private static func label(_ s: RelayState) -> String {
        switch s {
        case .idle:           return "idle"
        case .hosting:        return "hosting"
        case .joining:        return "joining"
        case .negotiating:    return "negotiating"
        case .open(let r):    return "open(\(r == .host ? "host" : "peer"))"
        case .closed(let r):  return "closed(\(r))"
        }
    }
}
