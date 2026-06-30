#if canImport(UIKit)
import UIKit

/// The drawing surface for ``AnnotateViewController``. Captures box / arrow / pen / blur
/// gestures in view coordinates, renders them live, and flattens them onto the source
/// image at native resolution (mapping view points → image pixels via `displayedImageRect`).
final class AnnotationCanvasView: UIView {
    enum Tool: String {
        case box, arrow, pen, blur
    }

    private enum Annotation {
        case pen(points: [CGPoint], color: UIColor)
        case box(rect: CGRect, color: UIColor)
        case arrow(from: CGPoint, to: CGPoint, color: UIColor)
        case blur(rect: CGRect)
    }

    var tool: Tool = .box
    var color: UIColor = .systemRed
    /// The aspect-fit rect the source image occupies in this view (set by the controller).
    var displayedImageRect: CGRect = .zero

    private var annotations: [Annotation] = []
    private var current: Annotation?
    private var penPoints: [CGPoint] = []
    private var startPoint: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        startPoint = point
        if tool == .pen { penPoints = [point] }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        switch tool {
        case .pen:
            penPoints.append(point)
            current = .pen(points: penPoints, color: color)
        case .box:
            current = .box(rect: rect(from: startPoint, to: point), color: color)
        case .arrow:
            current = .arrow(from: startPoint, to: point, color: color)
        case .blur:
            current = .blur(rect: rect(from: startPoint, to: point))
        }
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let current { annotations.append(current) }
        current = nil
        penPoints = []
        setNeedsDisplay()
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: - Live drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        for annotation in annotations { drawLive(annotation, in: ctx) }
        if let current { drawLive(current, in: ctx) }
    }

    private func drawLive(_ annotation: Annotation, in ctx: CGContext) {
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch annotation {
        case let .pen(points, color):
            guard points.count > 1 else { return }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(4)
            ctx.move(to: points[0])
            for p in points.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case let .box(r, color):
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(3)
            ctx.addPath(UIBezierPath(roundedRect: r, cornerRadius: 6).cgPath)
            ctx.strokePath()
        case let .arrow(from, to, color):
            ctx.setStrokeColor(color.cgColor)
            ctx.setFillColor(color.cgColor)
            ctx.setLineWidth(3)
            drawArrow(from: from, to: to, headLength: 16, in: ctx)
        case let .blur(r):
            ctx.setFillColor(UIColor(white: 0.5, alpha: 0.35).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.5).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r)
        }
    }

    private func drawArrow(from: CGPoint, to: CGPoint, headLength: CGFloat, in ctx: CGContext) {
        ctx.move(to: from)
        ctx.addLine(to: to)
        ctx.strokePath()
        let angle = atan2(to.y - from.y, to.x - from.x)
        let spread: CGFloat = .pi / 7
        let p1 = CGPoint(x: to.x - headLength * cos(angle - spread), y: to.y - headLength * sin(angle - spread))
        let p2 = CGPoint(x: to.x - headLength * cos(angle + spread), y: to.y - headLength * sin(angle + spread))
        ctx.move(to: to)
        ctx.addLine(to: p1)
        ctx.addLine(to: p2)
        ctx.closePath()
        ctx.fillPath()
    }

    // MARK: - Flatten onto the native-resolution image

    func flatten(onto image: UIImage) -> UIImage {
        guard displayedImageRect.width > 0, displayedImageRect.height > 0 else { return image }
        let scale = image.size.width / displayedImageRect.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { context in
            let ctx = context.cgContext
            image.draw(in: CGRect(origin: .zero, size: image.size))
            for case let .blur(r) in annotations {
                drawBlurRegion(r, scale: scale, source: image, in: ctx)
            }
            for annotation in annotations {
                drawFlattened(annotation, scale: scale, in: ctx)
            }
        }
    }

    private func mapPoint(_ p: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: (p.x - displayedImageRect.minX) * scale, y: (p.y - displayedImageRect.minY) * scale)
    }

    private func mapRect(_ r: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: (r.minX - displayedImageRect.minX) * scale,
            y: (r.minY - displayedImageRect.minY) * scale,
            width: r.width * scale,
            height: r.height * scale
        )
    }

    private func drawFlattened(_ annotation: Annotation, scale: CGFloat, in ctx: CGContext) {
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch annotation {
        case let .pen(points, color):
            guard points.count > 1 else { return }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(4 * scale)
            ctx.move(to: mapPoint(points[0], scale: scale))
            for p in points.dropFirst() { ctx.addLine(to: mapPoint(p, scale: scale)) }
            ctx.strokePath()
        case let .box(r, color):
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(3 * scale)
            ctx.addPath(UIBezierPath(roundedRect: mapRect(r, scale: scale), cornerRadius: 6 * scale).cgPath)
            ctx.strokePath()
        case let .arrow(from, to, color):
            ctx.setStrokeColor(color.cgColor)
            ctx.setFillColor(color.cgColor)
            ctx.setLineWidth(3 * scale)
            drawArrow(from: mapPoint(from, scale: scale), to: mapPoint(to, scale: scale),
                      headLength: 16 * scale, in: ctx)
        case .blur:
            break // applied first, above
        }
    }

    private func drawBlurRegion(_ r: CGRect, scale: CGFloat, source: UIImage, in ctx: CGContext) {
        let target = mapRect(r, scale: scale)
        guard target.width > 2, target.height > 2, let cg = source.cgImage else { return }
        let region = CGRect(
            x: target.minX * source.scale, y: target.minY * source.scale,
            width: target.width * source.scale, height: target.height * source.scale
        )
        guard let cropped = cg.cropping(to: region) else { return }
        let small = max(1, Int(target.width / 12))
        let downFormat = UIGraphicsImageRendererFormat()
        downFormat.scale = 1
        let down = UIGraphicsImageRenderer(
            size: CGSize(width: small, height: small), format: downFormat
        ).image { c in
            c.cgContext.interpolationQuality = .low
            UIImage(cgImage: cropped).draw(in: CGRect(x: 0, y: 0, width: small, height: small))
        }
        ctx.interpolationQuality = .none
        down.draw(in: target)
        ctx.interpolationQuality = .default
    }
}
#endif
