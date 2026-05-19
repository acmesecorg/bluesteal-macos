//
//  SignalingClient.swift
//  bluesteal
//

import Foundation
import CocoaMQTT
import CocoaMQTTWebSocket

/// Thin MQTT wrapper that runs the ~5-second WebRTC pairing handshake over a
/// public broker. Topics:
///
///   bluesteal/v1/<code>/offer        (retained — host publishes once)
///   bluesteal/v1/<code>/answer       (peer publishes once)
///   bluesteal/v1/<code>/ice/host     (host trickle ICE)
///   bluesteal/v1/<code>/ice/peer     (peer trickle ICE)
///   bluesteal/v1/<code>/bye          (either side announces close)
///
/// Knows nothing about WebRTC; just emits `SignalingMessage`s up to whoever
/// owns it.
@MainActor
final class SignalingClient {

    enum Role { case host, peer }

    /// Public broker endpoints, tried in order until one connects.
    struct Broker {
        let host: String
        let port: UInt16
        let path: String     // WebSocket path (usually "/mqtt")
        let useTLS: Bool

        static let hiveMQ      = Broker(host: "broker.hivemq.com",   port: 8884, path: "/mqtt", useTLS: true)
        static let emqx        = Broker(host: "broker.emqx.io",      port: 8084, path: "/mqtt", useTLS: true)
        static let mosquitto   = Broker(host: "test.mosquitto.org",  port: 8081, path: "/mqtt", useTLS: true)
        static let fallbacks: [Broker] = [hiveMQ, emqx, mosquitto]
    }

    /// Alphabet used for pairing codes — uppercase letters with the ambiguous
    /// I, L, O removed. **Must match Windows `SignalingClient.cs` exactly**:
    /// the FNV-1a hash of the code drives the starting-broker selection on
    /// both sides, so any divergence (length, alphabet, casing) breaks
    /// cross-platform pairing.
    static let codeAlphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ")

    /// Length of a generated pairing code. 5 letters from a 23-letter
    /// alphabet ≈ 6.4 M combinations — plenty for a short-lived MQTT topic.
    static let codeLength = 5

    /// Generate a fresh pairing code. The code lives only as long as the
    /// broker session and is human-typed across devices, so we favour
    /// ease-of-typing over entropy.
    static func makeCode() -> String {
        String((0..<codeLength).map { _ in codeAlphabet.randomElement()! })
    }

    static func topicRoot(for code: String) -> String { "bluesteal/v1/\(code)" }

    // MARK: - Public surface

