//
//  DuplicatePayloadDetector.swift
//  bluesteal
//
//  Watches the local `AdvertStore` and the paired `AdvertRelay` for an
//  advert payload (hex only) that has been both locally observed and
//  received from the peer. Surfaces a one-shot warning so the UI can tell
//  the user that host and peer are within range of the same Bluetooth
//  device for the CTAP hybrid flow — defeating the point of relaying.
//
//  Mirrors `Bluesteal/Services/DuplicatePayloadDetector.cs` on the Windows
//  port. Comparison is on `payloadHex` only (lowercased): peripheral UUID,
//  Bluetooth address and variant legitimately differ between host and peer
//  for the same advert.
//

import Foundation
import Observation

@MainActor
@Observable
final class DuplicatePayloadDetector {

    /// True while the warning banner should be visible. Flipped on the
    /// first cross-side payload match, flipped back after the
    /// auto-dismiss timer fires or the user dismisses manually.
    private(set) var isWarningVisible: Bool = false

    /// Latched true once the first match is detected so subsequent matches
    /// stay quiet for the rest of the session. Mirrors `_warned` in the
    /// Windows reference.
    private var hasWarned: Bool = false

    private var localPayloads: Set<String> = []
    private var peerPayloads: Set<String> = []

    private weak var relay: AdvertRelay?
    private var dismissTask: Task<Void, Never>?

    /// Match the Windows `InfoBar` 10 s auto-dismiss exactly.
    private static let autoDismissAfter: TimeInterval = 10

    init(store: AdvertStore, relay: AdvertRelay) {
        self.relay = relay
        // The local-ingest path is owned by `AdvertRelay` (it forwards
        // `AdvertStore.onIngest`) so we hang off that callback rather than
        // fighting for the single-handler property on the store.
        relay.onLocalIngest = { [weak self] advert in
            self?.observe(payloadHex: advert.payloadHex, side: .local)
        }
        relay.onReceived = { [weak self] advert in
            self?.observe(payloadHex: advert.payloadHex, side: .peer)
        }
    }

    /// Manually dismiss the warning (e.g. user clicked the X). Idempotent.
    /// Does not clear `hasWarned` — the warning still won't reappear in
    /// this session.
    func dismissWarning() {
        dismissTask?.cancel()
        dismissTask = nil
        isWarningVisible = false
    }

    // MARK: - Private

    private enum Side { case local, peer }

    private func observe(payloadHex: String, side: Side) {
        guard !hasWarned else { return }
        let hex = payloadHex.lowercased()
        guard !hex.isEmpty else { return }
        let matched: Bool
        switch side {
        case .local:
            localPayloads.insert(hex)
            matched = peerPayloads.contains(hex)
        case .peer:
            peerPayloads.insert(hex)
            matched = localPayloads.contains(hex)
        }
        if matched { fire() }
    }

    private func fire() {
        hasWarned = true
        isWarningVisible = true
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            let delay = UInt64(Self.autoDismissAfter * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.isWarningVisible = false
            self.dismissTask = nil
        }
    }
}
