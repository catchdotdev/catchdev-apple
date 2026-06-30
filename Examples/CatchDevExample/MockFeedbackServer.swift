import Foundation
import Network

/// A tiny in-process HTTP server used by the UI tests so `CatchDev` submissions succeed
/// deterministically without a real backend. The example app starts it under the
/// `-CatchDevUITest` launch argument and points `CatchDev` at `http://127.0.0.1:<port>`.
///
/// It routes the three requests the new reporter makes:
///   • `POST /api/v1/feedback/upload-url` → mint a (loopback) presigned URL + key
///   • `PUT  /upload/...`                 → accept the attachment bytes (200)
///   • `POST /api/v1/feedback/report`     → parse the multipart and reply `{ id }`
/// then surfaces the parsed report to the debug probe so the UI tests can assert exactly
/// what the SDK sent (type, severity, area, contact, attachment count, breadcrumbs, …).
final class MockFeedbackServer {
    struct ReceivedRequest {
        let screenName: String?
        let breadcrumbs: [String]
        let message: String?
        let type: String?
        let severity: String?
        let area: String?
        let email: String?
        let attachmentCount: Int
        let sessionId: String?
    }

    static let shared = MockFeedbackServer()

    /// Invoked (on a background queue) once a full `/feedback/report` has been parsed.
    var onRequestReceived: ((ReceivedRequest) -> Void)?

    /// Invoked (on a background queue) for EVERY request, for test diagnostics.
    var onAnyRequest: ((_ method: String, _ path: String) -> Void)?

    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    @discardableResult
    func start() -> UInt16 {
        guard listener == nil else { return port }
        do {
            let listener = try NWListener(using: .tcp)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global())
                self?.receive(on: connection, buffer: Data())
                // Safety net: URLSession opens speculative loopback connections that send
                // no data; left open, the receive on them never completes and they pile up
                // across many sends until the listener stops servicing real requests (a
                // hang with no error). Force-close every connection after a few seconds —
                // far longer than any real request needs.
                DispatchQueue.global().asyncAfter(deadline: .now() + 6) { connection.cancel() }
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

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buffer
            if let data = data, !data.isEmpty { buffer.append(data) }

            if self.isBodyComplete(buffer) || isComplete || error != nil {
                self.respond(on: connection, to: buffer)
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(on connection: NWConnection, to buffer: Data) {
        let (method, path) = Self.requestLine(buffer)
        onAnyRequest?(method, path)
        if path.contains("feedback/upload-url") {
            let key = "feedback/uploads/uitest-\(UUID().uuidString).bin"
            let url = "http://127.0.0.1:\(port)/upload/\(key)"
            send(json: "{\"uploadUrl\":\"\(url)\",\"key\":\"\(key)\",\"expiresIn\":600}", on: connection)
        } else if method == "PUT" {
            send(json: "{\"ok\":true}", on: connection)
        } else if path.contains("feedback/report") {
            handle(request: buffer)
            send(json: "{\"id\":\"uitest-123\"}", on: connection)
        } else {
            send(json: "{\"id\":\"uitest-123\"}", on: connection)
        }
    }

    private func send(json body: String, on connection: NWConnection) {
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
            // No body (e.g. a bodiless GET) — headers alone complete the request.
            return true
        }
        let bodyCount = buffer.distance(from: headerRange.upperBound, to: buffer.endIndex)
        return bodyCount >= length
    }

    private func handle(request buffer: Data) {
        guard let onRequestReceived = onRequestReceived else { return }
        guard
            let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)),
            let boundary = boundary(in: buffer)
        else { return }
        let body = buffer.subdata(in: headerRange.upperBound..<buffer.endIndex)
        let fields = parseFields(body: body, boundary: boundary)
        func str(_ key: String) -> String? { fields[key].flatMap { String(data: $0, encoding: .utf8) } }

        let metaString = str("meta")
        onRequestReceived(ReceivedRequest(
            screenName: str("screenName"),
            breadcrumbs: metaString.map(Self.breadcrumbs(fromMeta:)) ?? [],
            message: str("message"),
            type: str("type"),
            severity: str("severity"),
            area: str("area"),
            email: str("email"),
            attachmentCount: str("attachments").flatMap(Self.attachmentCount(fromJSON:)) ?? 0,
            sessionId: metaString.flatMap(Self.sessionId(fromMeta:))
        ))
    }

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

    private static func requestLine(_ buffer: Data) -> (method: String, path: String) {
        guard
            let lineEnd = buffer.range(of: Data("\r\n".utf8)),
            let line = String(data: buffer.subdata(in: buffer.startIndex..<lineEnd.lowerBound), encoding: .utf8)
        else { return ("", "") }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return ("", "") }
        return (String(parts[0]), String(parts[1]))
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

    private static func sessionId(fromMeta meta: String) -> String? {
        guard
            let data = meta.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["catchdev.sessionId"] as? String
    }

    private static func attachmentCount(fromJSON json: String) -> Int? {
        guard
            let data = json.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }
        return array.count
    }
}
