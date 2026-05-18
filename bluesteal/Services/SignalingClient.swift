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

    /// 8 chars from an unambiguous alphabet (≈210B combinations).
    static func makeCode() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
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

    private var mqtt: CocoaMQTT?
    private let delegateProxy = MQTTDelegateProxy()

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

    init(role: Role, code: String, brokers: [Broker]? = nil) {
        self.role = role
        self.code = code
        self.brokers = brokers ?? Broker.fallbacks
    }

    func connect() {
        connect(to: brokerIndex)
    }

    private func connect(to index: Int) {
        guard index < brokers.count else {
            onDisconnect?(NSError(domain: "Signaling", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "All brokers unreachable"]))
            return
        }
        brokerIndex = index
        let broker = brokers[index]

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

        _ = client.connect()
    }

    func disconnect() {
        mqtt?.disconnect()
        mqtt = nil
        isConnected = false
    }

    // MARK: - Send

    func publish(_ message: SignalingMessage) {
        guard let mqtt, isConnected else { return }
        let root = Self.topicRoot(for: code)
        let topic: String
        let retain: Bool
        switch message {
        case .offer:   topic = "\(root)/offer";  retain = true
        case .answer:  topic = "\(root)/answer"; retain = false
        case .ice:     topic = "\(root)/ice/\(role == .host ? "host" : "peer")"; retain = false
        case .bye:     topic = "\(root)/bye";    retain = false
        }
        guard let data = try? encoder.encode(message),
              let body = String(data: data, encoding: .utf8) else { return }
        mqtt.publish(topic, withString: body, qos: .qos1, retained: retain)
    }

    // MARK: - Delegate callbacks (invoked by proxy on main)

    fileprivate func didConnect() {
        isConnected = true
        let root = Self.topicRoot(for: code)
        guard let mqtt else { return }

        switch role {
        case .host:
            mqtt.subscribe("\(root)/answer",   qos: .qos1)
            mqtt.subscribe("\(root)/ice/peer", qos: .qos1)
        case .peer:
            mqtt.subscribe("\(root)/offer",    qos: .qos1)
            mqtt.subscribe("\(root)/ice/host", qos: .qos1)
        }
        mqtt.subscribe("\(root)/bye", qos: .qos1)

        onConnect?()
    }

    fileprivate func didReceive(topic: String, payload: String) {
        // Ignore our own messages echoed back (retained offer when host reconnects, etc.).
        if isOwnOrigin(topic: topic) { return }
        guard let data = payload.data(using: .utf8) else { return }
        do {
            let message = try decoder.decode(SignalingMessage.self, from: data)
            onMessage?(message)
        } catch {
            #if DEBUG
            print("[Signaling] decode failed on \(topic): \(error)")
            #endif
        }
    }

    fileprivate func didDisconnect(error: Error?) {
        let wasConnected = isConnected
        isConnected = false
        if !wasConnected && brokerIndex + 1 < brokers.count {
            connect(to: brokerIndex + 1)
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
}

// MARK: - Delegate proxy

/// CocoaMQTT requires an NSObject delegate. Proxy keeps `SignalingClient`
/// a plain Swift class.
private final class MQTTDelegateProxy: NSObject, CocoaMQTTDelegate {
    weak var owner: SignalingClient?

    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        guard ack == .accept else {
            Task { @MainActor in self.owner?.didDisconnect(error:
                NSError(domain: "Signaling", code: Int(ack.rawValue),
                        userInfo: [NSLocalizedDescriptionKey: "MQTT connect refused: \(ack)"])) }
            return
        }
        Task { @MainActor in self.owner?.didConnect() }
    }

    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        let topic = message.topic
        let body = message.string ?? ""
        Task { @MainActor in self.owner?.didReceive(topic: topic, payload: body) }
    }

    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        Task { @MainActor in self.owner?.didDisconnect(error: err) }
    }

    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    func mqttDidPing(_ mqtt: CocoaMQTT) {}
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}
}
