//
//  RendezvousClient.swift
//  bluesteal
//
//  Out-of-band pairing-token drop for the "two people in different rooms"
//  demo. macOS is dual-role, so this client does BOTH directions: the
//  persistent host PUTs its current CODE-ROUTING token under a shared room
//  (iOS behaviour); a peer GETs it (Android behaviour). See
//  bluesteal/tools/rendezvous (the Cloudflare Worker) and specs/PAIRING_TOKEN.md.
//
//  SECRET HYGIENE: the base URL, room, and optional bearer are supplied at
//  runtime (command-line args written into UserDefaults — see
//  bluestealApp.handleStartupArgs) and NEVER compiled into the app or committed
//  to this public repo. This client never logs the token or the bearer — only
//  the room and HTTP status.
//

import Foundation

struct RendezvousConfig {
    let baseURL: URL
    let room: String
    let bearer: String?

    /// Reads config persisted by the `-rv`/`-room`/`-k` startup args. Returns
    /// nil (rendezvous disabled) when no base URL / room has been configured.
    static func fromDefaults(_ defaults: UserDefaults = .standard) -> RendezvousConfig? {
        guard let urlString = defaults.string(forKey: "rv.baseURL"),
              let url = URL(string: urlString),
              let room = defaults.string(forKey: "rv.room"),
              !room.isEmpty else { return nil }
        let key = defaults.string(forKey: "rv.key")
        return RendezvousConfig(baseURL: url, room: room,
                                bearer: (key?.isEmpty == false) ? key : nil)
    }
}

final class RendezvousClient: @unchecked Sendable {
    private let config: RendezvousConfig
    private let tracer: RelayTracer

    init(config: RendezvousConfig, tracer: RelayTracer) {
        self.config = config
        self.tracer = tracer
    }

    private var endpoint: URL {
        config.baseURL.appendingPathComponent("r").appendingPathComponent(config.room)
    }

    private func authorized(_ req: inout URLRequest) {
        if let bearer = config.bearer {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Best-effort publish of the current pairing token (host role). Failures
    /// are logged and swallowed — the host keeps serving regardless.
    func publish(token: String) async {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "PUT"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorized(&req)
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            // Deliberately logs room + status only — never the token or bearer.
            tracer.log("rendezvous", "publish", ["room": config.room, "status": status])
        } catch {
            tracer.log("rendezvous", "publish.failed",
                       ["room": config.room, "error": "\(error)"])
        }
    }

    /// Current token the host published under the room (peer role), or nil if
    /// none / parse / HTTP error. Never logs the token — only room + status.
    func fetch() async -> String? {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        authorized(&req)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            tracer.log("rendezvous", "fetch", ["room": config.room, "status": status])
            guard (200..<300).contains(status),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = obj["token"] as? String, !token.isEmpty else { return nil }
            return token
        } catch {
            tracer.log("rendezvous", "fetch.failed",
                       ["room": config.room, "error": "\(error)"])
            return nil
        }
    }
}
