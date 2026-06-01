# bluesteal-macos

The **macOS** client for bluesteal — observe and re-broadcast FIDO caBLE
(CTAP 2.2 hybrid-tunnel) BLE advertisements across devices.

- **Stack:** Swift / SwiftUI
- **Role:** dual-role (host **and** peer) + re-broadcast
- **Re-broadcast:** `CBPeripheralManager` only accepts service-UUIDs from
  third-party apps, so the EID is packed into a 128-bit service UUID (the
  Chromium `IS_MAC` convention) — a lossy path that Chrome on macOS can consume.

## Build & run

```bash
git clone https://github.com/acmesecorg/bluesteal-macos.git
open bluesteal.xcodeproj      # scheme: bluesteal, destination: My Mac
```

Uses Xcode 16 file-system-synchronized groups, so any `.swift` under
`bluesteal/` is compiled automatically. No secrets or credentials needed.
(The active project is `bluesteal.xcodeproj`; ignore the legacy
`bluemonday.xcodeproj`.)

## Driving host/join for testing

The app accepts command-line arguments:

- **Host:** `open -n Bluesteal.app --args -host`
- **Join:** `open -n Bluesteal.app --args -join <TOKEN>`

Per-PID JSONL traces — the hosted token appears as a `token.ready` event — land
in the sandbox container:
`~/Library/Containers/org.crainiate.bluesteal/Data/Library/Application Support/bluesteal/Logs/`

## More

Protocol, architecture, OOB-token format, and the shared specs live in the
umbrella repo: **https://github.com/acmesecorg/bluesteal**
