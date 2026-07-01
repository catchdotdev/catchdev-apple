#if canImport(UIKit)
import UIKit

/// Drives the Record flow, which must OUTLIVE the reporter: tapping Record dismisses the
/// reporter (so the host app is recordable), and the reporter is then deallocated — so the
/// recorder and the floating Stop control are owned here, by a singleton, not by the
/// reporter. On stop, the recording is appended to `ReporterViewController.pendingRestore`
/// and the reporter is re-presented restoring the draft.
final class ReporterRecordingSession {
    static let shared = ReporterRecordingSession()

    private let recorder = ScreenRecorder()
    private var window: RecordingStopWindow?

    private init() {}

    var isAvailable: Bool { recorder.isAvailable }

    /// Start the capture. `onStarted` fires only once recording is actually rolling (the
    /// caller dismisses the reporter there); `onUnavailable` fires if it can't start, so the
    /// caller can keep the reporter up and inform the user instead of leaving them on a
    /// dismissed-but-frozen screen.
    func begin(onStarted: @escaping () -> Void, onUnavailable: @escaping () -> Void) {
        guard recorder.isAvailable else {
            onUnavailable()
            return
        }
        recorder.startRecording { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    onStarted()
                    self?.showStopControl()
                case .failure:
                    onUnavailable()
                }
            }
        }
    }

    private func showStopControl() {
        let window = RecordingStopWindow()
        window.onStop = { [weak self] in self?.finish() }
        window.show()
        self.window = window
    }

    private func finish() {
        window?.hide()
        window = nil
        recorder.stopRecording { result in
            DispatchQueue.main.async {
                if case .success(let url) = result {
                    if let data = try? Data(contentsOf: url) {
                        ReporterViewController.pendingRestore?.attachments.append(
                            PendingAttachment(
                                kind: .recording, data: data,
                                contentType: "video/mp4", filename: "recording.mp4"
                            )
                        )
                    }
                    try? FileManager.default.removeItem(at: url) // don't leak the temp .mp4
                }
                CatchDev.shared.presentReporter()
            }
        }
    }
}
#endif
