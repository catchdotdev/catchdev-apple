import Foundation
import Network

/// A tiny in-process HTTP server used by the UI tests so `CatchDev` submissions succeed
/// deterministically without a real backend. The example app starts it under the
/// `-CatchDevUITest` launch argument and points `CatchDev` at `http://localhost:<port>`.
///
/// We run a real loopback server rather than stubbing `URLProtocol`, because
/// `URLSession.shared` — which the SDK uses — does not consult globally registered
/// `URLProtocol` subclasses. This also exercises the real networking path. Beyond
/// replying 200, it parses the multipart body and reports the `screenName` and breadcrumb
/// trail it received, so the UI tests can assert what the SDK actually sent.
final class MockFeedbackServer {
    struct ReceivedRequest {
        let screenName: String?
        let breadcrumbs: [String]
        let message: String?
    }

    static let shared = MockFeedbackServer()

    /// Invoked (on a background queue) once a full request has been received and parsed.
    var onRequestReceived: ((ReceivedRequest) -> Void)?

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
                self?.receive(on: connection, buffer: Data())
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

    // MARK: - Receiving

    /// Accumulate bytes until the full body (per `Content-Length`) has arrived — a JPEG
    /// screenshot easily spans multiple TCP segments — then parse and reply.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buffer
            if let data = data, !data.isEmpty { buffer.append(data) }

            if self.isBodyComplete(buffer) || isComplete || error != nil {
                self.handle(request: buffer)
                self.sendOK(on: connection)
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func sendOK(on connection: NWConnection) {
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

    // MARK: - Parsing

    private func isBodyComplete(_ buffer: Data) -> Bool {
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
        guard let length = headerLine(named: "content-length", in: buffer).flatMap({ Int($0) }) else {
            return false
        }
        let bodyCount = buffer.distance(from: headerRange.upperBound, to: buffer.endIndex)
        return bodyCount >= length
    }

    private func handle(request buffer: Data) {
        guard let onRequestReceived = onRequestReceived else { return }
        // Never report a non-request (e.g. an empty connection from happy-eyeballs) — doing
        // so would clobber a good payload already surfaced to the probe.
        guard
            let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)),
            let boundary = boundary(in: buffer)
        else { return }
        let body = buffer.subdata(in: headerRange.upperBound..<buffer.endIndex)
        let fields = parseFields(body: body, boundary: boundary)
        let screenName = fields["screenName"].flatMap { String(data: $0, encoding: .utf8) }
        let message = fields["message"].flatMap { String(data: $0, encoding: .utf8) }
        let breadcrumbs = fields["meta"]
            .flatMap { String(data: $0, encoding: .utf8) }
            .map(Self.breadcrumbs(fromMeta:)) ?? []
        onRequestReceived(
            ReceivedRequest(screenName: screenName, breadcrumbs: breadcrumbs, message: message)
        )
    }

    /// Split a multipart body into `name` → raw value, skipping binary parts is not needed
    /// (callers only read the text fields). The screenshot's bytes are captured but unused.
    private func parseFields(body: Data, boundary: String) -> [String: Data] {
        var fields: [String: Data] = [:]
        let delimiter = Data("--\(boundary)".utf8)
        let headerSep = Data("\r\n\r\n".utf8)

        var positions: [Data.Index] = []
        var searchStart = body.startIndex
        while let range = body.range(of: delimiter, options: [], in: searchStart..<body.endIndex) {
            positions.append(range.lowerBound)
            searchStart = range.upperBound
        }
        guard positions.count >= 2 else { return fields }

        for i in 0..<(positions.count - 1) {
            let partStart = body.index(positions[i], offsetBy: delimiter.count)
            let partEnd = positions[i + 1]
            guard partStart < partEnd else { continue }
            let part = body.subdata(in: partStart..<partEnd)
            guard let sep = part.range(of: headerSep) else { continue }
            let headerData = part.subdata(in: part.startIndex..<sep.lowerBound)
            var content = part.subdata(in: sep.upperBound..<part.endIndex)
            // Strip the trailing CRLF that precedes the next boundary.
            if content.count >= 2 {
                content = content.subdata(in: content.startIndex..<content.index(content.endIndex, offsetBy: -2))
            }
            guard
                let headers = String(data: headerData, encoding: .utf8),
                let name = Self.name(inDisposition: headers)
            else { continue }
            fields[name] = content
        }
        return fields
    }

    private func headerLine(named name: String, in buffer: Data) -> String? {
        guard
            let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)),
            let headers = String(
                data: buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound),
                encoding: .utf8
            )
        else { return nil }
        for line in headers.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, parts[0].lowercased() == name { return parts[1] }
        }
        return nil
    }

    private func boundary(in buffer: Data) -> String? {
        guard
            let contentType = headerLine(named: "content-type", in: buffer),
            let range = contentType.range(of: "boundary=")
        else { return nil }
        return String(contentType[range.upperBound...])
    }

    private static func name(inDisposition headers: String) -> String? {
        guard let range = headers.range(of: "name=\"") else { return nil }
        let rest = headers[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func breadcrumbs(fromMeta meta: String) -> [String] {
        guard
            let data = meta.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let crumbs = object["catchdev.breadcrumbs"] as? [[String: Any]]
        else { return [] }
        return crumbs.compactMap { $0["screen"] as? String }
    }
}
