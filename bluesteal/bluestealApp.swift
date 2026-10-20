//
//  bluestealApp.swift
//  bluesteal
//
//  Created by James Westgate on 18/05/2026.
//

import SwiftUI

@main
struct bluestealApp: App {
    @State private var scanner: CableScanner
    @State private var store: AdvertStore
    @State private var advertRelay: AdvertRelay
    @State private var duplicateDetector: DuplicatePayloadDetector
    @State private var bleAdvertiser: BleAdvertiser
    @State private var rebroadcast: RebroadcastService
    @State private var tunnel: TunnelTransport
    @State private var qrReceiver: QRReceiver

    init() {
        let tracer = RelayTracer()
        tracer.log("app", "app.start", [
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "bundleVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "logFile": tracer.logFileURL.path
        ])

        let scanner = CableScanner()
        scanner.diagnosticLogger = DiagnosticLogger()
        let store = AdvertStore(logger: JSONLLogger())
        let advertRelay = AdvertRelay(store: store, tracer: tracer)
        let detector = DuplicatePayloadDetector(store: store, relay: advertRelay)
        let advertiser = BleAdvertiser(tracer: tracer)
        let rebroadcast = RebroadcastService(advertRelay: advertRelay,
                                              advertiser: advertiser,
                                              tracer: tracer)
        // Loop-guard: AdvertStore must drop scanner events that match a
        // payload we're currently re-broadcasting ourselves, otherwise the
        // local scanner would re-ingest its own emission and forward it
        // back to the peer.
        store.selfPayloadFilter = { [weak rebroadcast] hex in
            rebroadcast?.isSelfPublished(payloadHex: hex) ?? false
        }
        // caBLE tunnel transport — the only transport. Inbound decrypted frames
        // are routed to the QR display modal if they're shared QR codes,
        // otherwise into the advert path.
        let tunnel = TunnelTransport(tracer: tracer)
        let qrReceiver = QRReceiver(tracer: tracer)
        tunnel.onFrame = { [weak advertRelay, weak qrReceiver] bytes in
            let data = Data(bytes)
            if qrReceiver?.tryHandle(data) == true { return }
            advertRelay?.handleTunnelFrame(data)
        }
        _scanner = State(initialValue: scanner)
        _store = State(initialValue: store)
        _advertRelay = State(initialValue: advertRelay)
        _duplicateDetector = State(initialValue: detector)
        _bleAdvertiser = State(initialValue: advertiser)
        _rebroadcast = State(initialValue: rebroadcast)
        _tunnel = State(initialValue: tunnel)
        _qrReceiver = State(initialValue: qrReceiver)

        Self.handleStartupArgs(tunnel: tunnel, advertRelay: advertRelay, tracer: tracer)
    }

    /// Auto-drives Host/Join from command-line args so the app can be launched
    /// pre-configured (e.g. a second instance for testing): `-host` auto-hosts
    /// and surfaces the token in the UI (and logs `token.ready`); `-join
    /// <token>` auto-joins; `-rvjoin` auto-joins the configured rendezvous room
    /// (the unattended "two rooms" peer). Mirrors Windows `App.HandleStartupArgs`.
    ///
    /// Rendezvous config is supplied here too and persisted to UserDefaults so
    /// no base URL / room / bearer is ever compiled in or committed to this
    /// public repo (SECRET HYGIENE — see RendezvousClient):
    ///   -rv <baseURL>  -room <room>  [-k <bearer>]
    /// Once set, it persists across plain relaunches. Only presence is logged,
    /// never the base URL or bearer value.
    private static func handleStartupArgs(tunnel: TunnelTransport,
                                          advertRelay: AdvertRelay,
                                          tracer: RelayTracer) {
        let args = CommandLine.arguments

        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            let v = args[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }

        // Persist any rendezvous config passed at launch so RendezvousConfig
        // .fromDefaults() can pick it up (host publish + peer fetch).
        let d = UserDefaults.standard
        if let rv = value(after: "-rv") { d.set(rv, forKey: "rv.baseURL") }
        if let room = value(after: "-room") { d.set(room, forKey: "rv.room") }
        if let k = value(after: "-k") { d.set(k, forKey: "rv.key") }
        if args.contains("-rv") || args.contains("-room") || args.contains("-k") {
            tracer.log("app", "app.config", [
                "hasRv": args.contains("-rv"),
                "hasRoom": args.contains("-room"),
                "hasKey": args.contains("-k")
            ])
        }

        // Outbound adverts flow through the tunnel once it's connected.
        func wireSend() {
            advertRelay.tunnelSend = { data in
                Task { await tunnel.send([UInt8](data)) }
            }
        }

        if args.contains("-host") {
            tracer.log("app", "app.autohost", nil)
            wireSend()
            let code = PairingCode.make()
            Task { try? await tunnel.host(code: code) }
        } else if args.contains("-rvjoin"), let room = RendezvousConfig.fromDefaults()?.room {
            tracer.log("app", "app.autorvjoin", ["room": room])
            wireSend()
            tunnel.joinViaRendezvous(room: room)
        } else if let i = args.firstIndex(of: "-join"), i + 1 < args.count {
            let token = args[i + 1].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            tracer.log("app", "app.autojoin", ["token": token])
            wireSend()
            Task { try? await tunnel.join(token: token) }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(scanner)
                .environment(store)
                .environment(advertRelay)
                .environment(duplicateDetector)
                .environment(bleAdvertiser)
                .environment(rebroadcast)
                .environment(tunnel)
                .environment(qrReceiver)
        }
    }
}
