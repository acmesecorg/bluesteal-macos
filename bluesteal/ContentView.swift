//
//  ContentView.swift
//  bluesteal
//

import SwiftUI

struct ContentView: View {
    @Environment(CableScanner.self) private var scanner
    @Environment(AdvertStore.self) private var store
    @Environment(RelayClient.self) private var relay
    @Environment(AdvertRelay.self) private var advertRelay

    var body: some View {
        VStack(spacing: 0) {
            ScannerStatusView(
                state: scanner.state,
                isScanning: scanner.isScanning,
                totalDetections: store.totalDetections,
                uniqueCount: store.adverts.count,
                mode: Binding(get: { scanner.mode }, set: { scanner.mode = $0 }),
                onClear: { store.clear() }
            )

            Divider()

            RelayView()

            Divider()

            if store.adverts.isEmpty && advertRelay.received.isEmpty {
                ContentUnavailableView {
                    Label("Waiting for caBLE adverts", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("Listening for service data under UUIDs 0xFFF9 (FIDO) and 0xFDE2 (Google).\nStart a hybrid sign-in flow on a nearby phone or laptop.")
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !store.adverts.isEmpty {
                        Section("Local") {
                            ForEach(store.adverts) { AdvertRowView(advert: $0) }
                        }
                    }
                    if !advertRelay.received.isEmpty {
                        Section("From peer") {
                            ForEach(advertRelay.received) { AdvertRowView(advert: $0, source: .relay) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear {
            scanner.onEvent = { event in
                store.ingest(event)
            }
        }
        .frame(minWidth: 820, minHeight: 480)
    }
}

#Preview {
    let store = AdvertStore(logger: JSONLLogger())
    let relay = RelayClient()
    return ContentView()
        .environment(CableScanner(previewMode: true))
        .environment(store)
        .environment(relay)
        .environment(AdvertRelay(store: store, relay: relay))
}
