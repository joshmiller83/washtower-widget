import Foundation
import os

/// One line per event on stderr, which launchd sends to the relay's log file.
enum Log {
    private static let timestamp = Date.ISO8601FormatStyle(timeZone: .current)
    private static let muted = OSAllocatedUnfairLock(initialState: false)

    /// Tests call this to keep their output readable.
    static func mute() { muted.withLock { $0 = true } }

    static func info(_ message: String) { write("info", message) }
    static func warn(_ message: String) { write("warn", message) }
    static func error(_ message: String) { write("error", message) }

    private static func write(_ level: String, _ message: String) {
        guard !muted.withLock({ $0 }) else { return }
        let line = "\(Date().formatted(timestamp)) [\(level)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

enum Files {
    /// Writes a file only its owner can read, atomically: a reader sees the old
    /// contents or the new ones, never half of each.
    static func writePrivate(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path]) }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    static func readTrimmed(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum Hex {
    static func encode(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercased token if it's an even-length run of hex digits of a plausible length, else nil.
    static func normalizedToken(_ value: String) -> String? {
        let token = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard (16...1024).contains(token.count), token.count % 2 == 0,
              token.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return token
    }
}

extension String {
    /// A push token shortened for logs.
    var tokenPrefix: String { String(prefix(8)) + "…" }
}
