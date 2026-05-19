# Bluesteal pairing — porting guide

How to add a new platform (Linux, iOS, Android, Web, …) to the bluesteal pairing
protocol while staying interoperable with the existing macOS (`bluesteal-macos`)
and Windows (`bluesteal-windows`) clients.

This guide is written backwards from every cross-platform bug we hit getting
macOS and Windows to talk. **Every section below corresponds to a specific
failure mode we observed in the trace files.** If you skip a section your port
will hit that same bug.

---

## 1. The protocol in 30 seconds

Two clients pair using a 5-letter code typed by the user. Pairing is a
~5-second WebRTC SDP/ICE handshake brokered over a public MQTT-over-WSS
broker; once the data channel opens, the MQTT signaling drops and adverts
flow over the direct WebRTC `RTCDataChannel`.

```
       ┌─ MQTT broker ─┐
       │   (5 seconds) │
   ┌───▼───┐       ┌───▼───┐
   │ Host  │       │ Peer  │     1. Both hash the code → same broker
   │  PC   │       │  PC   │     2. Host publishes retained offer
   └───┬───┘       └───┬───┘     3. Peer sends answer
       │ WebRTC DC     │         4. ICE candidates trickled
       └───────────────┘         5. DC opens → MQTT dropped
                                 6. Adverts flow on the DC
```

There are four layers, and **all four** must match the existing
implementations exactly:

1. **MQTT broker selection** — both sides must land on the same broker.
2. **MQTT signaling wire format** — the `offer`, `answer`, `ice`, `bye` JSON.
3. **WebRTC SDP + ICE** — standard, but with one platform-library quirk.
4. **Data-channel wire format** — the `advert`, `heartbeat`, `bye` JSON.

Reference implementations:

| File | Role |
|---|---|
| **macOS** | |
| [`bluesteal/Models/RelayMessage.swift`](../bluesteal/Models/RelayMessage.swift) | Wire types for both signaling and data channel |
| [`bluesteal/Services/SignalingClient.swift`](../bluesteal/Services/SignalingClient.swift) | MQTT-over-WSS pairing client |
| [`bluesteal/Services/RelayClient.swift`](../bluesteal/Services/RelayClient.swift) | WebRTC peer connection wrapper |
| [`bluesteal/Services/AdvertRelay.swift`](../bluesteal/Services/AdvertRelay.swift) | AdvertStore ↔ RelayClient bridge |
| [`bluesteal/Logging/RelayTracer.swift`](../bluesteal/Logging/RelayTracer.swift) | JSONL trace logger |
| **Windows** | |
| `Bluesteal/Models/RelayMessage.cs` | Wire types |
| `Bluesteal/Models/SignalingMessage.cs` | Signaling wire types |
| `Bluesteal/Services/SignalingClient.cs` | MQTT-over-WSS client |
| `Bluesteal/Services/RelayClient.cs` | WebRTC wrapper (SIPSorcery) |
| `Bluesteal/Services/AdvertRelay.cs` | AdvertStore ↔ RelayClient bridge |
| `Bluesteal/Services/RelayTracer.cs` | JSONL trace logger |

---

## 2. MQTT broker selection — convergence is non-trivial

### Broker list (verbatim, in this order)

```
index | host                  | port | path  | TLS
   0  | broker.hivemq.com     | 8884 | /mqtt | yes (WSS)
   1  | broker.emqx.io        | 8084 | /mqtt | yes (WSS)
   2  | test.mosquitto.org    | 8081 | /mqtt | yes (WSS)
```

**Do not reorder, substitute, or add brokers** — the FNV-1a hash below depends
on the list and its order being identical on every platform.

### Starting broker — FNV-1a hash of the pairing code

Both Host and Peer compute the same starting index by hashing the pairing
code. The two sides start on the same broker.

### Pairing code format

| Field | Value |
|---|---|
| Length | **5** characters |
| Alphabet | `ABCDEFGHJKMNPQRSTUVWXYZ` (23 uppercase letters; `I`, `L`, `O` removed) |
| Casing | Always uppercase on the wire; UI should `uppercase()` user input |

