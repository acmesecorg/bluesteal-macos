import Foundation

/// Template for the gitignored `Secrets.swift`. Copy this file to
/// `Secrets.swift` in the same directory before first build, then fill in
/// real values minted from [Cloudflare Realtime TURN][1]. The committed copy
/// stays empty.
///
/// Empty strings are tolerated at build time and at runtime — the apps fall
/// back to STUN-only (no TURN relay path) when the credentials are blank.
///
/// See the root README and `TURN_ROTATION.local.md` for the curl command that
/// mints credentials and the exact paste targets.
///
/// [1]: https://dash.cloudflare.com/?to=/:account/calls
enum Secrets {
    static let turnUsername = ""
    static let turnCredential = ""
}