    var onConnect: (() -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var onMessage: ((SignalingMessage) -> Void)?

    private(set) var isConnected = false

    private let role: Role
    private let code: String
    private let brokers: [Broker]
    private var brokerIndex = 0
    private var attemptCount = 0
    private let tracer: RelayTracer?

    private var mqtt: CocoaMQTT?
    private let delegateProxy = MQTTDelegateProxy()

    /// Per-broker connect timeout. **Must match the Windows side exactly**
    /// (`SignalingClient.cs` `s_perBrokerTimeout`) or cross-platform pairing
    /// breaks: if one side has a longer budget it may successfully connect
    /// to broker N while the other side times out and walks to broker N+1,
    /// publishing/listening on different brokers for the same pairing code.
    /// Once both sides time out the same broker at the same elapsed time
    /// they walk the deterministic FNV-1a-seeded list in lock-step and end
    /// up on whichever broker is reachable from both.
    private static let perBrokerTimeout: TimeInterval = 6

    /// In-flight connect timeout for the current attempt. Cancelled on
    /// success or explicit disconnect; if it fires the active broker is
    /// torn down and the next one is tried.
    private var connectTimeoutItem: DispatchWorkItem?

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

    init(role: Role, code: String, tracer: RelayTracer? = nil, brokers: [Broker]? = nil) {
        self.role = role
        self.code = code
        self.tracer = tracer
        self.brokers = brokers ?? Broker.fallbacks
    }

    func connect() {
        brokerIndex = startingBrokerIndex()
        attemptCount = 0
        tracer?.log("mqtt", "mqtt.connect.start", [
            "role": "\(role)",
            "code": code,
            "brokerCount": brokers.count,
            "startingBrokerIndex": brokerIndex,
            "startingBroker": brokers[brokerIndex].host,
            "perBrokerTimeoutMs": Int(Self.perBrokerTimeout * 1000)
        ])
        connect(to: brokerIndex)
    }

    /// Picks a deterministic starting broker by hashing the pairing code with
    /// FNV-1a. Both Host and Peer call this with the same code, so they
    /// always attempt brokers in the same order. Mirrors
    /// `SignalingClient.StartingBrokerIndex` on the Windows side — keep the
    /// algorithm and broker list in sync or cross-platform pairing breaks.
    private func startingBrokerIndex() -> Int {
        var hash: UInt32 = 2166136261
        for byte in code.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        return Int(hash % UInt32(brokers.count))
    }

    private func connect(to index: Int) {
        guard attemptCount < brokers.count else {
            tracer?.log("error", "mqtt.connect.exhausted", ["triedBrokers": brokers.count])
            onDisconnect?(NSError(domain: "Signaling", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "All brokers unreachable"]))
            return
        }
        brokerIndex = index
        attemptCount += 1
        let broker = brokers[index]

        tracer?.log("mqtt", "mqtt.connect.attempt", [
            "index": index,
            "host": broker.host,
            "port": Int(broker.port),
            "tls": broker.useTLS,
            "attempt": attemptCount
        ])

        let socket = CocoaMQTTWebSocket(uri: broker.path)
        let clientID = "bluesteal-\(role)-\(UUID().uuidString.prefix(8))"
        let client = CocoaMQTT(clientID: clientID,
                               host: broker.host,
                               port: broker.port,
                               socket: socket)
        client.enableSSL = broker.useTLS
        client.keepAlive = 30
        client.autoReconnect = false
        client.cleanSession = true
        client.delegate = delegateProxy
        delegateProxy.owner = self
        self.mqtt = client

        scheduleConnectTimeout(forIndex: index)
        _ = client.connect()
    }

