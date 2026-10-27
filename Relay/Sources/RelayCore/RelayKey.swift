import CryptoKit
import Foundation

/// The shared secret the phone sends as `Authorization: Bearer <key>`: 32 random
/// bytes as hex, in a mode-600 file. `pair` shows it to the phone as a QR code.
enum RelayKey {
    enum Problem: LocalizedError {
        case malformed(URL)

        var errorDescription: String? {
            switch self {
            case .malformed(let url): "\(url.path) isn't 64 hex characters. Delete it and pair again."
            }
        }
    }

    static func load(from url: URL) throws -> String? {
        guard let key = Files.readTrimmed(url) else { return nil }
        guard key.count == 64, Hex.normalizedToken(key) != nil else { throw Problem.malformed(url) }
        return key.lowercased()
    }

    /// The existing key, or a new one saved to `url`.
    static func ensure(at url: URL) throws -> (key: String, created: Bool) {
        if let key = try load(from: url) { return (key, false) }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Hex.encode($0) }
        try Files.writePrivate(Data((key + "\n").utf8), to: url)
        return (key, true)
    }

    /// washtower://pair?url=<percent-encoded url>&key=<key>
    static func pairLink(url: String, key: String) -> String {
        var unreserved = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        unreserved.insert(charactersIn: "-._~")
        let encoded = url.addingPercentEncoding(withAllowedCharacters: unreserved) ?? url
        return "washtower://pair?url=\(encoded)&key=\(key)"
    }

    /// Compares without returning early, so response timing doesn't leak the key.
    static func matches(_ candidate: String, key: String) -> Bool {
        let a = Array(candidate.utf8), b = Array(key.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<b.count {
            difference |= (index < a.count ? a[index] : 0) ^ b[index]
        }
        return difference == 0
    }
}