The alphabet and length **must match every other platform exactly** —
both sides hash the code to select the starting broker, and a mismatch
(one side digits-included, the other letters-only) means they pick
different brokers and never meet.

```
hash = 0x811C9DC5            # FNV-1a 32-bit offset basis
for each byte in code.utf8:
    hash = (hash XOR byte) * 0x01000193 mod 2^32
return hash mod len(brokers)
```

ASCII-only pairing codes mean the UTF-8 bytes are the raw ASCII values;
results are deterministic across all platforms.

Reference test vectors (use these to validate your implementation):

| code    | hash (hex)   | index (mod 3) |
|---------|--------------|---------------|
| `ABCDE` | `0x041153a8` | 2 |
| `QWERT` | `0xe4e8af3a` | 0 |
| `ZZZZZ` | `0x82941d6d` | 2 |
| `BNJPS` | `0xbcdf3d30` | 1 |
| `KMHRX` | `0x37693d25` | 0 |

If your implementation produces a different index for any of these, you've
diverged — find the bug before going further.

### Per-broker connect timeout — **MUST match other platforms exactly**

This is the single most subtle source of cross-platform failure we hit.

If both sides hash to broker N and N is reachable from both, perfect. But if
one side's MQTT library completes the WSS+TLS+CONNECT handshake in 5 s and
the other times out at 6 s, **they walk to different brokers** on the
fallback chain and never meet. The retained offer ends up on one broker
while the peer subscribes on another.

**Mitigation:**

1. Per-broker timeout: **6 s on every platform**.
2. Fallback walk order is `(start + i) mod N`, identical on every platform.
3. If your platform's MQTT/WSS stack is unusually slow on first connect,
   investigate the underlying issue rather than bumping the timeout. (On
   macOS via CocoaMQTT the original slowness turned out to be a missing
   TLS-trust callback — see §6 below.)

### Topic naming

```
bluesteal/v1/<code>/offer    (retained — host publishes once)
bluesteal/v1/<code>/answer   (peer publishes once)
bluesteal/v1/<code>/ice/host (host trickle ICE)
bluesteal/v1/<code>/ice/peer (peer trickle ICE)
bluesteal/v1/<code>/bye      (either side announces close)
```

Both sides subscribe **before** anything is published. The Host's `offer` is
retained (QoS 1, `retain=true`); everything else is non-retained.

Origin filtering: the Host subscribes to `…/answer`, `…/ice/peer`, and
`…/bye`; the Peer subscribes to `…/offer`, `…/ice/host`, and `…/bye`. The
Host should additionally **ignore** messages it receives on `…/offer` or
`…/ice/host` (the broker may echo retained messages back to the publisher).
Log filtered messages as `signaling.receive.filtered { reason: "ownOrigin" }`
so they show up in the trace.

---

## 3. Signaling wire format — the JSON the broker carries

All messages are UTF-8 JSON, one message per MQTT publish, no envelopes
beyond the message itself.

### Tagged union shape

```jsonc
// offer
{ "type": "offer",  "payload": { "sdp": "v=0\r\n…" } }

// answer
{ "type": "answer", "payload": { "sdp": "v=0\r\n…" } }

// ICE candidate (one per message, trickled)
{ "type": "ice",    "payload": {
    "sdp": "candidate:1497987091 1 udp 2122194687 192.168.1.165 50172 typ host generation 0 …",
    "sdpMid": "0",
    "sdpMLineIndex": 0
}}

// bye (sent on cancel / DC close / ICE failed)
{ "type": "bye", "reason": "cancelled" }
```

Quirks to be aware of:

- **`type` always present.** Some Swift/C# enum-with-payload encoders default
  to a different shape (e.g. `{"offer": {"sdp": "…"}}` — Swift's default
  Codable). That shape **is not the wire format** and breaks cross-platform
  pairing. Write a custom encoder/decoder if your language defaults
  elsewhere.
