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
    // A handoff that fails to even open its next socket (`hop.begin_failed`)
    // otherwise strands the session until the next 30s tick — by then the
    // current socket is past the relay's ~60s cap and dead. Retry quickly so a
    // transient network blip doesn't kill the whole session.
    private static let handoffRetryInterval: UInt64 = 5
    private static let handoffMaxRetries = 5

    // Observable surface (RelayView reads these directly)
    private(set) var state: RelayState = .idle {
        didSet {
            if state != oldValue {
                tracer.log("tunnel", "state.change",
                           ["transport": "cable-tunnel", "to": Self.label(state)])
                updateSleepAssertion(for: state)
            }
        }
    }
    private(set) var token: String?
    private(set) var hopNumber = 0
    private(set) var messagesSent = 0
    private(set) var messagesReceived = 0
    private(set) var heartbeatCount = 0

    /// caBLE tunnel-server domain resolved for the current session — e.g.
    /// "cable.ua5v.com" (Google) or "cable.auth.com" (Apple). Surfaced in the
    /// "tunnel open" status so we can tell which provider's tunnel was used.
    var tunnelDomain: String { host }

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

    /// Persistent-host loop: keeps re-registering with the relay while waiting
    /// for a peer, so the relay's ~60s idle socket cap doesn't strand a host
    /// nobody has joined yet. Nil once a peer connects (the handoff timer then
    /// sustains the established session).
    private var hostLoopTask: Task<Void, Never>?

    /// True for a host() session: makes drops self-heal — when an established
    /// session closes for any non-user reason, the host re-registers and
    /// republishes instead of going to .closed, so an unattended host recovers.
    private var persistentHost = false

    /// Peer-side rendezvous join: the room to re-join on a non-user drop
    /// (self-heal). Non-nil only for a `joinViaRendezvous` session; cleared on a
    /// user disconnect or a plain typed join.
    private var rendezvousRoom: String?

    /// Peer-side rendezvous poll/join loop (the "two rooms" demo).
    private var rendezvousTask: Task<Void, Never>?

    /// Peer-liveness watchdog. The relay's handoff keeps a socket alive even
    /// after the far side silently leaves, so an open session would otherwise
    /// sit `open` with a dead peer forever. Both sides heartbeat every 2s; if
    /// nothing arrives for `peerSilenceTimeout`, treat the peer as gone and
    /// self-heal — the host re-hosts + republishes, the peer re-joins.
    private var livenessTask: Task<Void, Never>?
    private var lastPeerFrameAt = Date()
    private static let peerSilenceTimeout: TimeInterval = 15

    /// Optional out-of-band token drop. When configured (`-rv`/`-room`/`-k`
    /// startup args), a host republishes its fresh CODE-ROUTING token on each
    /// (re)connect so a peer in another room can read it. Nil = rendezvous
    /// disabled. Also used by the peer join loop to fetch the host's token.
    private var rendezvous: RendezvousClient?

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
        rendezvousRoom = nil
        let keys = TunnelKeyDerivation.derive(code: code)
        self.keys = keys
        host = TunnelServerDomain.get(keys.tunnelServerId) ?? "cable.ua5v.com"
        tracer.setContext(role: "Host", code: code)
        persistentHost = true
        // Enable the out-of-band token drop if the operator configured one.
        if let cfg = RendezvousConfig.fromDefaults() {
            rendezvous = RendezvousClient(config: cfg, tracer: tracer)
            tracer.log("rendezvous", "enabled", ["room": cfg.room])
        }
        state = .hosting(code: code)

        // Drive registration from a persistent loop so a host waiting for a peer
        // survives the relay's ~60s idle socket cap: each (re)connect gets a
        // fresh routing_id -> new token, which is republished to the rendezvous.
        // The token surfaces via the observable `token`; callers ignore the
        // return (kept for signature compatibility).
        hostLoopTask?.cancel()
        hostLoopTask = Task { @MainActor [weak self] in await self?.runHostLoop() }
        return ""
    }

    /// Re-registers with the relay until a peer completes the handshake. Once a
    /// peer connects, the established session is handed to the heartbeat/handoff
    /// machinery and the loop exits.
    private func runHostLoop() async {
        guard let keys else { return }
        var attempt = 0
        while !disposed && !Task.isCancelled {
            attempt += 1
            do {
                let minute = TunnelKeyDerivation.currentUtcMinute()
                let tunnelId = TunnelKeyDerivation.deriveTunnelId(code: code, minute: minute)
                tracer.log("tunnel", "host.minute",
                           ["minute": minute, "tunnelId": Data(tunnelId).hexUpper, "attempt": attempt])

                let socket = try await TunnelHostSocket.connect(host: host, tunnelId: tunnelId, tracer: tracer)
                guard !disposed, !Task.isCancelled else { socket.close(); return }

                let tok = TunnelKeyDerivation.formatToken(code: code, routingId: socket.routingId)
                tracer.log("tunnel", "token.ready", ["token": tok, "attempt": attempt])
                token = tok
                state = .hosting(code: code)
                await rendezvous?.publish(token: tok)

                // Blocks until the peer connects and sends its initiator message
                // (-> .open) or the relay drops the idle socket (-> catch -> re-register).
                let session = try await TunnelNoiseSession.handshakeAsHost(socket: socket, keys: keys, tracer: tracer)
                guard !disposed, !Task.isCancelled else { socket.close(); return }

                let hop = Hop(session: session, routingId: socket.routingId)
                currentHop = hop
                state = .open(role: .host)
                lastPeerFrameAt = Date()
                startReadLoop(hop)
                startHeartbeat()
                startHandoffTimer()
                startLivenessWatchdog()
                hostLoopTask = nil
                return
            } catch {
                if disposed || Task.isCancelled { return }
                // Waiting socket dropped before a peer joined — re-register with
                // a fresh routing_id after a short backoff. This is expected at
                // the relay's idle cap, not a session failure, so we stay in
                // .hosting rather than going to .closed.
                tracer.log("tunnel", "host.wait_reconnect", ["attempt": attempt, "error": "\(error)"])
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Self-heal: tear down the dead session (keeping code/keys/rendezvous) and
    /// relaunch the host loop so the host re-registers, gets a fresh token, and
    /// republishes — letting an unattended host ride through drops. No-op after
    /// a user disconnect or dispose.
    private func restartHostLoop(reason: String) {
        guard persistentHost, !disposed, !userInitiated else { return }
        tracer.log("tunnel", "host.self_heal", ["reason": reason])
        livenessTask?.cancel(); livenessTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        handoffTask?.cancel(); handoffTask = nil
        currentHop?.close(); currentHop = nil
        pendingHop?.close(); pendingHop = nil
        hopState = .steady
        pendingRoutingId = nil
        peerSaidBye = false
        state = .hosting(code: code)
        hostLoopTask?.cancel()
        hostLoopTask = Task { @MainActor [weak self] in await self?.runHostLoop() }
    }

    func join(token: String) async throws {
        // A plain typed join is explicitly not a rendezvous session, so it has
        // no self-heal room. (The rendezvous path calls joinInternal directly,
        // preserving the room it set.)
        rendezvousRoom = nil
        try await joinInternal(token: token)
    }

    private func joinInternal(token: String) async throws {
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
            lastPeerFrameAt = Date()
            startReadLoop(hop)
            startHeartbeat()
            startLivenessWatchdog()
            // Peer does not initiate handoffs — it responds to offers.
        } catch {
            tracer.log("tunnel", "join.failed", ["error": "\(error)"])
            if !state.isClosed { state = .closed(reason: "join: \(error)") }
            throw error
        }
    }

    /// Peer-side rendezvous join for the "two rooms" demo: polls the shared
    /// room for the host's latest token and joins, retrying across the host's
    /// ~60s routing_id rotations until connected or cancelled. Enables
    /// self-heal (re-join) on a non-user drop.
    func joinViaRendezvous(room: String) {
        rendezvousRoom = room
        rendezvousTask?.cancel()
        rendezvousTask = Task { @MainActor [weak self] in await self?.joinViaRendezvousInternal(room) }
    }

    private func joinViaRendezvousInternal(_ room: String) async {
        guard let cfg = RendezvousConfig.fromDefaults() else {
            state = .closed(reason: "rendezvous not configured")
            return
        }
        let rv = RendezvousClient(config: cfg, tracer: tracer)
        tracer.log("rendezvous", "join.begin", ["room": room])
        var attempt = 0
        while !disposed && !Task.isCancelled {
            attempt += 1
            state = .joining(code: room)
            let token = await rv.fetch()
            if let token, TunnelKeyDerivation.isTunnelToken(token) {
                tracer.log("rendezvous", "join.try", ["attempt": attempt])
                try? await joinInternal(token: token.uppercased())   // sets .open or .closed
                if case .open = state {
                    rendezvousTask = nil
                    return
                }
                // Stale token (raced a rotation) — fall through and re-poll.
            }
            if disposed || Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// Self-heal: on a non-user drop of a rendezvous session, re-poll and
    /// re-join after a short backoff (the host needs a moment to re-register
    /// and republish its fresh token). No-op after a user disconnect.
    private func restartRendezvousJoin(reason: String) {
        guard let room = rendezvousRoom, !userInitiated, !disposed else { return }
        tracer.log("rendezvous", "self_heal", ["reason": reason, "room": room])
        livenessTask?.cancel(); livenessTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        currentHop?.close(); currentHop = nil
        pendingHop?.close(); pendingHop = nil
        hopState = .steady
        pendingRoutingId = nil
        peerSaidBye = false
        state = .joining(code: room)
        rendezvousTask?.cancel()
        rendezvousTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !self.disposed, !self.userInitiated else { return }
            await self.joinViaRendezvousInternal(room)
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
            if persistentHost, !userInitiated {
                restartHostLoop(reason: peerSaidBye ? "peer_bye" : "tunnel_closed")
            } else if rendezvousRoom != nil, !userInitiated {
                restartRendezvousJoin(reason: peerSaidBye ? "peer_bye" : "tunnel_closed")
            } else {
                state = .closed(reason: peerSaidBye ? "peer" : "tunnel closed")
            }
        }
    }

    private func handleFrame(_ frame: [UInt8], hop: Hop) {
        // Any frame from the peer is proof of life for the liveness watchdog.
        lastPeerFrameAt = Date()
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
            if persistentHost, !userInitiated {
                restartHostLoop(reason: "peer_bye")          // wait for a peer to re-join
            } else if rendezvousRoom != nil, !userInitiated {
                restartRendezvousJoin(reason: "peer_bye")    // re-join the host
            } else {
                state = .closed(reason: "peer: \(reason)")
            }
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

                // After initiateHandoff, hopState is .pendingAck on success (the
                // next socket opened; ack flow takes over) or back to .steady on
                // a begin_failed. On failure, retry quickly rather than waiting a
                // full interval, so one blip doesn't strand us past the ~60s cap.
                var retries = 0
                while retries < Self.handoffMaxRetries, !Task.isCancelled {
                    guard case .open = self.state, self.hopState == .steady else { break }
                    try? await Task.sleep(nanoseconds: Self.handoffRetryInterval * 1_000_000_000)
                    guard !Task.isCancelled, case .open = self.state, self.hopState == .steady else { break }
                    retries += 1
                    self.tracer.log("tunnel", "hop.retry", ["attempt": retries])
                    await self.initiateHandoff()
                }
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

    // MARK: - Idle-sleep prevention

    /// Held while a relay session is active so the Mac doesn't idle-sleep the
    /// process and let the relay's WebSocket get throttled or dropped — the
    /// unattended "two rooms" host/peer must keep running screen-locked. This is
    /// the high-level equivalent of an IOPMAssertion
    /// (kIOPMAssertionTypePreventUserIdleSystemSleep); lid-closed sleep on a
    /// laptop still applies.
    private var sleepActivity: NSObjectProtocol?

    private func updateSleepAssertion(for s: RelayState) {
        let active: Bool
        switch s {
        case .idle, .closed:                           active = false
        case .hosting, .joining, .negotiating, .open:  active = true
        }
        if active, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled, reason: "bluesteal relay session active")
            tracer.log("tunnel", "sleep.prevent", ["on": true])
        } else if !active, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
            tracer.log("tunnel", "sleep.prevent", ["on": false])
        }
    }

    // MARK: - Peer-liveness watchdog

    /// Runs for both roles once a session is open. If no frame arrives from the
    /// far side for `peerSilenceTimeout` while open, self-heal: a host re-hosts
    /// + republishes; a rendezvous peer re-joins. A plain typed-join peer has no
    /// re-join path, so it is left to the socket error to surface the drop.
    private func startLivenessWatchdog() {
        guard persistentHost || rendezvousRoom != nil else { return }
        livenessTask?.cancel()
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard case .open = self.state else { continue }
                guard Date().timeIntervalSince(self.lastPeerFrameAt) > Self.peerSilenceTimeout else { continue }
                let silentFor = Int(Date().timeIntervalSince(self.lastPeerFrameAt))
                if self.persistentHost {
                    self.tracer.log("tunnel", "peer.silent", ["silentFor": silentFor])
                    self.restartHostLoop(reason: "peer_timeout")
                    return
                } else if self.rendezvousRoom != nil {
                    self.tracer.log("tunnel", "peer.host_silent", ["silentFor": silentFor])
                    self.restartRendezvousJoin(reason: "host_timeout")
                    return
                }
            }
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
        persistentHost = false
        rendezvousRoom = nil
        hostLoopTask?.cancel(); hostLoopTask = nil
        rendezvousTask?.cancel(); rendezvousTask = nil
        livenessTask?.cancel(); livenessTask = nil
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
        // Note: rendezvousRoom is deliberately NOT cleared here — the rendezvous
        // re-join path calls joinInternal() (which calls this) and must keep the
        // room. The public host()/join() entrypoints set it explicitly.
        persistentHost = false
        hostLoopTask?.cancel(); hostLoopTask = nil
        livenessTask?.cancel(); livenessTask = nil
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
