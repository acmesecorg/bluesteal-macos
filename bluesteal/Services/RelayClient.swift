//
//  RelayClient.swift
//  bluesteal
//

import Foundation
@preconcurrency import WebRTC
import Observation

/// Orchestrates a WebRTC DataChannel between two bluesteal instances paired
/// by an 8-char code. The handshake (SDP + ICE) travels over a public MQTT
/// broker via `SignalingClient`; once `RTCDataChannel` is open we drop off
/// the broker and the channel is the only path used.
@MainActor
@Observable
final class RelayClient {

    enum Role { case host, peer }
    enum State: Equatable {
        case idle
        case hosting(code: String)
        case joining(code: String)
        case negotiating
        case open(role: Role)
        case closed(reason: String)
    }

    private(set) var state: State = .idle {
        didSet { traceStateChange(from: oldValue, to: state) }
    }
    private(set) var messagesSent = 0
    private(set) var messagesReceived = 0
    private(set) var isUsingTURN = false

    /// Inbound application messages (non-bye). Set by `AdvertRelay`.
    var onMessage: ((RelayMessage) -> Void)?

    /// Fires on every distinct `state` transition. Set by `AdvertRelay` to
    /// drive the heartbeat loop (start on `.open`, stop on anything else).
    var onStateChange: ((State) -> Void)?

