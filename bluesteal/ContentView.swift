//
//  ContentView.swift
//  bluesteal
//

import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(CableScanner.self) private var scanner
    @Environment(AdvertStore.self) private var store
    @Environment(RelayClient.self) private var relay
    @Environment(AdvertRelay.self) private var advertRelay
    @Environment(DuplicatePayloadDetector.self) private var duplicateDetector

    var body: some View {
        VStack(spacing: 0) {
            if duplicateDetector.isWarningVisible {
                DuplicateWarningBanner(
                    onDismiss: { duplicateDetector.dismissWarning() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if scanner.mode == .diagnostic {
                DiagnosticModeBanner()
            }

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
        .animation(.easeInOut(duration: 0.2), value: duplicateDetector.isWarningVisible)
        .frame(minWidth: 820, minHeight: 480)
    }
}

/// Warning banner shown when host and peer have both observed an advert
/// with the same payload bytes. Wording matches the Windows `<InfoBar>`
/// verbatim — the two clients are expected to look and read the same.
private struct DuplicateWarningBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .imageScale(.large)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("Host and peer are seeing the same advert")
                    .font(.subheadline.weight(.semibold))
                Text("Bluesteal works best when host and peer are not within range of the same Bluetooth device for the CTAP hybrid flow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.18))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Instructional banner shown while in Diagnostic scan mode. Reminds the
/// user where the dump file lives and what they should be doing on the
/// iOS authenticator while the capture runs.
private struct DiagnosticModeBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "magnifyingglass.circle.fill")
                .foregroundStyle(.blue)
                .imageScale(.large)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("Diagnostic capture active")
                    .font(.subheadline.weight(.semibold))
                Text("Every nearby BLE advert is being dumped to ~/Library/Logs/bluesteal/diag-*.jsonl. Trigger a hybrid sign-in on the iOS device under test, then switch back to Promiscuous and grep the diag log for the new advert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Reveal log") {
                let dir = URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Logs/bluesteal", isDirectory: true)
                NSWorkspace.shared.open(dir)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

#Preview {
    let tracer = RelayTracer()
    let store = AdvertStore(logger: JSONLLogger())
    let relay = RelayClient(tracer: tracer)
    let advertRelay = AdvertRelay(store: store, relay: relay)
    let advertiser = BleAdvertiser(tracer: tracer)
    let rebroadcast = RebroadcastService(advertRelay: advertRelay,
                                          advertiser: advertiser,
                                          relay: relay,
                                          tracer: tracer)
    return ContentView()
        .environment(CableScanner(previewMode: true))
        .environment(store)
        .environment(relay)
        .environment(advertRelay)
        .environment(DuplicatePayloadDetector(store: store, relay: advertRelay))
        .environment(advertiser)
        .environment(rebroadcast)
}
