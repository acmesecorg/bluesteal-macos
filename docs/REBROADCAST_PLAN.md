# Re-broadcast Peer Adverts — macOS Implementation Plan

> **Empirical update (2026-05-19):** A diagnostic capture of a native iOS
> authenticator confirmed it emits `ServiceData.FFF9` with a 20-byte payload
> (16-byte encrypted EID + 4-byte HMAC tag) — *not* the EID-as-128-bit-UUID
> encoding. See `IOS_AUTHENTICATOR_CAPTURE.md`. Implications:
>
> - The universally-working topology is **iOS authenticator → any Host →
>   Windows Receiver → any Chromium** (Windows re-emits the original service-
>   data with HMAC tag intact).
> - **macOS/iOS Receivers cannot re-broadcast faithfully** — they can only
>   emit `kCBAdvertisementDataServiceUUIDsKey`, which drops the HMAC tag and
>   is only consumed by Chromium-macOS's `IS_MAC` UUID trial-decrypt path.
> - `MACOS_UPDATES.md §5` (EID-as-UUID detection) is *not* required to detect
>   iOS-native authenticators. It would still be needed to detect Chromium-on-
>   macOS *acting as* an authenticator.

This document describes the changes needed in luesteal-macos to re-broadcast peer-received BLE advertisements on the local Bluetooth peripheral, mirroring the Windows implementation in luesteal-windows.

---

## Overview

When the relay is open and adverts arrive from the paired peer over the WebRTC data channel, the macOS app should re-emit them on the local BLE peripheral so a nearby CTAP hybrid client can observe them.

---

## Design Summary

| Aspect | Behaviour |
|--------|-----------|
| Source | Peer-received adverts only (via AdvertRelay's received pipeline) |
| Selection | Latest-wins — single CBPeripheralManager advertisement at a time |
| TTL | 8 seconds since lastSeen; 2-second sweep timer expires stale entries |
| Debounce | 250 ms minimum between publisher swaps |
| Loop guard | Self-published payload-hex Set; AdvertStore.ingest drops matches |
| Lifecycle | Starts automatically when relay opens; stops on relay close |

---

## CoreBluetooth Limitation (CRITICAL)

Apple's `CBPeripheralManager.startAdvertising(_:)` only honours:
- `CBAdvertisementDataLocalNameKey`
- `CBAdvertisementDataServiceUUIDsKey`

**Raw service-data and manufacturer-data cannot be emitted by third-party apps on macOS.**

### Workaround for service-data variants (FidoV2 / GoogleV2)

Chromium's `IS_MAC` branch in `ConstructAdvertisementData` encodes the client EID as a **128-bit service UUID**. The macOS app should do the same:
- Map the 20-byte encrypted EID into the octets of a 128-bit UUID.
- Advertise that UUID via `CBAdvertisementDataServiceUUIDsKey`.
- The client platform (Chrome) recognises this encoding and trial-decrypts.

### GoogleMfgV1 (manufacturer-data only)

**Cannot be re-broadcast on macOS.** Log a warning: `"GoogleMfgV1 advert not re-broadcastable on macOS (manufacturer-data not supported by CoreBluetooth)"` and skip.

---

## New Files

### `bluesteal/Services/BleAdvertiser.swift`

Wraps `CBPeripheralManager`:

`swift
class BleAdvertiser: NSObject, CBPeripheralManagerDelegate {
    private var peripheralManager: CBPeripheralManager?
    private(set) var isAdvertising = false
    var onStatusChanged: ((Bool, Error?) -> Void)?
    
    func startAdvertising(serviceUUID: CBUUID) { ... }
    func stopAdvertising() { ... }
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) { ... }
}
`

### `bluesteal/Services/RebroadcastService.swift`

Mirrors Windows `RebroadcastService.cs`:

`swift
@Observable
class RebroadcastService {
    private let advertRelay: AdvertRelay
    private let advertiser: BleAdvertiser
    private var sweepTimer: Timer?
    private var selfPublishedPayloadHex: Set<String> = []
    private var lastSwapTime: Date = .distantPast
    
    private(set) var activeCount = 0
    private(set) var isActive = false
    private(set) var currentPayloadHex: String?
    private(set) var lastError: String?
    
    func isSelfPublished(_ hex: String) -> Bool { ... }
    private func evaluateLatestWins() { ... }
    private func buildServiceUUID(from advert: CableAdvert) -> CBUUID? { ... }
}
`

---

## Modified Files

### `bluesteal/Services/AdvertStore.swift`

In `ingest(_:)`, before upserting, check:

`swift
if RebroadcastService.shared.isSelfPublished(payloadHex) {
    selfEchoesDropped += 1
    return
}
`

### SwiftUI Views

- **Per-row indicator:** Add a green circle (`Circle().fill(.green).frame(width: 8, height: 8)`) to each peer advert row, visible when `vm.isRebroadcasting == true`. Tooltip: "On air now".
- **Relay status chip:** In the relay bar, show `"Rebroadcasting \(N)"` with a green dot when active; `"Re-broadcast failed: \(error)"` with a red dot on error.

### `bluesteal/ViewModels/CableAdvertViewModel.swift` (or equivalent)

Add:
`swift
@Published var isRebroadcasting = false
`

---

## Entitlements & Info.plist

Confirm the following is present:

`xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Bluesteal uses Bluetooth to re-broadcast FIDO caBLE advertisements for the CTAP hybrid transport relay.</string>
`

Required by `CBPeripheralManager` — without it the app will crash on first use.

---

## Cross-References

- **Windows Section 6e** in `MACOS_UPDATES.md`: loop guard / origin gate (now fulfilled).
- **Windows Section 8** in `MACOS_UPDATES.md`: full re-broadcast design summary.

### Windows source files for reference

| File | Role |
|------|------|
| `Bluesteal/Services/BleAdvertiser.cs` | BluetoothLEAdvertisementPublisher wrapper |
| `Bluesteal/Services/RebroadcastService.cs` | Latest-wins coordinator, TTL sweep, self-payload guard |
| `Bluesteal/Services/AdvertStore.cs` | selfPayloadFilter loop guard |
| `Bluesteal/ViewModels/CableAdvertViewModel.cs` | IsRebroadcasting UI binding |
| `Bluesteal/Views/RelayView.xaml(.cs)` | Rebroadcasting chip UI |

---

## Testing

1. Pair host (macOS) + peer (Windows) via relay.
2. Scan a caBLE advert on the peer side (Windows scanner picks up a FidoV2 advert).
3. Confirm macOS peer row shows green "On air" dot and relay bar shows "Rebroadcasting 1".
4. Use a third BLE scanner (e.g. nRF Connect) to observe the re-broadcast 128-bit service UUID.
5. Confirm macOS's own scanner does NOT re-ingest the published UUID (loop guard works).
6. Send a GoogleMfgV1 advert from Windows → confirm macOS logs a skip warning and does not attempt to advertise.
