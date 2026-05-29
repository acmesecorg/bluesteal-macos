//
//  RebroadcastService.swift
//  bluesteal
//
//  Re-emits adverts received from a paired peer over the local BLE
//  peripheral, so a nearby CTAP hybrid client (e.g. Chrome on a laptop) can
//  observe them. Latest-wins: a single `CBPeripheralManager` advertisement at
//  a time, switching to the freshest non-stale peer advert.
//
//  Mirrors the Windows `RebroadcastService.cs` design with one notable
//  macOS-specific constraint: `CBPeripheralManager` accepts only
//  `CBAdvertisementDataServiceUUIDsKey` (and `LocalName`) from third-party
//  apps, so we encode the EID payload into a 128-bit service UUID — the same
//  format Chromium emits from its `IS_MAC` branch in `ConstructAdvertisement-
//  Data`. `GoogleMfgV1` adverts cannot be re-broadcast at all on macOS;
//  those are skipped with a warning.
//

import Foundation
import CoreBluetooth

@MainActor
@Observable
final class RebroadcastService {
    private static let staleSweepInterval: TimeInterval = 2.0
    private static let staleAfter: TimeInterval = 8.0
    private static let debounce: TimeInterval = 0.25

    /// Number of peer adverts currently within TTL — drives the
    /// "Rebroadcasting N" chip count.
    private(set) var activeCount: Int = 0

    /// `id` of the advert currently being re-broadcast (if any). The UI
    /// matches this against each row's `CableAdvert.id` to draw a green dot.
    private(set) var activeAdvertID: String?

    /// True iff the local `CBPeripheralManager` has actually entered the
    /// advertising state.
    private(set) var isActive: Bool = false

    /// Last error surfaced by `BleAdvertiser` (e.g. start failure). Cleared
    /// on the next successful start.
    private(set) var lastError: String?

    private let advertRelay: AdvertRelay
    private let advertiser: BleAdvertiser
    private let tracer: RelayTracer

    private var sweepTask: Task<Void, Never>?
    private var selfPublishedPayloadHex: Set<String> = []
    private var lastSwapTime: Date = .distantPast
    private var currentPayloadHex: String?

    /// The view sets this true while the caBLE tunnel is Open, which gates the
    /// rebroadcast pipeline (sweep + publish). False tears everything down.
    /// Mirrors Windows `RebroadcastService.ExternalOpen`.
    var externalOpen: Bool = false {
        didSet {
            guard externalOpen != oldValue else { return }
            if externalOpen { startSweep() } else { stopSweep() }
        }
    }

    init(advertRelay: AdvertRelay,
         advertiser: BleAdvertiser,
         tracer: RelayTracer) {
        self.advertRelay = advertRelay
        self.advertiser = advertiser
        self.tracer = tracer

        advertiser.onStatusChanged = { [weak self] active, error in
            guard let self else { return }
            self.isActive = active
            self.lastError = error
        }
    }

    /// Loop-guard predicate handed to `AdvertStore.selfPayloadFilter`. Returns
    /// true when the scanner observes a payload we are currently publishing
    /// ourselves, so the store can drop it before it ever enters the local
    /// list (and before it gets forwarded back to the peer).
    func isSelfPublished(payloadHex: String) -> Bool {
        selfPublishedPayloadHex.contains(payloadHex.lowercased())
    }

    // MARK: - State plumbing

