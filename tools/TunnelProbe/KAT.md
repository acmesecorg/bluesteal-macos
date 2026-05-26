# caBLE Tunnel — Known-Answer Test Vectors

Authoritative vectors generated from the **Windows C# crypto** (the canonical
implementation) via a throwaway net10.0 console that compiled
`Bluesteal/Crypto/CableNoise/*.cs` directly. The Swift port must reproduce
these byte-for-byte given identical inputs.

Verified Phase 0 (2026-05-26):
- `psk` and `responder_seed` below already match CryptoKit HKDF output exactly.
- Legacy salt-empty `tunnel_id(BSTL1)` = `377B0B4170FBAD1FEFEFFE0BAF6E3402`
  (CryptoKit HKDF == .NET HKDF confirmed).
- `URLSessionWebSocketTask` can read the `X-caBLE-Routing-ID` response header.

## Key derivation (code = `BSTL1`, all HKDF-SHA256)

| Output | Salt | Info label | Value (hex) |
|---|---|---|---|
| psk | empty | `bluesteal/psk` | `E4BCC2256F15E1E990541F50E86350161364AD9F221C6CF98697C156E12C0843` |
| responder_seed | empty | `bluesteal/responder-static` | `D47890BCF7A16A88CA7CAD6259297631C3C175FA47B06939A73FDBF793FD74C1` |
| tunnel_id (legacy) | empty | `bluesteal/tunnel-id` | `377B0B4170FBAD1FEFEFFE0BAF6E3402` |

`tunnel_id_m` = HKDF(ikm=UTF8(code), salt=Int64-little-endian(minute),
info=`bluesteal/tunnel-minute`, len=16).

## P256 derive-from-seed (the high-risk port)

`P256.DeriveKeyFromSeed(seed)` = HKDF-SHA256(ikm=seed,
salt=ASCII`"EC_KEY_derive_from_secret"`, info=empty, len=48) → BigInteger
(unsigned big-endian) mod n → 32-byte BE private scalar.

| Input seed (hex) | → public key X9.62 uncompressed (hex) |
|---|---|
| responder_seed `D47890BC…74C1` | `0451EBBBE5E90DEC6D7571B911212788C09B4A1FDD7C9443F93749A1F51A168A61D08E1F7DFDB61FD96FD141C9A51E0CAEBC8A9CEBB86B98E290D13158B8E40570` |
| `11`×32 (init ephemeral) | `041FB5CC2A13F0AFEA7C9639E79C3F613D522D408F6124F263ACAB97520B3BEEA7688AEDED4BECEF79446130630310FDFDA2D87333BD79A6D22A114DF4AB31E71C` |
| `22`×32 (resp ephemeral) | `0444361852C0E53A499B796EE766E0C8ACB921533F91F4970DD28F060D64B49DA13829474C176DF9A878DF5C8CBD1220D015BB719471C080C5795D1B752C1FC7D8` |

## Deterministic NKpsk0 handshake transcript

Inputs: psk = BSTL1 psk; responder static = derive(responder_seed); initiator
ephemeral = derive(`11`×32); responder ephemeral = derive(`22`×32).

```
initial_message (peer→host, 65B eph pubkey || 16B ciphertext):
  041FB5CC2A13F0AFEA7C9639E79C3F613D522D408F6124F263ACAB97520B3BEEA7688AEDED4BECEF79446130630310FDFDA2D87333BD79A6D22A114DF4AB31E71C
  AB700F9C508B3B81099C93236F4812C8

response (host→peer, 65B eph pubkey || 16B ciphertext):
  0444361852C0E53A499B796EE766E0C8ACB921533F91F4970DD28F060D64B49DA13829474C176DF9A878DF5C8CBD1220D015BB719471C080C5795D1B752C1FC7D8
  3F65DCCA0559E2F681095227E0D0F58B
```

## Post-handshake Crypter sample

After the above handshake, initiator's first `Crypter.Encrypt("hello")`
(UTF-8 `hello`, 32-byte padding scheme, BE seq=0 at nonce offset 8, empty AAD):

```
crypter_encrypt(hello) = BFAC748198B0676C0286598995BA020A83FCB65164C01F4B76C93F3BFE9E10D37D48C12483CACEFF2EFF84A8559E169E
```

Responder `Decrypt` of that ciphertext → `hello`.
