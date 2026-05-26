// Live two-party bridging test over the real Google relay, exercising the
// ported Swift Noise stack end-to-end:
//   host  opens /cable/new/<tid>, reads routing_id, runs responder
//   peer  opens /cable/connect/<routing>/<tid>, runs initiator
//   both  exchange an encrypted ping in each direction
//
//   swift run TunnelProbe live2

import Foundation
import CryptoKit

private final class ProbeWS: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var cont: CheckedContinuation<HTTPURLResponse?, Error>?
    private var resolved = false

    func connect(url: URL, origin: String?) async throws -> HTTPURLResponse? {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        var req = URLRequest(url: url)
        req.setValue("fido.cable", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        if let origin { req.setValue(origin, forHTTPHeaderField: "Origin") }
        req.timeoutInterval = 15
        let task = session.webSocketTask(with: req)
        self.task = task
        return try await withCheckedThrowingContinuation { c in
            lock.lock(); cont = c; lock.unlock()
            task.resume()
        }
    }
    func send(_ d: [UInt8]) async throws { try await task!.send(.data(Data(d))) }
    func receive() async throws -> [UInt8] {
        switch try await task!.receive() {
        case .data(let d): return [UInt8](d)
        default: throw NSError(domain: "ws", code: -2)
        }
    }
    func close() { task?.cancel(with: .normalClosure, reason: nil); session?.invalidateAndCancel() }

    func urlSession(_ s: URLSession, webSocketTask t: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        resolve(.success(t.response as? HTTPURLResponse))
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
        if let e { resolve(.failure(e)) }
    }
    private func resolve(_ r: Result<HTTPURLResponse?, Error>) {
        lock.lock(); guard !resolved, let c = cont else { lock.unlock(); return }
        resolved = true; cont = nil; lock.unlock(); c.resume(with: r)
    }
}

func runLive2() async {
    print("=== live two-party bridging test (real relay + Swift Noise) ===")
    let hostName = "cable.ua5v.com"
    let code = "BSTL1"
    let ikm = Data(code.utf8)
    let psk = [UInt8](HKDFShim.derive(ikm: ikm, salt: Data(), info: Data("bluesteal/psk".utf8), length: 32))
    let seed = HKDFShim.derive(ikm: ikm, salt: Data(), info: Data("bluesteal/responder-static".utf8), length: 32)
    let responderStatic = CableP256.deriveKeyFromSeed(seed)
    let responderPub = [UInt8](CableP256.exportPublicKeyX962(responderStatic))

    let minute = Int64(Date().timeIntervalSince1970) / 60
    var le = minute.littleEndian
    let salt = withUnsafeBytes(of: &le) { Data($0) }
    let tid = [UInt8](HKDFShim.derive(ikm: ikm, salt: salt, info: Data("bluesteal/tunnel-minute".utf8), length: 16))
    let tidHex = Data(tid).hexUpper

    let hostWS = ProbeWS()
    do {
        let resp = try await hostWS.connect(url: URL(string: "wss://\(hostName)/cable/new/\(tidHex)")!,
                                             origin: "wss://\(hostName)")
        guard let routingHex = resp?.value(forHTTPHeaderField: "X-caBLE-Routing-ID"),
              let routing = Data(hexString: routingHex) else {
            print("  FAIL host open / routing-id"); hostWS.close(); return
        }
        print("  host open, routing=\(routingHex)")

        let peerWS = ProbeWS()
        let url = "wss://\(hostName)/cable/connect/\(Data(routing).hexUpper)/\(tidHex)"
        _ = try await peerWS.connect(url: URL(string: url)!, origin: nil)
        print("  peer open")

        // Noise handshake: peer initiator → host responder → peer processes
        let initiator = CableHandshake.Initiator(psk: psk, peerIdentity: responderPub)
        try await peerWS.send(initiator.buildInitialMessage())

        let initialMsg = try await hostWS.receive()
        guard let (hostResult, response) = CableHandshake.respond(psk: psk, identity: responderStatic, message: initialMsg) else {
            print("  FAIL host responder"); hostWS.close(); peerWS.close(); return
        }
        try await hostWS.send(response)

        let respMsg = try await peerWS.receive()
        guard let peerResult = initiator.processResponse(respMsg) else {
            print("  FAIL peer processResponse"); hostWS.close(); peerWS.close(); return
        }
        print("  handshake complete; crypters counterparty: \(peerResult.crypter.isCounterparty(of: hostResult.crypter))")

        // peer → host
        let p2h = peerResult.crypter.encrypt([UInt8]("ping-from-peer".utf8))!
        try await peerWS.send(p2h)
        let gotAtHost = hostResult.crypter.decrypt(try await hostWS.receive())
        print("  host received: \(gotAtHost.map { String(decoding: $0, as: UTF8.self) } ?? "<nil>")")

        // host → peer
        let h2p = hostResult.crypter.encrypt([UInt8]("ping-from-host".utf8))!
        try await hostWS.send(h2p)
        let gotAtPeer = peerResult.crypter.decrypt(try await peerWS.receive())
        print("  peer received: \(gotAtPeer.map { String(decoding: $0, as: UTF8.self) } ?? "<nil>")")

        let ok = gotAtHost.map { String(decoding: $0, as: UTF8.self) } == "ping-from-peer"
              && gotAtPeer.map { String(decoding: $0, as: UTF8.self) } == "ping-from-host"
        print(ok ? "  PASS — full-duplex encrypted bridging works" : "  FAIL — payload mismatch")

        hostWS.close(); peerWS.close()
    } catch {
        print("  FAIL live2: \(error)")
        hostWS.close()
    }
}
