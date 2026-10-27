import Foundation
import Network
import os

/// A small HTTP/1.1 server on Network.framework: one request per connection, then
/// close. It sits behind cloudflared on localhost and sees little traffic.
final class HTTPServer: Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    /// A client that hasn't sent a whole request by then is cut off.
    static let requestTimeout: TimeInterval = 15

    private let listener: NWListener
    private let queue = DispatchQueue(label: "washtower-relay.http")
    private let handler: Handler

    init(host: String, port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    /// Starts listening; returns the bound port once the listener is ready.
    func start() async throws -> UInt16 {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard !resumed.withLock({ let was = $0; $0 = true; return was }) else { return }
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    if resumed.withLock({ let was = $0; $0 = true; return was }) {
                        Log.error("HTTP listener failed: \(error)")
                    } else {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Cancelling a connection that already finished does nothing.
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { connection.cancel() }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequestParser.parse(buffer) {
            case .complete(let request):
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    Self.send(response, on: connection)
                }
            case .invalid(let status, let reason):
                Self.send(.error(status, reason), on: connection)
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private static func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
