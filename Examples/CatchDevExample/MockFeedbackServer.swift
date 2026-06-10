import Foundation
import Network

/// A tiny in-process HTTP server used by the UI tests so `CatchDev` submissions
/// succeed deterministically without a real backend. The example app starts it under
/// the `-CatchDevUITest` launch argument and points `CatchDev` at `http://localhost:<port>`.
///
/// We run a real loopback server rather than stubbing `URLProtocol`, because
/// `URLSession.shared` — which the SDK uses — does not consult globally registered
/// `URLProtocol` subclasses. This also exercises the real networking path.
final class MockFeedbackServer {
    static let shared = MockFeedbackServer()

    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    /// Starts the server and returns the bound port (0 if it failed to start).
    @discardableResult
    func start() -> UInt16 {
        guard listener == nil else { return port }
        do {
            let listener = try NWListener(using: .tcp)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global())
                self?.reply(on: connection)
            }
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.port = listener.port?.rawValue ?? 0
                    ready.signal()
                }
            }
            listener.start(queue: .global())
            self.listener = listener
            _ = ready.wait(timeout: .now() + 5)
            return port
        } catch {
            return 0
        }
    }

    private func reply(on connection: NWConnection) {
        // Read whatever the client sends, then reply 200 regardless of the request.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { _, _, _, _ in
            let body = #"{"id":"uitest-123"}"#
            let response = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(body.utf8.count)\r\n"
                + "Connection: close\r\n\r\n"
                + body
            connection.send(
                content: Data(response.utf8),
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }
}
