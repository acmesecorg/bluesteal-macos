//
//  PairingCode.swift
//  bluesteal
//
//  Generates the short human-shareable pairing code (the "CODE" half of a
//  tunnel token). Replaces the code generation that used to live on
//  `SignalingClient`. Mirrors Windows `Services/PairingCode.cs`.
//

import Foundation

enum PairingCode {
    /// Uppercase letters with the ambiguous I, L, O removed. **Must match the
    /// other platforms exactly** so a code generated on one device is typable
    /// on another.
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ")

    /// 5 letters from a 23-letter alphabet ≈ 6.4 M combinations.
    static let length = 5

    /// Generate a fresh pairing code. It lives only as long as the tunnel
    /// session and is human-typed across devices, so we favour ease-of-typing
    /// over entropy.
    static func make() -> String {
        String((0..<length).map { _ in alphabet.randomElement()! })
    }
}
