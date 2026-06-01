//
//  QRReceiver.swift
//  bluesteal
//
//  Receive side of the scan-and-share feature: decodes an inbound `RelayMessage.qr`
//  from the tunnel and surfaces the `FIDO:/` URI for display in a modal. macOS
//  does not scan; it only receives and renders.
//

import Foundation
import Observation

/// Identifiable wrapper around a received `FIDO:/` URI, for `.sheet(item:)`.
struct QRItem: Identifiable, Equatable {
    let id = UUID()
    let uri: String
}

@MainActor
@Observable
final class QRReceiver {
    /// A QR received from the peer to display (drives the receive modal).
    var received: QRItem?

    private let tracer: RelayTracer
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    init(tracer: RelayTracer) { self.tracer = tracer }

    /// Try to consume an inbound tunnel frame. Returns true if it was a QR
    /// message (surfaced for display); false otherwise so the caller can route
    /// it down the normal advert path.
    func tryHandle(_ data: Data) -> Bool {
        guard let msg = try? decoder.decode(RelayMessage.self, from: data) else { return false }
        if case .qr(let q) = msg {
            tracer.log("qr", "qr.recv", ["len": q.uri.count])
            received = QRItem(uri: q.uri)
            return true
        }
        return false
    }
}
