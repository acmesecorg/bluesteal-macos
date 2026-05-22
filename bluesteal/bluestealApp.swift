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
    @State private var relay: RelayClient
    @State private var advertRelay: AdvertRelay
    @State private var duplicateDetector: DuplicatePayloadDetector
    @State private var bleAdvertiser: BleAdvertiser
    @State private var rebroadcast: RebroadcastService

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
        let relay = RelayClient(tracer: tracer)
        let advertRelay = AdvertRelay(store: store, relay: relay)
        let detector = DuplicatePayloadDetector(store: store, relay: advertRelay)
        let advertiser = BleAdvertiser(tracer: tracer)
        let rebroadcast = RebroadcastService(advertRelay: advertRelay,
                                              advertiser: advertiser,
                                              relay: relay,
                                              tracer: tracer)
        // Loop-guard: AdvertStore must drop scanner events that match a
        // payload we're currently re-broadcasting ourselves, otherwise the
        // local scanner would re-ingest its own emission and forward it
        // back to the peer.
        store.selfPayloadFilter = { [weak rebroadcast] hex in
            rebroadcast?.isSelfPublished(payloadHex: hex) ?? false
        }
        _scanner = State(initialValue: scanner)
        _store = State(initialValue: store)
        _relay = State(initialValue: relay)
        _advertRelay = State(initialValue: advertRelay)
        _duplicateDetector = State(initialValue: detector)
        _bleAdvertiser = State(initialValue: advertiser)
        _rebroadcast = State(initialValue: rebroadcast)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(scanner)
                .environment(store)
                .environment(relay)
                .environment(advertRelay)
                .environment(duplicateDetector)
                .environment(bleAdvertiser)
                .environment(rebroadcast)
        }
    }
}
