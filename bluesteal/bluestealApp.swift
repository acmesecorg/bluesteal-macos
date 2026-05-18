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

    init() {
        let scanner = CableScanner()
        let store = AdvertStore(logger: JSONLLogger())
        let relay = RelayClient()
        let advertRelay = AdvertRelay(store: store, relay: relay)
        _scanner = State(initialValue: scanner)
        _store = State(initialValue: store)
        _relay = State(initialValue: relay)
        _advertRelay = State(initialValue: advertRelay)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(scanner)
                .environment(store)
                .environment(relay)
                .environment(advertRelay)
        }
    }
}
