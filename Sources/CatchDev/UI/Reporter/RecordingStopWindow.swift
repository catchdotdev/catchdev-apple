#if canImport(UIKit)
import UIKit

/// A floating "● Stop recording" pill shown in its own pass-through window while the
/// reporter is dismissed for a screen recording, so the host app stays fully interactive
/// underneath. Only the pill receives touches; everything else falls through to the host.
final class RecordingStopWindow {
    var onStop: (() -> Void)?
    private var window: UIWindow?

    func show() {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear

        let root = UIViewController()
        let passthrough = PassthroughView()
        passthrough.backgroundColor = .clear
        root.view = passthrough
        window.rootViewController = root

        let pill = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = "Stop recording"
        config.image = UIImage(systemName: "stop.circle.fill")
        config.imagePadding = 7
        config.baseBackgroundColor = UIColor(white: 0.05, alpha: 0.92)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.titleTextAttributesTransformer = .init { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 14, weight: .semibold)
            return out
        }
        pill.configuration = config
        pill.tintColor = .systemRed
        pill.accessibilityIdentifier = CatchDevReporterAccessibility.recordStop
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addAction(UIAction { [weak self] _ in self?.onStop?() }, for: .touchUpInside)
        passthrough.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: passthrough.safeAreaLayoutGuide.topAnchor, constant: 12),
            pill.centerXAnchor.constraint(equalTo: passthrough.centerXAnchor),
            pill.heightAnchor.constraint(equalToConstant: 44),
        ])

        window.isHidden = false
        self.window = window
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}

/// Root view that only claims touches landing on its subviews; taps on empty space fall
/// through to the window beneath (the host app).
private final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
#endif