    private func startSweep() {
        sweepTask?.cancel()
        sweepTask = Task { @MainActor [weak self] in
            // Evaluate immediately so the first peer advert isn't delayed by
            // a full sweep interval, then settle into the periodic cadence.
            self?.evaluateLatestWins()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.staleSweepInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { break }
                self.evaluateLatestWins()
            }
        }
        tracer.log("rebroadcast", "rebroadcast.sweep.start", [:])
    }

    private func stopSweep() {
        sweepTask?.cancel()
        sweepTask = nil
        stopPublisher(reason: "relay closed")
        activeCount = 0
        tracer.log("rebroadcast", "rebroadcast.sweep.stop", [:])
    }

    private func evaluateLatestWins() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.staleAfter)

        var best: CableAdvert?
        var alive = 0
        for advert in advertRelay.received {
            guard advert.lastSeen >= cutoff else { continue }
            alive += 1
            if best == nil || advert.lastSeen > best!.lastSeen {
                best = advert
            }
        }
        activeCount = alive

        guard let best else {
            if currentPayloadHex != nil {
                stopPublisher(reason: "no fresh peer adverts")
            }
            return
        }

        // Already broadcasting this exact payload — nothing to do.
        if best.payloadHex == currentPayloadHex {
            return
        }

        // Debounce rapid swaps — prevents thrashing the publisher when two
        // peers' adverts ping-pong as "newest".
        if now.timeIntervalSince(lastSwapTime) < Self.debounce {
            return
        }

        guard let uuid = Self.buildServiceUUID(for: best) else {
            if best.variant == .googleMfgV1 {
                tracer.log("rebroadcast", "rebroadcast.skip",
                           ["reason": "not re-broadcastable on macOS (manufacturer-data)",
                            "variant": best.variant.wireName,
                            "id": best.id])
            } else {
                tracer.log("rebroadcast", "rebroadcast.skip",
                           ["reason": "unsupported variant",
                            "variant": best.variant.wireName,
                            "id": best.id])
            }
            return
        }

        // Roll the self-published set: drop the previous payload, register
        // the new one. The loop-guard in `AdvertStore` reads from this set,
        // so any membership transition needs to happen before the publisher
        // actually goes on-air.
        if let prev = currentPayloadHex {
            selfPublishedPayloadHex.remove(prev)
        }
        let hex = best.payloadHex.lowercased()
        selfPublishedPayloadHex.insert(hex)
        currentPayloadHex = hex
        activeAdvertID = best.id
        lastSwapTime = now

        advertiser.start(uuid: uuid)
        tracer.log("rebroadcast", "rebroadcast.publish",
                   ["uuid": uuid.uuidString,
                    "variant": best.variant.wireName,
                    "id": best.id,
                    "alive": alive])
    }

    private func stopPublisher(reason: String) {
        if let prev = currentPayloadHex {
            selfPublishedPayloadHex.remove(prev)
        }
        currentPayloadHex = nil
        activeAdvertID = nil
        advertiser.stop()
        tracer.log("rebroadcast", "rebroadcast.unpublish", ["reason": reason])
    }

    // MARK: - macOS service-UUID encoding

    /// Builds the 128-bit service UUID that carries a peer EID payload.
    /// Format: `0000FFF9-AAAA-BBBB-CCCC-DDDDDDDDDDDD` where the trailing 12
    /// bytes are the first 12 bytes of the EID. Returns nil for variants
    /// that cannot be re-broadcast from a macOS third-party peripheral.
    private static func buildServiceUUID(for advert: CableAdvert) -> CBUUID? {
        switch advert.variant {
        case .fidoV2, .googleV2:
            // 20-byte payload: AES-ECB(EID) ‖ HMAC[:4]. We pack the first 12
            // ciphertext bytes; the remaining 4 EID bytes + 4 HMAC bytes are
            // dropped (a known macOS-side fidelity loss vs Windows raw
            // service-data emission).
            return packAsServiceUUID(payload: advert.payload)
        case .googleV1:
            // Google v1 wire payload is [flags, version, EID(16)]. Strip the
            // 2-byte header so the UUID carries EID bytes, not metadata.
            guard advert.payload.count >= 2 else { return nil }
            let eid = advert.payload.subdata(in: 2..<advert.payload.count)
            return packAsServiceUUID(payload: eid)
        case .googleMfgV1, .unknown:
            return nil
        }
    }

    private static func packAsServiceUUID(payload: Data) -> CBUUID? {
        let needed = 12
        guard payload.count >= needed else { return nil }
        let tail = payload.prefix(needed)
        let hex = tail.map { String(format: "%02X", $0) }.joined()
        // 24 hex chars => "AAAA-BBBB-CCCC-DDDDDDDDDDDD" (4-4-4-12).
        let s1 = hex.prefix(4)
        let s2 = hex.dropFirst(4).prefix(4)
        let s3 = hex.dropFirst(8).prefix(4)
        let s4 = hex.dropFirst(12)
        return CBUUID(string: "0000FFF9-\(s1)-\(s2)-\(s3)-\(s4)")
    }
}
