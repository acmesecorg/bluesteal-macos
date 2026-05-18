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

    private(set) var state: State = .idle
    private(set) var messagesSent = 0
    private(set) var messagesReceived = 0
    private(set) var isUsingTURN = false

    /// Inbound application messages (non-bye). Set by `AdvertRelay`.
    var onMessage: ((RelayMessage) -> Void)?

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
    private let delegateProxy = WebRTCDelegateProxy()

    private var pendingLocalCandidates: [RTCIceCandidate] = []
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var hasRemoteDescription = false

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

    init() {
        delegateProxy.owner = self
    }

    // MARK: - Public API

    @discardableResult
    func host() -> String {
        let code = SignalingClient.makeCode()
        role = .host
        state = .hosting(code: code)
        startSignaling(code: code, role: .host)
        createPeerConnection()

        let cfg = RTCDataChannelConfiguration()
        cfg.isOrdered = true
        dataChannel = peerConnection?.dataChannel(forLabel: "bluesteal.adverts", configuration: cfg)
        dataChannel?.delegate = delegateProxy

        createOffer()
        return code
    }

    func join(code: String) {
        role = .peer
        state = .joining(code: code)
        startSignaling(code: code, role: .peer)
        createPeerConnection()
        // Peer's data channel arrives via peerConnection(_:didOpen:).
    }

    func disconnect(reason: String = "user") {
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
        guard let dataChannel, dataChannel.readyState == .open,
              let data = try? encoder.encode(message) else { return }
        let buffer = RTCDataBuffer(data: data, isBinary: false)
        dataChannel.sendData(buffer)
        if case .advert = message { messagesSent += 1 }
    }

    // MARK: - Setup

    private func startSignaling(code: String, role: SignalingClient.Role) {
        let client = SignalingClient(role: role, code: code)
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
        pc.offer(for: constraints) { [weak self] sdp, _ in
            Task { @MainActor in
                guard let self, let sdp else { return }
                pc.setLocalDescription(sdp) { _ in
                    Task { @MainActor in
                        self.signaling?.publish(.offer(sdp: sdp.sdp))
                    }
                }
            }
        }
    }

    private func createAnswer() {
        guard let pc = peerConnection else { return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc.answer(for: constraints) { [weak self] sdp, _ in
            Task { @MainActor in
                guard let self, let sdp else { return }
                pc.setLocalDescription(sdp) { _ in
                    Task { @MainActor in
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
            guard role == .peer else { return }
            let remote = RTCSessionDescription(type: .offer, sdp: sdp)
            pc.setRemoteDescription(remote) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.hasRemoteDescription = true
                    self.state = .negotiating
                    self.drainPendingRemoteCandidates()
                    self.createAnswer()
                }
            }

        case .answer(let sdp):
            guard role == .host else { return }
            let remote = RTCSessionDescription(type: .answer, sdp: sdp)
            pc.setRemoteDescription(remote) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.hasRemoteDescription = true
                    self.state = .negotiating
                    self.drainPendingRemoteCandidates()
                    self.flushLocalCandidates()
                }
            }

        case .ice(let cand):
            let candidate = RTCIceCandidate(sdp: cand.sdp,
                                            sdpMLineIndex: cand.sdpMLineIndex,
                                            sdpMid: cand.sdpMid)
            if hasRemoteDescription {
                pc.add(candidate) { _ in }
            } else {
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
        for c in pending { pc.add(c) { _ in } }
    }

    private func flushLocalCandidates() {
        let pending = pendingLocalCandidates
        pendingLocalCandidates.removeAll()
        for c in pending { publish(local: c) }
    }

    private func publish(local candidate: RTCIceCandidate) {
        signaling?.publish(.ice(.init(sdp: candidate.sdp,
                                      sdpMid: candidate.sdpMid,
                                      sdpMLineIndex: candidate.sdpMLineIndex)))
    }

    // MARK: - Delegate callbacks (called by proxy on main)

    fileprivate func didGenerateLocalIce(_ candidate: RTCIceCandidate) {
        if hasRemoteDescription {
            publish(local: candidate)
        } else {
            pendingLocalCandidates.append(candidate)
        }
    }

    fileprivate func didOpenRemoteDataChannel(_ channel: RTCDataChannel) {
        dataChannel = channel
        channel.delegate = delegateProxy
    }

    fileprivate func didChangeIceState(_ newState: RTCIceConnectionState) {
        switch newState {
        case .failed:
            state = .closed(reason: "ICE failed")
        default:
            break  // wait for data channel .open
        }
    }

    fileprivate func dataChannelDidChange(_ channel: RTCDataChannel) {
        switch channel.readyState {
        case .open:
            state = .open(role: role)
            signaling?.disconnect()
            signaling = nil
        case .closed:
            if case .open = state { state = .closed(reason: "data channel closed") }
        default:
            break
        }
    }

    fileprivate func dataChannelDidReceive(_ buffer: RTCDataBuffer) {
        guard let message = try? decoder.decode(RelayMessage.self, from: buffer.data) else { return }
        if case .advert = message { messagesReceived += 1 }
        if case .bye(let reason) = message {
            disconnect(reason: "peer: \(reason)")
            return
        }
        onMessage?(message)
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
                        didChange newState: RTCIceGatheringState) {}

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