    private func scheduleConnectTimeout(forIndex index: Int) {
        connectTimeoutItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleConnectTimeout(forIndex: index)
            }
        }
        connectTimeoutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.perBrokerTimeout, execute: item)
    }

    private func cancelConnectTimeout() {
        connectTimeoutItem?.cancel()
        connectTimeoutItem = nil
    }

    /// Called when the 6-second per-broker timeout fires. If this attempt is
    /// still in flight (no `didConnect`, no `didDisconnect` advance), tear
    /// the client down and advance to the next broker.
    private func handleConnectTimeout(forIndex index: Int) {
        // The race: a successful or failing connect callback may have already
        // advanced us; in that case `brokerIndex` has moved or `isConnected`
        // is true. Either way, this timeout is stale.
        guard brokerIndex == index, !isConnected, mqtt != nil else { return }
        let broker = brokers[index]
        tracer?.log("error", "mqtt.connect.timeout", [
            "index": index,
            "host": broker.host,
            "timeoutMs": Int(Self.perBrokerTimeout * 1000)
        ])
        // Detach the dying client first so its `didDisconnect` callback (which
        // will fire when we call disconnect below) becomes a no-op rather than
        // re-entering the broker-walking path.
        let dying = mqtt
        mqtt = nil
        dying?.disconnect()

        advanceToNextBroker()
    }

    private func advanceToNextBroker() {
        guard attemptCount < brokers.count else {
            tracer?.log("error", "mqtt.connect.exhausted", ["triedBrokers": brokers.count])
            onDisconnect?(NSError(domain: "Signaling", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "All brokers unreachable"]))
            return
        }
        let next = (brokerIndex + 1) % brokers.count
        connect(to: next)
    }

    func disconnect() {
        tracer?.log("mqtt", "mqtt.disconnect.requested")
        cancelConnectTimeout()
        let dying = mqtt
        mqtt = nil
        isConnected = false
        // Cap the attempt counter so any late `didDisconnect` from `dying`
        // doesn't kick off another broker walk.
        attemptCount = brokers.count
        dying?.disconnect()
    }

    // MARK: - Send

    func publish(_ message: SignalingMessage) {
        let typeName = Self.signalingTypeName(message)
        guard let mqtt, isConnected else {
            tracer?.log("signaling", "signaling.publish.skipped",
                        ["reason": "not connected", "type": typeName])
            return
        }
        let root = Self.topicRoot(for: code)
        let topic: String
        let retain: Bool
        switch message {
        case .offer:   topic = "\(root)/offer";  retain = true
        case .answer:  topic = "\(root)/answer"; retain = false
        case .ice:     topic = "\(root)/ice/\(role == .host ? "host" : "peer")"; retain = false
        case .bye:     topic = "\(root)/bye";    retain = false
        }
        let data: Data
        let body: String
        do {
            data = try encoder.encode(message)
            guard let s = String(data: data, encoding: .utf8) else {
                tracer?.log("error", "signaling.publish.error",
                            ["type": typeName, "topic": topic, "error": "utf8 decode"])
                return
            }
            body = s
        } catch {
            tracer?.log("error", "signaling.publish.error",
                        ["type": typeName, "topic": topic, "error": "\(error)"])
            return
        }
        tracer?.log("signaling", "signaling.publish",
                    ["type": typeName,
                     "topic": topic,
                     "retain": retain,
                     "payloadBytes": data.count,
                     "preview": Self.preview(body)])
        mqtt.publish(topic, withString: body, qos: .qos1, retained: retain)
    }

    // MARK: - Delegate callbacks (invoked by proxy on main)

    fileprivate func didConnect(client: CocoaMQTT) {
        // Reject stale callbacks from a previous broker attempt that we've
        // already abandoned (timeout fired, explicit disconnect, etc.). The
        // hazard: CocoaMQTT may surface the result of attempt N's connect()
        // after we've moved on to attempt N+1.
        guard client === self.mqtt else {
            tracer?.log("mqtt", "mqtt.connected.ignored", ["reason": "stale client"])
            return
        }
        cancelConnectTimeout()
        isConnected = true
        let root = Self.topicRoot(for: code)
        guard let mqtt else { return }

        var topics: [String] = []
        switch role {
        case .host:
            topics.append("\(root)/answer")
            topics.append("\(root)/ice/peer")
        case .peer:
            topics.append("\(root)/offer")
            topics.append("\(root)/ice/host")
        }
        topics.append("\(root)/bye")

        for t in topics { mqtt.subscribe(t, qos: .qos1) }

        let broker = brokers[brokerIndex]
        tracer?.log("mqtt", "mqtt.connected",
                    ["host": broker.host, "port": Int(broker.port), "tls": broker.useTLS])
        tracer?.log("mqtt", "mqtt.subscribed", ["role": "\(role)", "topics": topics])

        onConnect?()
    }

    fileprivate func didReceive(topic: String, payload: String) {
        // Ignore our own messages echoed back (retained offer when host reconnects, etc.).
        if isOwnOrigin(topic: topic) {
            tracer?.log("signaling", "signaling.receive.filtered",
                        ["topic": topic,
                         "payloadBytes": payload.utf8.count,
                         "reason": "ownOrigin"])
            return
        }
        guard let data = payload.data(using: .utf8) else {
            tracer?.log("signaling", "signaling.receive.empty", ["topic": topic])
            return
        }
        do {
            let message = try decoder.decode(SignalingMessage.self, from: data)
            tracer?.log("signaling", "signaling.receive",
                        ["topic": topic,
                         "payloadBytes": data.count,
                         "parsedType": Self.signalingTypeName(message)])
            onMessage?(message)
        } catch {
            tracer?.log("error", "signaling.parse.error",
                        ["topic": topic,
                         "error": "\(error)",
                         "payloadPreview": Self.preview(payload)])
        }
    }

    fileprivate func didDisconnect(client: CocoaMQTT, error: Error?) {
        // Reject stale disconnect callbacks from a previous broker attempt.
        // After a timeout or explicit `disconnect()` we tear down the old
        // client and start a new one; CocoaMQTT may still deliver the old
        // client's `mqttDidDisconnect` afterwards.
        guard client === self.mqtt else {
            tracer?.log("mqtt", "mqtt.disconnected.ignored",
                        ["reason": "stale client",
                         "error": error?.localizedDescription ?? ""])
            return
        }
        cancelConnectTimeout()
        let wasConnected = isConnected
        isConnected = false
        tracer?.log("mqtt", "mqtt.disconnected",
                    ["wasConnected": wasConnected,
                     "error": error?.localizedDescription ?? ""])
        if !wasConnected {
            tracer?.log("mqtt", "mqtt.connect.failed",
                        ["index": brokerIndex,
                         "host": brokers[brokerIndex].host,
                         "error": error?.localizedDescription ?? "disconnected"])
            // Detach the failed client so a duplicate `didDisconnect` from
            // CocoaMQTT (some failure paths fire twice) doesn't re-enter.
            mqtt = nil
            advanceToNextBroker()
            return
        }
        onDisconnect?(error)
    }

    private func isOwnOrigin(topic: String) -> Bool {
        switch role {
        case .host: return topic.hasSuffix("/ice/host") || topic.hasSuffix("/offer")
        case .peer: return topic.hasSuffix("/ice/peer") || topic.hasSuffix("/answer")
        }
    }

    nonisolated static func signalingTypeName(_ m: SignalingMessage) -> String {
        switch m {
        case .offer:  return "offer"
        case .answer: return "answer"
        case .ice:    return "ice"
        case .bye:    return "bye"
        }
    }

    nonisolated static func preview(_ s: String) -> String {
        if s.count <= 120 { return s }
        let idx = s.index(s.startIndex, offsetBy: 120)
        return String(s[..<idx]) + "…(+\(s.count - 120))"
    }
}

