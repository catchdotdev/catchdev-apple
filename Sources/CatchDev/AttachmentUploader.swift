import Foundation

/// HTTP header marking a request as SDK-internal, so ``CatchDevNetworkCapture`` never
/// records the SDK's own traffic as one of the host's "failed network calls".
let catchDevInternalHeader = "X-CatchDev-Internal"

/// Uploads an attachment's bytes DIRECTLY to Cloudflare R2 via a backend-minted
/// presigned PUT URL, so large files (especially recordings) never pass through the
/// catch.dev API and the SDK stays dependency-free. Two hops:
///   1. `POST <endpoint>/api/v1/feedback/upload-url` → `{ uploadUrl, key, expiresIn }`
///   2. `PUT` the bytes to `uploadUrl`
/// then yields an ``Attachment`` reference the report carries in its `attachments` field.
/// Foundation-only (URLSession), so it compiles and unit-tests on any platform.
final class AttachmentUploader {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    struct MintedUpload {
        let uploadURL: URL
        let key: String
    }

    /// Full upload: mint a URL, PUT the bytes, return the attachment reference.
    func upload(
        data: Data,
        kind: AttachmentKind,
        contentType: String,
        filename: String?,
        annotated: Bool,
        configuration: Configuration,
        completion: @escaping (Result<Attachment, Error>) -> Void
    ) {
        requestUploadURL(
            kind: kind,
            contentType: contentType,
            size: data.count,
            filename: filename,
            configuration: configuration
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let minted):
                self.put(data, to: minted.uploadURL, contentType: contentType) { putResult in
                    switch putResult {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success:
                        completion(.success(Attachment(
                            key: minted.key,
                            kind: kind,
                            contentType: contentType,
                            size: data.count,
                            filename: filename,
                            annotated: annotated ? true : nil
                        )))
                    }
                }
            }
        }
    }

    /// Step 1 — ask the backend for a presigned PUT URL (exposed for unit tests).
    func requestUploadURL(
        kind: AttachmentKind,
        contentType: String,
        size: Int,
        filename: String?,
        configuration: Configuration,
        completion: @escaping (Result<MintedUpload, Error>) -> Void
    ) {
        let url = configuration.endpoint.appendingPathComponent("api/v1/feedback/upload-url")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-access-token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: catchDevInternalHeader)
        var bodyObject: [String: Any] = [
            "kind": kind.rawValue,
            "contentType": contentType,
            "size": size,
        ]
        if let filename { bodyObject["filename"] = filename }
        request.httpBody = try? JSONSerialization.data(withJSONObject: bodyObject)

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(CatchDevError.transport(error)))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                completion(.failure(CatchDevError.server(status: status)))
                return
            }
            guard
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let uploadString = json["uploadUrl"] as? String,
                let uploadURL = URL(string: uploadString),
                let key = json["key"] as? String
            else {
                completion(.failure(CatchDevError.server(status: status)))
                return
            }
            completion(.success(MintedUpload(uploadURL: uploadURL, key: key)))
        }
        task.resume()
    }

    /// Step 2 — PUT the bytes straight to R2 (exposed for unit tests).
    func put(
        _ data: Data,
        to url: URL,
        contentType: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: catchDevInternalHeader)
        let task = session.uploadTask(with: request, from: data) { _, response, error in
            if let error = error {
                completion(.failure(CatchDevError.transport(error)))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                completion(.failure(CatchDevError.server(status: status)))
                return
            }
            completion(.success(()))
        }
        task.resume()
    }
}
