// Phase 0/1 probe + KAT harness for the macOS caBLE tunnel side-channel port.
//
//   swift run TunnelProbe          → run crypto KATs (default, no network)
//   swift run TunnelProbe net      → also run the live routing-id WS probe
//
// KAT vectors are the authoritative Windows C# outputs recorded in KAT.md.

import Foundation
import CryptoKit

func label(_ s: String) -> Data { Data(s.utf8) }

var pass = 0
var fail = 0
func check(_ name: String, _ got: String, _ want: String) {
    if got == want { pass += 1; print("  PASS  \(name)") }
    else { fail += 1; print("  FAIL  \(name)\n        got  \(got)\n        want \(want)") }
}

func runKAT() {
    print("=== Crypto KAT (vs Windows C#) ===")

    let ikm = Data("BSTL1".utf8)
    let psk = HKDFShim.derive(ikm: ikm, salt: Data(), info: label("bluesteal/psk"), length: 32)
    let respSeed = HKDFShim.derive(ikm: ikm, salt: Data(), info: label("bluesteal/responder-static"), length: 32)
    let legacyTid = HKDFShim.derive(ikm: ikm, salt: Data(), info: label("bluesteal/tunnel-id"), length: 16)

    check("psk(BSTL1)", psk.hexUpper,
          "E4BCC2256F15E1E990541F50E86350161364AD9F221C6CF98697C156E12C0843")
    check("responder_seed(BSTL1)", respSeed.hexUpper,
          "D47890BCF7A16A88CA7CAD6259297631C3C175FA47B06939A73FDBF793FD74C1")
    check("legacy tunnel_id(BSTL1)", legacyTid.hexUpper,
          "377B0B4170FBAD1FEFEFFE0BAF6E3402")

    // P256 derive-from-seed → public key (the high-risk port)
    let responderStatic = CableP256.deriveKeyFromSeed(respSeed)
    let respPub = CableP256.exportPublicKeyX962(responderStatic)
    check("responder_pubkey_x963", respPub.hexUpper,
          "0451EBBBE5E90DEC6D7571B911212788C09B4A1FDD7C9443F93749A1F51A168A61D08E1F7DFDB61FD96FD141C9A51E0CAEBC8A9CEBB86B98E290D13158B8E40570")

    let initEphSeed = Data(repeating: 0x11, count: 32)
    let respEphSeed = Data(repeating: 0x22, count: 32)
    let initEph = CableP256.deriveKeyFromSeed(initEphSeed)
    let respEph = CableP256.deriveKeyFromSeed(respEphSeed)
    check("init_eph_pubkey_x963", CableP256.exportPublicKeyX962(initEph).hexUpper,
          "041FB5CC2A13F0AFEA7C9639E79C3F613D522D408F6124F263ACAB97520B3BEEA7688AEDED4BECEF79446130630310FDFDA2D87333BD79A6D22A114DF4AB31E71C")
    check("resp_eph_pubkey_x963", CableP256.exportPublicKeyX962(respEph).hexUpper,
          "0444361852C0E53A499B796EE766E0C8ACB921533F91F4970DD28F060D64B49DA13829474C176DF9A878DF5C8CBD1220D015BB719471C080C5795D1B752C1FC7D8")

    // Deterministic NKpsk0 handshake transcript
    let pskBytes = [UInt8](psk)
    let respPubBytes = [UInt8](respPub)

    let initiator = CableHandshake.Initiator(psk: pskBytes, peerIdentity: respPubBytes, ephemeral: initEph)
    let initialMessage = initiator.buildInitialMessage()
    check("initial_message",
          Data(initialMessage).hexUpper,
          "041FB5CC2A13F0AFEA7C9639E79C3F613D522D408F6124F263ACAB97520B3BEEA7688AEDED4BECEF79446130630310FDFDA2D87333BD79A6D22A114DF4AB31E71CAB700F9C508B3B81099C93236F4812C8")

    guard let (respResult, response) = CableHandshake.respond(
        psk: pskBytes, identity: responderStatic, message: initialMessage, ephemeral: respEph) else {
        fail += 1; print("  FAIL  responder returned nil"); return
    }
    check("response", Data(response).hexUpper,
          "0444361852C0E53A499B796EE766E0C8ACB921533F91F4970DD28F060D64B49DA13829474C176DF9A878DF5C8CBD1220D015BB719471C080C5795D1B752C1FC7D83F65DCCA0559E2F681095227E0D0F58B")

    guard let initResult = initiator.processResponse(response) else {
        fail += 1; print("  FAIL  initiator.processResponse returned nil"); return
    }
    check("crypters counterparty", String(initResult.crypter.isCounterparty(of: respResult.crypter)), "true")

    // Post-handshake Crypter sample
    let ct = initResult.crypter.encrypt([UInt8]("hello".utf8))
    check("crypter_encrypt(hello)", Data(ct ?? []).hexUpper,
          "BFAC748198B0676C0286598995BA020A83FCB65164C01F4B76C93F3BFE9E10D37D48C12483CACEFF2EFF84A8559E169E")
    let dec = ct.flatMap { respResult.crypter.decrypt($0) }
    check("responder_decrypt", dec.map { String(decoding: $0, as: UTF8.self) } ?? "<nil>", "hello")

    print("\n  \(pass) passed, \(fail) failed")
}

// MARK: - Live routing-id probe (opt-in)

func runNetworkProbe() async {
    let host = "cable.ua5v.com"
    let code = "BSTL1"
    let nowMinute = Int64(Date().timeIntervalSince1970) / 60
    var le = nowMinute.littleEndian
    let salt = withUnsafeBytes(of: &le) { Data($0) }
    let tid = HKDFShim.derive(ikm: Data(code.utf8), salt: salt,
                              info: label("bluesteal/tunnel-minute"), length: 16)
    let url = URL(string: "wss://\(host)/cable/new/\(tid.hexUpper)")!
    print("\n=== live routing-id probe ===")
    print("connecting to \(url.absoluteString)")

    final class D: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        let cb: (HTTPURLResponse?) -> Void
        init(_ cb: @escaping (HTTPURLResponse?) -> Void) { self.cb = cb }
        func urlSession(_ s: URLSession, webSocketTask t: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
            cb(t.response as? HTTPURLResponse)
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
            if let e { print("WS error: \(e.localizedDescription)"); cb(nil) }
        }
    }

    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        var done = false
        func finish() { if !done { done = true; cont.resume() } }
        var req = URLRequest(url: url)
        req.setValue("fido.cable", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        req.setValue("wss://\(host)", forHTTPHeaderField: "Origin")
        let delegate = D { resp in
            let routing = resp?.value(forHTTPHeaderField: "X-caBLE-Routing-ID")
            print("X-caBLE-Routing-ID = \(routing ?? "<MISSING>")  [\(routing != nil ? "PASS" : "FAIL")]")
            finish()
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        session.webSocketTask(with: req).resume()
        DispatchQueue.global().asyncAfter(deadline: .now() + 18) { print("(timeout)"); finish() }
    }
}

if CommandLine.arguments.contains("live2") {
    await runLive2()
    exit(0)
}
runKAT()
if CommandLine.arguments.contains("net") {
    await runNetworkProbe()
}
exit(fail == 0 ? 0 : 1)