- **`bye` does not have a `payload` wrapper.** It has `reason` at top level.
- **`sdpMid`** may be `null` or omitted for some candidates (SIPSorcery on
  Windows emits null `sdpMid` for some host candidates). Always populate
  `sdpMLineIndex` so the candidate is valid even without `sdpMid`.
- **Key order is not significant.** Both reference implementations parse by
  field name, not position. Don't depend on `type` being first when decoding.

---

## 4. WebRTC SDP + ICE — the one prefix that matters

### Use the standard W3C WebRTC offer/answer/ICE flow

- Host: `createDataChannel` (label: `bluesteal.adverts`, ordered) →
  `createOffer` → `setLocalDescription` → publish offer →
  receive answer → `setRemoteDescription`.
- Peer: receive offer → `setRemoteDescription` → `createAnswer` →
  `setLocalDescription` → publish answer.
- Trickled ICE on both sides; buffer locally generated candidates until
  the remote description is set; buffer remote candidates until the local
  description is set.

Default ICE servers (Google STUN + openrelay TURN):

```
stun:stun.l.google.com:19302
stun:stun1.l.google.com:19302
stun:stun.cloudflare.com:3478
turn:openrelay.metered.ca:80    (user: openrelayproject pass: openrelayproject)
turn:openrelay.metered.ca:443   (user: openrelayproject pass: openrelayproject)
```

### ICE candidate string format — **the `candidate:` prefix**

The W3C spec says the `candidate` member of `RTCIceCandidateInit` includes
the `candidate:` prefix:

```
candidate:1497987091 1 udp 2122194687 192.168.1.165 50172 typ host generation 0 …
└── must include this ─┘
```

**However, SIPSorcery (Windows) emits the bare value form** (no `candidate:`
prefix). Google's WebRTC (used on macOS) rejects bare-value candidates with
`Error processing ICE candidate`.

**Defensive rule for any port:**

- When **encoding** for the wire, always include `candidate:`.
- When **decoding** from the wire, accept both: if the string does not start
  with `candidate:`, prepend it before handing to your WebRTC binding.

This one-line fix is the difference between "ICE never starts" and "ICE
pairs in milliseconds".

---

## 5. Data-channel wire format

After `RTCDataChannel.readyState == "open"`, signaling is dropped and the DC
becomes the only path. Each DC message is one UTF-8 JSON object.

```jsonc
// advert (Host → Peer, every time the local scanner observes a caBLE advert)
{ "type": "advert", "payload": {
    "id": "BCE9072F-…|673450ad…",
    "ts": "2026-05-18T21:33:07.123Z",
    "peripheralID": "BCE9072F-5DAA-4774-7720-3774FE760AF6",
    "serviceUUID": "FFF9",            // null/omitted for manufacturer-only adverts
    "manufacturerId": 224,            // 0x00E0 for Google manufacturer-only adverts; null otherwise
    "payloadHex": "673450ad…",
    "variant": "fidoV2",              // "fidoV2" | "googleV1" | "googleV2" | "googleMfgV1" | "unknown(…)"
    "rssi": -43,
    "count": 5,
    "firstSeen": "…",
    "lastSeen": "…",
    "localName": "…",                 // optional
    "manufacturerHex": "…",           // optional
    "advertisedServiceUUIDs": ["…"],  // optional
    "txPowerLevel": -8,               // optional
    "isConnectable": true             // optional
}}

// heartbeat (every 5 s, both directions, indicates "still alive")
{ "type": "heartbeat", "payload": {
    "ts": "2026-05-18T21:33:00Z",
    "knownIds": ["id-1", "id-2"]
}}

// bye
{ "type": "bye", "reason": "user" }
```

### Peripheral ID convention

macOS uses native `CBPeripheralIdentifier` UUIDs (random). Windows has a
48-bit Bluetooth MAC address, which it encodes as
`00000000-0000-0000-0000-XXXXXXXXXXXX` — the trailing 12 hex chars are the
MAC. **Treat `peripheralID` as opaque** for identity purposes; do not parse
it as a true UUID or as a MAC unless you know the producer's convention.