    // MARK: - WebRTC plumbing

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoders = RTCDefaultVideoEncoderFactory()
        let decoders = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: encoders, decoderFactory: decoders)
    }()

    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var signaling: SignalingClient?
    private var role: Role = .host
    private var code: String = ""
    private let delegateProxy = WebRTCDelegateProxy()

    private var pendingLocalCandidates: [RTCIceCandidate] = []
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var hasRemoteDescription = false

    /// Flipped true by `disconnect()`. Late callbacks (signaling.onConnect
    /// arriving after the user cancelled, ondatachannel firing during
    /// teardown) check this and bail rather than touching a torn-down peer
    /// connection.
    private var isTornDown = false

    private let tracer: RelayTracer

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(tracer: RelayTracer) {
        self.tracer = tracer
        delegateProxy.owner = self
    }

    // MARK: - Public API

    @discardableResult
    func host() -> String {
        let code = SignalingClient.makeCode()
        self.code = code
        role = .host
        isTornDown = false
        tracer.setContext(role: "Host", code: code)
        tracer.log("relay", "relay.host", ["code": code])
        state = .hosting(code: code)
        // Peer connection is created up front so ICE gathering can start, but
        // the data channel + offer are deferred to `signalingDidConnect()` so
        // we don't publish an offer the broker never received.
        createPeerConnection()
        startSignaling(code: code, role: .host)
        return code
    }

    func join(code: String) {
        self.code = code
        role = .peer
        isTornDown = false
        tracer.setContext(role: "Peer", code: code)
        tracer.log("relay", "relay.join", ["code": code])
        state = .joining(code: code)
        createPeerConnection()
        startSignaling(code: code, role: .peer)
        // Peer's data channel arrives via peerConnection(_:didOpen:).
    }

    func disconnect(reason: String = "user") {
        tracer.log("relay", "relay.disconnect", ["reason": reason])
        isTornDown = true
        if signaling?.isConnected == true {
            signaling?.publish(.bye(reason: reason))
        }
        signaling?.disconnect()
        signaling = nil
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        hasRemoteDescription = false
        pendingLocalCandidates.removeAll()
        pendingRemoteCandidates.removeAll()
        state = .closed(reason: reason)
    }

    func send(_ message: RelayMessage) {
        let typeName = messageTypeName(message)
        guard let dataChannel else {
            tracer.log("dc", "dc.send.skipped", ["reason": "no channel", "type": typeName])
            return
        }
        guard dataChannel.readyState == .open else {
            tracer.log("dc", "dc.send.skipped",
                       ["reason": "state \(dataChannel.readyState.rawValue)", "type": typeName])
            return
        }
        let data: Data
        do {
            data = try encoder.encode(message)
        } catch {
            tracer.log("error", "dc.send.error",
                       ["type": typeName, "error": "\(error)"])
            return
        }
        let buffer = RTCDataBuffer(data: data, isBinary: false)
        dataChannel.sendData(buffer)
        tracer.log("dc", "dc.send", ["type": typeName, "payloadBytes": data.count])
        if case .advert = message { messagesSent += 1 }
    }

    // MARK: - Setup

    private func startSignaling(code: String, role: SignalingClient.Role) {
        let client = SignalingClient(role: role, code: code, tracer: tracer)
        client.onConnect = { [weak self] in
            self?.signalingDidConnect()
        }
        client.onDisconnect = { [weak self] err in
            guard let self else { return }
            if case .open = self.state { return }   // ignore: handshake already done
            self.state = .closed(reason: "signaling: \(err?.localizedDescription ?? "disconnected")")
        }
        client.onMessage = { [weak self] msg in
            self?.handleSignaling(msg)
        }
        signaling = client
        client.connect()
    }

    /// Called once the MQTT signaling broker is connected and subscribed.
    /// For the Host this is where the data channel is created and the SDP
    /// offer is published; for the Peer there's nothing to do — the offer
    /// will arrive via `handleSignaling`.
    ///
    /// Guards against a late arrival after `disconnect()`: if the session
    /// has been torn down or the peer connection is gone, the callback is a
    /// no-op (mirrors `relay.signaling.connected.ignored` on Windows).
    private func signalingDidConnect() {
        tracer.log("relay", "relay.signaling.connected", ["role": "\(role)"])
        guard !isTornDown, peerConnection != nil, signaling != nil else {
            tracer.log("relay", "relay.signaling.connected.ignored",
                       ["state": Self.stateLabel(state),
                        "isTornDown": isTornDown,
                        "hasPC": peerConnection != nil,
                        "hasSignaling": signaling != nil])
            return
        }
        guard role == .host else { return }

        let cfg = RTCDataChannelConfiguration()
        cfg.isOrdered = true
        dataChannel = peerConnection?.dataChannel(forLabel: "bluesteal.adverts", configuration: cfg)
        dataChannel?.delegate = delegateProxy
        tracer.log("dc", "dc.created", ["label": "bluesteal.adverts"])

        createOffer()
    }

    private func createPeerConnection() {
        let config = RTCConfiguration()
        config.iceServers = Self.defaultIceServers()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        peerConnection = Self.factory.peerConnection(with: config,
                                                      constraints: constraints,
                                                      delegate: delegateProxy)
    }

    private static func defaultIceServers() -> [RTCIceServer] {
        return [
            RTCIceServer(urlStrings: [
                "stun:stun.l.google.com:19302",
                "stun:stun1.l.google.com:19302",
                "stun:stun.cloudflare.com:3478"
            ]),
            RTCIceServer(urlStrings: ["turn:openrelay.metered.ca:80"],
                         username: "openrelayproject",
                         credential: "openrelayproject"),
            RTCIceServer(urlStrings: ["turn:openrelay.metered.ca:443"],
                         username: "openrelayproject",
                         credential: "openrelayproject")
        ]
    }

    // MARK: - Offer / answer

    private func createOffer() {
        guard let pc = peerConnection else { return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc.offer(for: constraints) { [weak self] sdp, error in
            Task { @MainActor in
                guard let self else { return }
                guard let sdp else {
                    self.tracer.log("error", "pc.createOffer.error",
                                    ["error": "\(error?.localizedDescription ?? "no sdp")"])
                    return
                }
                self.tracer.log("pc", "pc.createOffer", ["sdpBytes": sdp.sdp.count])
                pc.setLocalDescription(sdp) { err in
                    Task { @MainActor in
                        self.tracer.log("pc", "pc.setLocalDescription",
                                        ["type": "offer",
                                         "result": err?.localizedDescription ?? "OK"])
                        self.signaling?.publish(.offer(sdp: sdp.sdp))
                    }
                }
            }
        }
    }

    private func createAnswer() {
        guard let pc = peerConnection else { return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc.answer(for: constraints) { [weak self] sdp, error in
            Task { @MainActor in
                guard let self else { return }
                guard let sdp else {
                    self.tracer.log("error", "pc.createAnswer.error",
                                    ["error": "\(error?.localizedDescription ?? "no sdp")"])
                    return
                }
                self.tracer.log("pc", "pc.createAnswer", ["sdpBytes": sdp.sdp.count])
                pc.setLocalDescription(sdp) { err in
                    Task { @MainActor in
                        self.tracer.log("pc", "pc.setLocalDescription",
                                        ["type": "answer",
                                         "result": err?.localizedDescription ?? "OK"])
                        self.signaling?.publish(.answer(sdp: sdp.sdp))
                        self.flushLocalCandidates()
                    }
                }
            }
        }
    }

    // MARK: - Signaling inbound

    private func handleSignaling(_ message: SignalingMessage) {
        guard let pc = peerConnection else { return }
        switch message {
        case .offer(let sdp):
            guard role == .peer else {
                tracer.log("signaling", "signaling.unexpected",
                           ["type": "offer", "role": "host"])
                return
            }
            let remote = RTCSessionDescription(type: .offer, sdp: sdp)
            pc.setRemoteDescription(remote) { [weak self] err in
                Task { @MainActor in
                    guard let self else { return }
                    self.tracer.log("pc", "pc.setRemoteDescription",
                                    ["type": "offer",
                                     "result": err?.localizedDescription ?? "OK"])
                    guard err == nil else { return }
                    self.hasRemoteDescription = true
                    self.state = .negotiating
                    self.drainPendingRemoteCandidates()
                    self.createAnswer()
                }
            }

        case .answer(let sdp):
            guard role == .host else {
                tracer.log("signaling", "signaling.unexpected",
                           ["type": "answer", "role": "peer"])
                return
            }
            let remote = RTCSessionDescription(type: .answer, sdp: sdp)
            pc.setRemoteDescription(remote) { [weak self] err in
                Task { @MainActor in
                    guard let self else { return }
                    self.tracer.log("pc", "pc.setRemoteDescription",
                                    ["type": "answer",
                                     "result": err?.localizedDescription ?? "OK"])
                    guard err == nil else { return }
                    self.hasRemoteDescription = true
                    self.state = .negotiating
                    self.drainPendingRemoteCandidates()
                    self.flushLocalCandidates()
                }
            }

        case .ice(let cand):
            // SIPSorcery on Windows emits the bare candidate value
            // (`foundation component proto …`) without the `candidate:`
            // prefix. Google's WebRTC (used here on macOS) follows the W3C
            // spec strictly and rejects strings that don't start with
            // `candidate:`. Normalise defensively — accepts both forms.
            let normalisedSdp = cand.sdp.hasPrefix("candidate:")
                ? cand.sdp
                : "candidate:" + cand.sdp
            let candidate = RTCIceCandidate(sdp: normalisedSdp,
                                            sdpMLineIndex: cand.sdpMLineIndex,
                                            sdpMid: cand.sdpMid)
            if hasRemoteDescription {
                tracer.log("ice", "ice.remote.apply",
                           ["type": Self.candidateType(cand.sdp),
                            "sdpMid": cand.sdpMid ?? "",
                            "sdpMLineIndex": Int(cand.sdpMLineIndex),
                            "sdpMidIsNil": cand.sdpMid == nil,
                            "sdp": cand.sdp])
                pc.add(candidate) { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error {
                            self.tracer.log("error", "ice.remote.add.error",
                                            ["error": "\(error)",
                                             "sdpMid": cand.sdpMid ?? "",
                                             "type": Self.candidateType(cand.sdp)])
                        } else {
                            self.tracer.log("ice", "ice.remote.add.ok",
                                            ["type": Self.candidateType(cand.sdp)])
                        }
                    }
                }
            } else {
                tracer.log("ice", "ice.remote.buffer",
                           ["type": Self.candidateType(cand.sdp),
                            "sdpMid": cand.sdpMid ?? "",
                            "sdpMidIsNil": cand.sdpMid == nil])
                pendingRemoteCandidates.append(candidate)
            }

        case .bye(let reason):
            disconnect(reason: "peer: \(reason)")
        }
    }

    private func drainPendingRemoteCandidates() {
        guard let pc = peerConnection else { return }
        let pending = pendingRemoteCandidates
        pendingRemoteCandidates.removeAll()
        tracer.log("ice", "ice.remote.drain", ["count": pending.count])
        for c in pending {
            pc.add(c) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.tracer.log("error", "ice.remote.add.error",
                                        ["error": "\(error)",
                                         "sdpMid": c.sdpMid ?? "",
                                         "type": Self.candidateType(c.sdp),
                                         "drained": true])
                    } else {
                        self.tracer.log("ice", "ice.remote.add.ok",
                                        ["type": Self.candidateType(c.sdp),
                                         "drained": true])
                    }
                }
            }
        }
    }

    private func flushLocalCandidates() {
        let pending = pendingLocalCandidates
        pendingLocalCandidates.removeAll()
        tracer.log("ice", "ice.local.flush", ["count": pending.count])
        for c in pending { publish(local: c) }
    }

    private func publish(local candidate: RTCIceCandidate) {
        signaling?.publish(.ice(.init(sdp: candidate.sdp,
                                      sdpMid: candidate.sdpMid,
                                      sdpMLineIndex: candidate.sdpMLineIndex)))
    }

    // MARK: - Delegate callbacks (called by proxy on main)

    fileprivate func didGenerateLocalIce(_ candidate: RTCIceCandidate) {
        let type = Self.candidateType(candidate.sdp)
        let buffered = !hasRemoteDescription
        tracer.log("ice", "ice.local",
                   ["type": type,
                    "sdpMid": candidate.sdpMid ?? "",
                    "sdpMLineIndex": Int(candidate.sdpMLineIndex),
                    "buffered": buffered])
        if hasRemoteDescription {
            publish(local: candidate)
        } else {
            pendingLocalCandidates.append(candidate)
        }
    }

    fileprivate func didOpenRemoteDataChannel(_ channel: RTCDataChannel) {
        tracer.log("dc", "dc.received",
                   ["label": channel.label,
                    "state": "\(channel.readyState.rawValue)"])
        guard !isTornDown else {
            tracer.log("dc", "dc.received.ignored", ["reason": "torn down"])
            return
        }
        dataChannel = channel
        channel.delegate = delegateProxy
        // The peer often receives a data channel that is *already* in `.open`
        // by the time this delegate fires (the DTLS+SCTP handshake finishes
        // before WebRTC surfaces `didOpen`). Subscribing to state changes
        // after that point would never see the transition to open, so drive
        // the open path synchronously here.
        if channel.readyState == .open {
            tracer.log("dc", "dc.alreadyOpen", ["label": channel.label])
            dataChannelDidChange(channel)
        }
    }

    fileprivate func didChangeIceState(_ newState: RTCIceConnectionState) {
        tracer.log("ice", "ice.connectionState", ["state": "\(newState.rawValue)"])
        switch newState {
        case .failed:
            state = .closed(reason: "ICE failed")
        default:
            break  // wait for data channel .open
        }
    }

    fileprivate func didChangeIceGatheringState(_ newState: RTCIceGatheringState) {
        tracer.log("ice", "ice.gatheringState", ["state": "\(newState.rawValue)"])
    }

    fileprivate func dataChannelDidChange(_ channel: RTCDataChannel) {
        tracer.log("dc", "dc.stateChange",
                   ["label": channel.label, "state": "\(channel.readyState.rawValue)"])
        switch channel.readyState {
        case .open:
            tracer.log("dc", "dc.open", ["label": channel.label])
            state = .open(role: role)
            signaling?.disconnect()
            signaling = nil
        case .closed:
            tracer.log("dc", "dc.close",
                       ["label": channel.label, "state": stateDescription])
            if case .open = state { state = .closed(reason: "data channel closed") }
        default:
            break
        }
    }

    fileprivate func dataChannelDidReceive(_ buffer: RTCDataBuffer) {
        tracer.log("dc", "dc.message",
                   ["payloadBytes": buffer.data.count,
                    "jsonPreview": Self.preview(buffer.data)])
        let message: RelayMessage
        do {
            message = try decoder.decode(RelayMessage.self, from: buffer.data)
        } catch {
            tracer.log("error", "dc.parse.error",
                       ["error": "\(error)",
                        "jsonPreview": Self.preview(buffer.data)])
            return
        }
        if case .advert = message { messagesReceived += 1 }
        if case .bye(let reason) = message {
            disconnect(reason: "peer: \(reason)")
            return
        }
        onMessage?(message)
    }

    // MARK: - Trace helpers

    private func traceStateChange(from old: State, to new: State) {
        guard old != new else { return }
        tracer.log("state", "state.change",
                   ["from": Self.stateLabel(old), "to": Self.stateLabel(new)])
        onStateChange?(new)
    }

    private var stateDescription: String { Self.stateLabel(state) }

    private static func stateLabel(_ s: State) -> String {
        switch s {
        case .idle:                  return "idle"
        case .hosting(let c):        return "hosting(\(c))"
        case .joining(let c):        return "joining(\(c))"
        case .negotiating:           return "negotiating"
        case .open(let r):           return "open(\(r == .host ? "host" : "peer"))"
        case .closed(let reason):    return "closed(\(reason))"
        }
    }

    private func messageTypeName(_ m: RelayMessage) -> String {
        switch m {
        case .advert:    return "advert"
        case .heartbeat: return "heartbeat"
        case .bye:       return "bye"
        }
    }

    /// Parse the `typ X` keyword out of an SDP candidate line, for tracing.
    nonisolated static func candidateType(_ sdp: String) -> String {
        guard let range = sdp.range(of: "typ ") else { return "unknown" }
        let rest = sdp[range.upperBound...]
        let end = rest.firstIndex(of: " ") ?? rest.endIndex
        return String(rest[..<end])
    }

    nonisolated static func preview(_ data: Data) -> String {
        let s = String(data: data, encoding: .utf8) ?? "<binary \(data.count)b>"
        if s.count <= 120 { return s }
        let idx = s.index(s.startIndex, offsetBy: 120)
        return String(s[..<idx]) + "…(+\(s.count - 120))"
    }
}

// MARK: - Delegate proxy

/// WebRTC delegates require NSObject; proxy keeps `RelayClient` a clean
/// `@Observable` Swift class.
private final class WebRTCDelegateProxy: NSObject,
                                          RTCPeerConnectionDelegate,
                                          RTCDataChannelDelegate {
    weak var owner: RelayClient?

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCIceConnectionState) {
        Task { @MainActor in self.owner?.didChangeIceState(newState) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCIceGatheringState) {
        Task { @MainActor in self.owner?.didChangeIceGatheringState(newState) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in self.owner?.didGenerateLocalIce(candidate) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor in self.owner?.didOpenRemoteDataChannel(dataChannel) }
    }

    // MARK: RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor in self.owner?.dataChannelDidChange(dataChannel) }
    }

    func dataChannel(_ dataChannel: RTCDataChannel,
                     didReceiveMessageWith buffer: RTCDataBuffer) {
        Task { @MainActor in self.owner?.dataChannelDidReceive(buffer) }
    }
}
