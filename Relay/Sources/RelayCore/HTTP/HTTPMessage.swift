import Foundation

/// A parsed HTTP/1.1 request.
struct HTTPRequest: Equatable, Sendable {
    var method: String
    /// The request target as sent, e.g. "/v1/devices/abc?x=1".
    var target: String
    /// Header names are lowercased; repeated headers are joined with ", ".
    var headers: [String: String]
    var body: Data

    /// Percent-decoded path segments without the query: "/v1/state" -> ["v1", "state"].
    var pathComponents: [String] {
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// The token from `Authorization: Bearer <token>`.
    var bearerToken: String? {
        guard let value = header("authorization") else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}

struct HTTPResponse: Equatable, Sendable {
    var status: Int
    var body: Data
    var contentType = "application/json"

    static func json(_ value: some Encodable, status: Int = 200) -> HTTPResponse {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return HTTPResponse(status: status, body: try encoder.encode(value))
        } catch {
            return .error(500, "couldn't encode the response")
        }
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }

    static let ok = json(["ok": true])

    /// The bytes on the wire. Every response closes the connection.
    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 413: "Content Too Large"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 505: "HTTP Version Not Supported"
        default: "Status"
        }
    }
}

/// Parses one request from the bytes received so far. Bodies are read by
/// Content-Length; chunked bodies are decoded too, in case a proxy sends one.
enum HTTPRequestParser {
    enum Result: Equatable, Sendable {
        /// Need more bytes.
        case incomplete
        case complete(HTTPRequest)
        /// Answer with this status and close.
        case invalid(status: Int, reason: String)
    }

    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 64 * 1024

    private static let crlf = Data("\r\n".utf8)
    private static let headerEnd = Data("\r\n\r\n".utf8)

    static func parse(_ buffer: Data) -> Result {
        guard let end = buffer.range(of: headerEnd) else {
            return buffer.count > maxHeaderBytes ? .invalid(status: 431, reason: "headers too large") : .incomplete
        }
        guard end.lowerBound - buffer.startIndex <= maxHeaderBytes else {
            return .invalid(status: 431, reason: "headers too large")
        }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400, reason: "headers aren't UTF-8")
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, !requestLine[0].isEmpty, requestLine[1].hasPrefix("/") else {
            return .invalid(status: 400, reason: "malformed request line")
        }
        guard requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0" else {
            return .invalid(status: 505, reason: "only HTTP/1.x is supported")
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                return .invalid(status: 400, reason: "malformed header line")
            }
            let name = line[..<colon].lowercased()
            guard !name.contains(" "), !name.contains("\t") else {
                return .invalid(status: 400, reason: "malformed header name")
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }

        let bodyStart = end.upperBound
        let body: Data
        if let encoding = headers["transfer-encoding"]?.lowercased() {
            guard encoding == "chunked" else { return .invalid(status: 501, reason: "unsupported transfer-encoding") }
            switch decodeChunked(buffer[bodyStart...]) {
            case .incomplete: return .incomplete
            case .invalid(let status, let reason): return .invalid(status: status, reason: reason)
            case .complete(let decoded): body = decoded
            }
        } else if let lengthHeader = headers["content-length"] {
            guard let length = Int(lengthHeader), length >= 0, lengthHeader.allSatisfy(\.isASCII) else {
                return .invalid(status: 400, reason: "bad content-length")
            }
            guard length <= maxBodyBytes else { return .invalid(status: 413, reason: "body too large") }
            guard buffer.endIndex - bodyStart >= length else { return .incomplete }
            body = Data(buffer[bodyStart..<(bodyStart + length)])
        } else {
            body = Data()
        }

        return .complete(HTTPRequest(
            method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: body))
    }

    private enum ChunkResult {
        case incomplete
        case complete(Data)
        case invalid(Int, String)
    }

    private static func decodeChunked(_ bytes: Data) -> ChunkResult {
        var body = Data()
        var index = bytes.startIndex
        while true {
            guard let lineEnd = bytes.range(of: crlf, in: index..<bytes.endIndex) else {
                return bytes.endIndex - index > 1024 ? .invalid(400, "malformed chunk size") : .incomplete
            }
            let sizeLine = String(decoding: bytes[index..<lineEnd.lowerBound], as: UTF8.self)
            let sizeText = sizeLine.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                return .invalid(400, "malformed chunk size")
            }
            index = lineEnd.upperBound
            if size == 0 {
                // Trailers (ignored), then an empty line.
                while true {
                    guard let trailerEnd = bytes.range(of: crlf, in: index..<bytes.endIndex) else { return .incomplete }
                    let isEmpty = trailerEnd.lowerBound == index
                    index = trailerEnd.upperBound
                    if isEmpty { return .complete(body) }
                }
            }
            guard body.count + size <= maxBodyBytes else { return .invalid(413, "body too large") }
            guard bytes.endIndex - index >= size + 2 else { return .incomplete }
            body.append(bytes[index..<(index + size)])
            index += size
            guard bytes[index..<(index + 2)] == crlf else { return .invalid(400, "malformed chunk") }
            index += 2
        }
    }
}
