# Capturing an iOS authenticator's hybrid-transport advert

This guide settles a single empirical question:

> When a native iOS device acts as the **authenticator** in a CTAP hybrid /
> caBLE sign-in flow, what wire format does its BLE advertisement use —
> service-data (`0xFFF9`/`0xFDE2`) with an HMAC tag, or a 128-bit Service
> UUID encoding the EID (the Chromium `IS_MAC` convention)?

The answer determines which of the four-device re-broadcast topologies
(see `REBROADCAST_PLAN.md`) is actually viable end-to-end. Until we know,
every architectural choice past this point is a guess.

---

## What you need

- A Mac running bluesteal-macOS (this build).
- A nearby iPhone or iPad (the authenticator under test).
- A third device that can trigger a hybrid sign-in — e.g. a Windows laptop,
  another Mac, or a Chromebook with Chrome. The iPhone you're testing must
  not be the one initiating the sign-in.
- A site / app on the third device that supports passkey login via "another
  device". Easy options: passkeys.io, the Google account demo, GitHub.

---

## Capture procedure

1. **Launch bluesteal-macOS.** Switch the scan mode to **Diagnostic** in
   the top-bar segmented control. A blue banner appears.
2. **Hold the iPhone within ~30 cm of the Mac.** Bluetooth coverage is
   short-range; the closer the better for SNR.
3. **On the third device**, start a passkey sign-in flow. When asked to
   pick a credential source, choose "Use a passkey on another device" /
   "Sign in with a passkey from another device" (the wording varies by
   browser).
4. A QR code appears on the third device. Scan it with the iPhone's
   camera. The iPhone then displays a system prompt — "Sign in to *site*
   with your saved passkey?".
5. **The advert is live for the ~30 seconds the prompt is on screen.**
   Wait ~10 s, then dismiss the prompt. Repeat once or twice to be sure
   it was captured.
6. Switch bluesteal-macOS back to **Promiscuous** (or close it).

---

## Where the dump lives

```
~/Library/Containers/<bundle-id>/Data/Library/Logs/bluesteal/diag-<yyyy-MM-dd>-<pid>.jsonl
```

The "Reveal log" button in the diagnostic banner opens this folder. One
JSON object per line. Each entry has:

```jsonc
{
  "ts": "2026-05-19T12:34:56.789Z",
  "peer": "1FA9B3E2-...",        // CoreBluetooth-assigned per-mac UUID
  "rssi": -47,
  "advert": {                    // full CoreBluetooth dict, JSON-safe
    "kCBAdvDataServiceUUIDs": ["...", "..."],
    "kCBAdvDataServiceData": { "FFF9": "deadbeef..." },
    "kCBAdvDataManufacturerData": "e000...",
    "kCBAdvDataLocalName": "...",
    "kCBAdvDataTxPowerLevel": -8,
    "kCBAdvDataIsConnectable": 1
  },
  // Hint fields surfaced for quick grep:
  "candidateEidUUIDs": ["AB12...EF34"],   // any 128-bit UUID in ServiceUUIDsKey
  "overflowUUIDs":     ["AB12...EF34"]    // iOS backgrounded-app UUIDs
}
```

---

## Decoding the result

Run a coarse grep first to narrow on adverts that appeared while the
iOS prompt was up:

```bash
# All adverts seen by peripheral, ordered by time.
jq -r '"\(.ts)  \(.peer)  rssi=\(.rssi)  \(.advert|keys|join(","))"' \
   diag-*.jsonl
```

You're looking for an advert that:

- Appeared at the moment you tapped through the QR / prompt.
- Disappeared when you dismissed the prompt.
- Has RSSI consistent with the iPhone being next to the Mac (~−40 to −60 dBm).

Once you identify the suspect peripheral, dump its full adverts:

```bash
jq 'select(.peer=="<iphone-peripheral-uuid>")' diag-*.jsonl
```

Then match against one of these branches:

### Branch A — EID-as-128-bit-UUID (Chromium `IS_MAC` convention)

Signature: `kCBAdvDataServiceUUIDs` contains exactly one 128-bit UUID
(36-character form like `00000000-0000-A11C-...-...`), and *no*
`kCBAdvDataServiceData` entries under `FFF9` or `FDE2`, and no
`kCBAdvDataManufacturerData` block.

Action: a CTAP hybrid client expects 16-byte encrypted EIDs and trial-
decrypts them with the QR-session key. The 16 bytes are the trailing
octets of the UUID (drop the dashes, take all 16 bytes).

### Branch B — `0xFFF9` / `0xFDE2` service-data with HMAC tag

Signature: `kCBAdvDataServiceData` contains an entry keyed `"FFF9"` or
`"FDE2"` with 18 or 20 hex bytes of value. The trailing 4 bytes (when
length is 20) are the HMAC tag.

Action: bluesteal-macOS's existing classifier already handles this
shape. If the advert showed up in the main list during your test, you
were on Branch B and didn't need the diagnostic at all. (Worth running
the diagnostic anyway to be sure no parallel UUID-encoded advert is
also being emitted.)

### Branch C — Manufacturer-data under company `0x00E0`

Signature: `kCBAdvDataManufacturerData` is a 22-byte hex string starting
with `e000` (little-endian company ID 0x00E0), followed by header
`[length=14, type=15, flags=20, version=01]` and a 16-byte EID.

Unlikely for native iOS, expected for Windows Chrome. Reported here
for completeness.

---

## Captured result (2026-05-19)

**Outcome: Branch B (service-data with HMAC tag).**

iPhone peer `FEFA3591-…` emitted `ServiceData.FFF9 = d0ce20819be3dc20219874d0841731304a192d1b`
during the passkey prompt — exactly 20 bytes, `fidoV2` shape (16-byte encrypted EID + 4-byte
HMAC tag). RSSI -39 to -57 dBm, time-correlated with the hybrid flow. No 128-bit service
UUIDs from the iPhone, no `0x00E0` manufacturer-data anywhere in the log.

Apple's native passkey daemon uses Chromium's Windows/Linux publisher wire format, not the
`IS_MAC` UUID-encoding trick that Chromium-on-macOS uses when it acts as authenticator.

Source log: `diag-2026-05-19-65201.jsonl`.

---

## What we'll do with the answer

| Outcome | Implication |
|---|---|
| Branch A (UUID) | Implement `MACOS_UPDATES.md §5` (EID-as-UUID detection in `CableScanner.swift`). Re-broadcast can target Chromium-macOS only — see `REBROADCAST_PLAN.md` matrix. |
| Branch B (service-data) | No detector changes needed. Re-broadcast on Windows preserves the HMAC tag → all Chromiums work. macOS/iOS re-broadcast is still UUID-only and macOS-Chrome-only. |
| Branch C (mfg-data) | Existing `classifyManufacturerData` works. Re-broadcast feasibility same as Branch B. |
| Mixed (multiple variants) | Implement all detectors and prefer the carrier the host can re-emit faithfully. |

After capturing, update `REBROADCAST_PLAN.md` with the outcome and check
off the relevant matrix row.