// MARK: - Delegate proxy

/// CocoaMQTT requires an NSObject delegate. Proxy keeps `SignalingClient`
/// a plain Swift class.
private final class MQTTDelegateProxy: NSObject, CocoaMQTTDelegate {
    weak var owner: SignalingClient?

    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        guard ack == .accept else {
            let err = NSError(domain: "Signaling", code: Int(ack.rawValue),
                              userInfo: [NSLocalizedDescriptionKey: "MQTT connect refused: \(ack)"])
            Task { @MainActor in self.owner?.didDisconnect(client: mqtt, error: err) }
            return
        }
        Task { @MainActor in self.owner?.didConnect(client: mqtt) }
    }

    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        let topic = message.topic
        let body = message.string ?? ""
        Task { @MainActor in self.owner?.didReceive(topic: topic, payload: body) }
    }

    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        Task { @MainActor in self.owner?.didDisconnect(client: mqtt, error: err) }
    }

    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    func mqttDidPing(_ mqtt: CocoaMQTT) {}
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}

    /// CocoaMQTT's WSS path (`CocoaMQTTWebSocket.FoundationConnection`)
    /// forwards every TLS auth challenge from `URLSessionWebSocketTask` to
    /// this optional delegate method. If nobody resolves the completion
    /// handler, the WSS task waits for its internal challenge timeout to
    /// fire and then cancels with "certificate unknown" — which surfaced as
    /// `boringssl_context_certificate_verify_callback FAIL` for all three
    /// public brokers despite the certs being valid. Defer to the OS's
    /// default trust evaluation; for public brokers like HiveMQ / EMQX /
    /// Mosquitto that's exactly what we want.
    func mqtt(_ mqtt: CocoaMQTT, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
