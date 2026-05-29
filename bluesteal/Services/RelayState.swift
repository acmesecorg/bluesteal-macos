//
//  RelayState.swift
//  bluesteal
//
//  Session role/state shared by the relay transport. Extracted from the former
//  `RelayClient` (the WebRTC/MQTT path) when that transport was removed — the
//  caBLE tunnel is now the only transport, but it keeps the same lifecycle
//  vocabulary. Mirrors Windows `Services/RelayState.cs`.
//

import Foundation

/// Which side of a relay/tunnel session this instance is.
enum RelayRole { case host, peer }

/// Lifecycle state of a relay/tunnel session, shared by all transports.
enum RelayState: Equatable {
    case idle
    case hosting(code: String)
    case joining(code: String)
    case negotiating
    case open(role: RelayRole)
    case closed(reason: String)

    var isClosed: Bool { if case .closed = self { return true } else { return false } }
}
