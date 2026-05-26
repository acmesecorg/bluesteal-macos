import Foundation
import CryptoKit

/// RFC 5869 HKDF-SHA256, implemented over CryptoKit HMAC so empty-IKM and
/// empty-salt cases behave identically to .NET's `HKDF.DeriveKey`.
/// (.NET follows RFC 5869: empty salt → HashLen zero bytes.)
enum HKDFShim {
    static func derive(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let saltKey = SymmetricKey(data: salt.isEmpty ? Data(repeating: 0, count: 32) : salt)
        let prk = HMAC<SHA256>.authenticationCode(for: ikm, using: saltKey)
        let prkKey = SymmetricKey(data: Data(prk))

        var output = Data()
        var t = Data()
        var counter: UInt8 = 1
        while output.count < length {
            var input = Data()
            input.append(t)
            input.append(info)
            input.append(counter)
            let block = HMAC<SHA256>.authenticationCode(for: input, using: prkKey)
            t = Data(block)
            output.append(t)
            counter = counter &+ 1
        }
        return output.prefix(length)
    }
}

extension Data {
    var hexUpper: String { map { String(format: "%02X", $0) }.joined() }
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var d = Data(capacity: hexString.count / 2)
        var idx = hexString.startIndex
        while idx < hexString.endIndex {
            let next = hexString.index(idx, offsetBy: 2)
            guard let b = UInt8(hexString[idx..<next], radix: 16) else { return nil }
            d.append(b)
            idx = next
        }
        self = d
    }
}