### Optional / nullable fields

Use whatever your language's idiomatic "absent" representation is when
encoding (Swift `nil` / C# `null` / Rust `None` / TypeScript `undefined`)
and configure your serializer to **omit nulls** rather than emitting them
explicitly. Decoders on the other side must treat missing-or-null as
equivalent. The macOS Swift Codable default does this naturally; the
Windows side uses `JsonIgnoreCondition.WhenWritingNull` on its serializer.

### Schema evolution

Add new optional fields freely — both sides will safely ignore unknown
fields. **Never** rename, retype, or remove existing fields without a
migration. The `manufacturerId` field was added this way (macOS sender
populates it from the leading 2 bytes of `manufacturerData`; older Windows
clients ignored it; newer Windows clients consume it).

---

## 6. Platform-library gotchas (the ones we hit)

Distilled from the debug session. Each of these cost hours.

### 6a. TLS trust callback for WSS-based MQTT (macOS / CocoaMQTT)

Some MQTT libraries that wrap a WebSocket layer forward the TLS auth
challenge to an **optional** delegate method on the application's MQTT
delegate. If you don't implement that method, the challenge handler is
never resolved and the WSS task waits for its internal challenge timeout
(~30 s) before cancelling with `certificate unknown` — manifested as
`boringssl … CERTIFICATE_VERIFY_FAILED`. The certs are fine; the callback
is unwired.

If you see TLS errors but `curl` to the same broker WSS endpoint succeeds,
and a vanilla `URLSession.dataTask` to `https://broker:port/` accepts the
cert, check whether your MQTT library has a TLS trust callback you need to
implement. The minimum impl: invoke the completion handler with "use the
OS default trust evaluation".

CocoaMQTT-specific minimal fix (Swift):

```swift
extension MQTTDelegateProxy: CocoaMQTTDelegate {
    func mqtt(_ mqtt: CocoaMQTT, didReceive trust: SecTrust,
              completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)   // defer to OS default trust evaluation
    }
}
```

### 6b. UDP socket binding requires explicit permission on sandboxed
       / mobile / firewalled targets

WebRTC ICE gathering binds UDP sockets locally to (1) issue STUN binding
requests and receive the reflexive-address response, and (2) accept inbound
UDP for nominated candidate pairs. On sandboxed platforms this requires
explicit permission:

- **macOS app sandbox**: needs `com.apple.security.network.server`
  (entitlement) in addition to `com.apple.security.network.client`. Without
  `server`, the sandbox silently blocks UDP binds and WebRTC falls back to
  emitting **only TCP-active host candidates**, which cannot pair with
  another TCP-active candidate (one side must be passive).
- **iOS / Android**: equivalent entitlements / manifest permissions.
- **Linux**: outbound firewall typically fine; verify `iptables` / `nftables`.
- **Web (browser)**: the browser handles this; not your concern.

**Symptom** of this bug: trace shows only `type=host` candidates with
`proto=tcp` and `tcptype=active`, no `udp`, no `srflx`, no `relay`. ICE
stops at `connectionState=checking` and never reaches `connected`.

### 6c. Default enum-with-payload Codable does not match the wire format

The wire is `{"type": "...", "payload": {...}}`. Swift's default Codable
for an associated-value enum produces `{"<caseName>": {...}}`. C#'s
`System.Text.Json` with `[JsonDerivedType]` produces something else again.
**Write a custom serializer** to emit and accept the exact shape in §3 /
§5.

### 6d. Late delegate callbacks from torn-down MQTT clients

When you implement broker-walk-on-timeout (§2), the timed-out broker's MQTT
library may still deliver a late `didConnect` / `didDisconnect` callback
after you've torn it down and started the next attempt. **Gate every MQTT
delegate callback on the firing client's identity** so the late callbacks
become no-ops instead of stomping on the new attempt.

```swift
// macOS
func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: …) {
    guard mqtt === self.activeClient else { return /* stale */ }
    …
}
```

### 6e. Data channel may arrive already-open

On the Peer, some WebRTC implementations (Apple WebRTC.framework, SIPSorcery
on Windows) deliver the incoming `RTCDataChannel` to the
`peerConnection.onDataChannel` callback with `readyState == open` *before*
you've had a chance to attach an `onopen` handler. The handler never fires
and the Peer stays in `negotiating` forever even though the channel is
actually usable.

**Defensive rule:** in your `onDataChannel` handler, after wiring up your
`onopen` listener, synchronously check `readyState`. If it's already
`open`, invoke the open path manually. Log this case so it shows up in the
trace.

### 6f. The Host's offer can be silently dropped if it's published
       before MQTT is connected

Don't `createOffer` and publish synchronously after `connect()`. The MQTT
connect is asynchronous; the publish will be silently dropped if the
client isn't connected yet. Move the offer creation into the
`signalingDidConnect` callback, and gate it against the session having
been torn down between `connect()` and `connected`.

---

## 7. Tracer — the structured event log

Both reference implementations write JSONL traces to disk so two sessions
can be diffed line for line. **Implementing a compatible tracer in your
port saves hours of debugging.**

### Path conventions

| Platform | Path |
|---|---|
| macOS | `~/Library/Application Support/bluesteal/Logs/relay-<yyyy-MM-dd>-<pid>.jsonl` |
| Windows | `%LOCALAPPDATA%\bluesteal\Logs\relay-<yyyy-MM-dd>-<pid>.jsonl` |
| Linux (suggested) | `$XDG_STATE_HOME/bluesteal/logs/relay-<yyyy-MM-dd>-<pid>.jsonl` |

### Record shape

One line per event, JSON object:

```jsonc
{
  "ts":         "2026-05-18T20:46:31.375Z",  // ISO 8601 UTC with ms
  "pid":        12345,                       // process id
  "instanceId": "a1b2c3d4",                  // short UUID per process
  "role":       "Host" | "Peer" | "none",
  "code":       "ABCD2345",                  // pairing code or ""
  "category":   "mqtt" | "signaling" | "relay" | "state" | "ice" | "pc" | "dc" | "app" | "error",
  "event":      "mqtt.connect.attempt",      // see vocabulary below
  "data":       { "host": "…", "port": 8884, /* event-specific */ }
}
```

### Required event vocabulary

Use these exact names — they're the "diff units" between two trace files.

| Category | Events |
|---|---|
| `app` | `app.start` |
| `mqtt` | `mqtt.connect.start`, `mqtt.connect.attempt`, `mqtt.connect.connected`, `mqtt.connect.timeout`, `mqtt.connect.failed`, `mqtt.connect.cancelled`, `mqtt.connect.exhausted`, `mqtt.subscribed`, `mqtt.publish`, `mqtt.publish.skipped`, `mqtt.publish.error`, `mqtt.disconnected`, `mqtt.disconnected.ignored` |
| `signaling` | `signaling.publish`, `signaling.publish.skipped`, `signaling.publish.error`, `signaling.receive`, `signaling.receive.filtered`, `signaling.receive.empty`, `signaling.parse.error`, `signaling.unexpected` |
| `relay` | `relay.host`, `relay.join`, `relay.disconnect`, `relay.signaling.connected`, `relay.signaling.connected.ignored` |
| `state` | `state.change` |
| `pc` | `pc.created`, `pc.createOffer`, `pc.createAnswer`, `pc.setLocalDescription`, `pc.setRemoteDescription`, `pc.connectionState` |
| `ice` | `ice.gatheringState`, `ice.connectionState`, `ice.local`, `ice.local.flush`, `ice.remote.apply`, `ice.remote.buffer`, `ice.remote.drain`, `ice.remote.add.ok`, `ice.remote.add.error` |
| `dc` | `dc.created`, `dc.received`, `dc.alreadyOpen`, `dc.stateChange`, `dc.open`, `dc.close`, `dc.send`, `dc.send.skipped`, `dc.send.error`, `dc.message`, `dc.parse.error` |
| `error` | catch-all for any operation that failed unexpectedly |

When something goes wrong cross-platform, the very first divergent event
name between the two trace files pinpoints the broken step.

---

## 8. Validation plan for a new port

Run these in order. **Do not skip earlier steps if a later one fails** —
you'll get false positives.

### Step 0 — unit tests for pure logic

1. FNV-1a hash test vectors (see §2).
2. Wire-format round trip: encode every variant (offer/answer/ice/bye and
   advert/heartbeat/bye), then decode the JSON; assert equality. Test
   omitted optional fields, null vs missing, etc.
3. ICE candidate normalisation: assert your decoder accepts both
   `"candidate:foundation …"` and `"foundation …"`.

### Step 1 — same-platform pairing

Two instances of your port pair locally. Walks through:

- `mqtt.connect.start` on both → same `startingBrokerIndex` for the same code.
- Both reach `mqtt.connected` on the same broker.
- Host: `pc.createOffer` → `signaling.publish` → Peer: `signaling.receive`.
- Peer: `pc.setRemoteDescription { result: OK }` → `pc.createAnswer` →
  `signaling.publish`.
- Host: `signaling.receive` → `pc.setRemoteDescription { result: OK }`.
- Both: `ice.local` events (host, srflx, possibly relay) and
  `ice.remote.add.ok` for the peer's candidates.
- Both: `ice.connectionState=connected` → `dc.open` → `state.change` to `open`.
- Within ~5 s: `dc.send {type: heartbeat}` and `dc.message` for the other
  side's heartbeat.

If `ice.local` only contains TCP-active host candidates, see §6b.

### Step 2 — cross-platform pairing

Pair your port against macOS, then against Windows. The trace files should
diff cleanly event-for-event up to per-side timings — every event should
appear in both files in the same order. Specific things to check:

- Same `startingBrokerIndex` for the same code on both sides.
- Same broker in `mqtt.connect.connected.host` on both sides.
- Both `pc.setRemoteDescription { result: OK }`.
- Both have at least one `ice.remote.add.ok` (proving your candidate
  encoding round-tripped through the other platform's WebRTC).
- Both `dc.open`.

If only one side reaches `connected`, the trace file of the other side will
show exactly where it diverged — likely `signaling.parse.error` (wire
format mismatch) or `mqtt.connected { host: X }` differing across the two
files (broker divergence).

### Step 3 — interruption / cancel / re-host

- Cancel mid-handshake on either side → other side should observe a clean
  `bye` and transition to `closed`.
- Host then re-hosts with a new code → no state from the previous session
  bleeds in (no stale `relay.signaling.connected.ignored`, no stuck broker
  attempt counter).
- Peer sends bad JSON on the data channel → other side logs
  `dc.parse.error` and stays open (doesn't crash, doesn't disconnect).

---

## 9. Open questions / future work (not blocking a new port)

These are flagged in the existing docs but not yet implemented; a new port
should leave space for them but doesn't need to ship them on day one.

- **Loop guard before re-broadcast.** If either side re-emits received
  adverts over BLE, both sides must add an origin/seenIds gate before
  re-broadcast.
- **Heartbeat `knownIds` reconciliation.** The field is sent every 5 s but
  not consumed today. If you don't implement re-broadcast, consider
  dropping the field to save bandwidth on busy scans (but coordinate
  removal across all platforms — see "schema evolution" in §5).
- **TURN credential rotation.** The hardcoded openrelay.metered.ca
  credentials are public and may expire. Plan for credential refresh /
  alternative TURN servers if you target restrictive networks.

---

## 10. Provenance

This guide was written 2026-05-18 after getting macOS↔Windows pairing
working end-to-end. Every section corresponds to a specific bug we hit and
fixed during that session. If you're porting and hit something this guide
doesn't cover, please extend it.
