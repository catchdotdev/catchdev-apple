import Foundation

/// Builds and sends the `multipart/form-data` request for a feedback report.
/// Foundation-only (URLSession), so it compiles and unit-tests on any platform.
final class FeedbackClient {
    private let session: URLSession
    private let boundaryProvider: () -> String

    init(
        session: URLSession = .shared,
        boundaryProvider: @escaping () -> String = { "catchdev-\(UUID().uuidString)" }
    ) {
        self.session = session
        self.boundaryProvider = boundaryProvider
    }

    /// Construct the request without sending it (exposed for unit tests).
    func makeRequest(report: FeedbackReport, configuration: Configuration) -> URLRequest {
        var form = MultipartFormData(boundary: boundaryProvider())
        form.addField(name: "message", value: report.message)
        form.addField(name: "type", value: report.type.rawValue)
        report.severity.map { form.addField(name: "severity", value: $0.rawValue) }
        report.area.map { form.addField(name: "area", value: $0) }
        report.attachmentsJSONString.map { form.addField(name: "attachments", value: $0) }
        report.email.map { form.addField(name: "email", value: $0) }
        report.userId.map { form.addField(name: "userId", value: $0) }
        report.appVersion.map { form.addField(name: "appVersion", value: $0) }
        report.appBuild.map { form.addField(name: "appBuild", value: $0) }
        report.osVersion.map { form.addField(name: "osVersion", value: $0) }
        report.device.map { form.addField(name: "device", value: $0) }
        report.platform.map { form.addField(name: "platform", value: $0) }
        report.environment.map { form.addField(name: "environment", value: $0) }
        report.screenName.map { form.addField(name: "screenName", value: $0) }
        report.locale.map { form.addField(name: "locale", value: $0) }
        form.addField(name: "sdk", value: report.sdk)
        form.addField(name: "sdkVersion", value: report.sdkVersion)
        form.addField(name: "time", value: report.time)
        form.addField(name: "reportId", value: report.reportId)
        report.metaJSONString.map { form.addField(name: "meta", value: $0) }
        if let image = report.imageData {
            form.addFile(
                name: "screenshot",
                filename: "screenshot.jpg",
                contentType: report.imageContentType,
                data: image
            )
        }

        let url = configuration.endpoint.appendingPathComponent("api/v1/feedback/report")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-access-token")
        request.setValue(form.contentTypeHeader, forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: catchDevInternalHeader)
        request.httpBody = form.encoded()
        return request
    }

    func send(
        _ report: FeedbackReport,
        configuration: Configuration,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let request = makeRequest(report: report, configuration: configuration)
        perform(request, retriesRemaining: 1, completion: completion)
    }

    private func perform(
        _ request: URLRequest,
        retriesRemaining: Int,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                if retriesRemaining > 0 {
                    self?.perform(request, retriesRemaining: retriesRemaining - 1, completion: completion)
                } else {
                    completion(.failure(CatchDevError.transport(error)))
                }
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                completion(.failure(CatchDevError.server(status: status)))
                return
            }

            var id = ""
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = json["id"] as? String {
                id = value
            }
            completion(.success(id))
        }
        task.resume()
    }
}
