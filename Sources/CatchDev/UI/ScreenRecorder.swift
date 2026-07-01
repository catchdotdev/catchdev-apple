#if canImport(UIKit)
import UIKit
#if canImport(ReplayKit)
import ReplayKit
#endif

/// Thin wrapper over ReplayKit for the reporter's "Record" tool: records the app's screen
/// to a temporary `.mp4`. ReplayKit is unavailable on the Simulator, so under
/// `-CatchDevUITest` this short-circuits to a tiny stub file, keeping the whole
/// record → attach → upload flow exercisable in UI tests.
final class ScreenRecorder {
    enum RecorderError: Error {
        case unavailable
        case failed(Error?)
    }

    /// True when running inside the example app's UI-test harness.
    static var isUITestStub: Bool {
        ProcessInfo.processInfo.arguments.contains("-CatchDevUITest")
    }

    /// UI-test hook: force recording to report unavailable, to exercise the graceful
    /// "reporter stays open + shows an alert" path (the real device/permission-denied case).
    static var isUITestForceUnavailable: Bool {
        ProcessInfo.processInfo.arguments.contains("-CatchDevRecordingUnavailable")
    }

    private(set) var isRecording = false

    var isAvailable: Bool {
        if Self.isUITestForceUnavailable { return false }
        if Self.isUITestStub { return true }
        #if targetEnvironment(simulator)
        // ReplayKit in-app capture doesn't produce a usable file on the Simulator; report
        // unavailable so the reporter shows a graceful message instead of a broken recording.
        return false
        #elseif canImport(ReplayKit)
        return RPScreenRecorder.shared().isAvailable
        #else
        return false
        #endif
    }

    func startRecording(completion: @escaping (Result<Void, Error>) -> Void) {
        if Self.isUITestStub {
            isRecording = true
            completion(.success(()))
            return
        }
        #if canImport(ReplayKit)
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            completion(.failure(RecorderError.unavailable))
            return
        }
        recorder.isMicrophoneEnabled = false
        recorder.startRecording { [weak self] error in
            if let error = error {
                completion(.failure(RecorderError.failed(error)))
            } else {
                self?.isRecording = true
                completion(.success(()))
            }
        }
        #else
        completion(.failure(RecorderError.unavailable))
        #endif
    }

    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        if Self.isUITestStub {
            isRecording = false
            completion(Self.writeStubFile())
            return
        }
        #if canImport(ReplayKit)
        let url = Self.tempURL()
        RPScreenRecorder.shared().stopRecording(withOutput: url) { [weak self] error in
            self?.isRecording = false
            if let error = error {
                completion(.failure(RecorderError.failed(error)))
            } else {
                completion(.success(url))
            }
        }
        #else
        completion(.failure(RecorderError.unavailable))
        #endif
    }

    private static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("catchdev-recording-\(UUID().uuidString).mp4")
    }

    private static func writeStubFile() -> Result<URL, Error> {
        let url = tempURL()
        do {
            try Data("catchdev-uitest-recording".utf8).write(to: url)
            return .success(url)
        } catch {
            return .failure(RecorderError.failed(error))
        }
    }
}
#endif
