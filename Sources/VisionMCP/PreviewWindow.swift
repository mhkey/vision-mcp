import AVFoundation
import AppKit
import SwiftUI

/// A window showing the live camera with detections drawn on top and a readout beside it.
/// Display only: no frame is copied or saved.
final class PreviewWindowController: NSObject, NSWindowDelegate {
    private static let sidebarWidth: CGFloat = 300
    private static let frameRate = 30.0
    /// The sidebar refreshes on every sixth overlay tick.
    private static let sidebarEvery = 6

    private let state: SceneState
    private let capture: CameraCapture
    private let capturable: Bool
    private let onCalibrate: () -> Void
    private var window: NSWindow?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var timer: Timer?
    private var tick = 0

    init(state: SceneState, capture: CameraCapture, capturable: Bool, onCalibrate: @escaping () -> Void) {
        self.state = state
        self.capture = capture
        self.capturable = capturable
        self.onCalibrate = onCalibrate
    }

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let size = NSSize(width: 1240, height: 700)
        let videoFrame = NSRect(x: 0, y: 0, width: size.width - Self.sidebarWidth, height: size.height)

        let layer = capture.makePreviewLayer()
        layer.backgroundColor = NSColor.black.cgColor
        let video = NSView(frame: videoFrame)
        video.layer = layer
        video.wantsLayer = true
        video.autoresizingMask = [.width, .height]

        // The layer reports rectangles with the origin at the top left; the overlay view's origin is at the bottom left.
        let overlay = SceneOverlayView(frame: videoFrame) { [weak layer] box in
            guard let layer else { return .zero }
            let rect = layer.layerRectConverted(fromMetadataOutputRect: box)
            return CGRect(x: rect.minX, y: layer.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        overlay.autoresizingMask = [.width, .height]

        let model = PreviewModel(
            scene: state.overlay(), analysisFPS: state.analysisFPS, displays: Displays.current(), onCalibrate: onCalibrate)
        let sidebar = NSHostingView(rootView: PreviewSidebar(model: model))
        sidebar.sizingOptions = []
        sidebar.frame = NSRect(x: videoFrame.maxX, y: 0, width: Self.sidebarWidth, height: size.height)
        sidebar.autoresizingMask = [.minXMargin, .height]

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.addSubview(video)
        content.addSubview(overlay)
        content.addSubview(sidebar)

        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Vision MCP Preview"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = content
        window.contentMinSize = NSSize(width: 860, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Asks macOS to leave the camera image out of screenshots and screen sharing.
        if !capturable { window.sharingType = .none }
        window.center()

        self.window = window
        previewLayer = layer
        timer = Timer.scheduledTimer(withTimeInterval: 1 / Self.frameRate, repeats: true) { [weak self, weak overlay] _ in
            guard let self else { return }
            let scene = state.overlay()
            overlay?.show(scene)
            tick += 1
            if tick % Self.sidebarEvery == 0 {
                model.scene = scene
                model.displays = Displays.current()
                model.now = Date()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        previewLayer?.session = nil
        previewLayer = nil
        window = nil
    }
}

extension SceneOverlay.Face {
    var tint: NSColor {
        guard id != nil else { return .systemGray }
        if let lookingAt { return lookingAt == GazeProfile.away ? .systemOrange : .systemGreen }
        switch facingCamera {
        case true?: return .systemGreen
        case false?: return .systemOrange
        case nil: return .systemTeal
        }
    }

    /// "looking at <display>" with a calibration, the facing-camera estimate without one.
    var attentionText: String? {
        if let lookingAt { return lookingAt == GazeProfile.away ? "looking away" : "looking at \(lookingAt)" }
        switch facingCamera {
        case true?: return "facing camera"
        case false?: return "not facing camera"
        case nil: return nil
        }
    }
}

extension SceneOverlay {
    /// Shown over the video when the scene is unknown.
    var unknownReason: String? {
        guard !sceneKnown else { return nil }
        switch status {
        case .starting: return "Starting camera"
        case .running: return "Waiting for frames"
        case .paused: return "Camera paused"
        case .locked: return "Screen locked"
        case .permissionPending: return "Waiting for camera permission"
        case .permissionDenied: return "Camera access denied"
        case .noCamera: return "No camera found"
        case .error: return statusDetail ?? "Camera error"
        }
    }
}

/// Draws detections over the video. Face boxes ease toward each new detection so they move smoothly between analyses.
final class SceneOverlayView: NSView {
    private let convert: (CGRect) -> CGRect
    private var scene: SceneOverlay?
    private var displayed: [Int: CGRect] = [:]

    /// `convert` maps a normalized, top-left-origin box to this view's coordinates.
    init(frame: NSRect, convert: @escaping (CGRect) -> CGRect) {
        self.convert = convert
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ scene: SceneOverlay, easing: CGFloat = 0.3) {
        var next: [Int: CGRect] = [:]
        for face in scene.faces {
            guard let id = face.id else { continue }
            let target = face.detection.box
            next[id] = displayed[id].map { Self.blend($0, target, easing) } ?? target
        }
        displayed = next
        self.scene = scene
        needsDisplay = true
    }

    private static func blend(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let scene else { return }
        for body in scene.bodies { drawBody(convert(body)) }
        for hand in scene.hands { drawHand(hand) }
        for face in scene.faces { drawFace(face) }
        if let reason = scene.unknownReason {
            let text = Self.text(reason, size: 15, weight: .medium, color: .white)
            let size = text.size()
            drawPill(text, at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), fill: NSColor.black.withAlphaComponent(0.65), padding: 10)
        }
    }

    private func drawBody(_ rect: NSRect) {
        guard rect.width > 0 else { return }
        NSColor.white.withAlphaComponent(0.55).setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        path.lineWidth = 1.5
        path.setLineDash([7, 5], count: 2, phase: 0)
        path.stroke()
        let tag = Self.text("upper body", size: 10, weight: .medium, color: NSColor.white.withAlphaComponent(0.85))
        drawPill(tag, at: NSPoint(x: rect.minX + 8, y: rect.minY + 6), fill: NSColor.black.withAlphaComponent(0.5), padding: 4)
    }

    private func drawHand(_ hand: HandDetection) {
        func place(_ point: CGPoint) -> NSPoint {
            convert(CGRect(origin: point, size: .zero)).origin
        }
        NSColor.systemYellow.setStroke()
        NSColor.systemYellow.setFill()
        for finger in hand.fingers where !finger.isEmpty {
            let points = (hand.wrist.map { [$0] } ?? []) + finger
            let path = NSBezierPath()
            path.move(to: place(points[0]))
            for point in points.dropFirst() { path.line(to: place(point)) }
            path.lineWidth = 2
            path.lineJoinStyle = .round
            path.stroke()
            for point in finger {
                let center = place(point)
                NSBezierPath(ovalIn: NSRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)).fill()
            }
        }
    }

    private func drawFace(_ face: SceneOverlay.Face) {
        let rect = convert(face.id.flatMap { displayed[$0] } ?? face.detection.box)
        guard rect.width > 0 else { return }
        let tint = face.tint

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 4
        shadow.set()
        tint.setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        if face.id == nil {
            path.lineWidth = 1
            path.setLineDash([4, 4], count: 2, phase: 0)
        } else {
            path.lineWidth = 2.5
        }
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        guard let id = face.id else { return }
        let title = "face-\(id)" + (face.attentionText.map { "  \($0)" } ?? "")
        let chip = Self.text(title, size: 12, weight: .semibold, color: .black)
        var chipOrigin = NSPoint(x: rect.minX + 4, y: rect.maxY + 8)
        if chipOrigin.y + chip.size().height + 4 > bounds.maxY { chipOrigin.y = rect.maxY - chip.size().height - 10 }
        drawPill(chip, at: clamped(chipOrigin, chip.size()), fill: tint, padding: 5)

        let pose = [("yaw", face.detection.yaw), ("pitch", face.detection.pitch), ("roll", face.detection.roll)]
            .compactMap { name, radians in radians.map { "\(name) \(String(format: "%.0f", $0 * 180 / .pi))°" } }
        guard !pose.isEmpty else { return }
        let readout = Self.text(pose.joined(separator: "   "), size: 11, weight: .regular, color: .white, monospaced: true)
        var readoutOrigin = NSPoint(x: rect.minX + 4, y: rect.minY - readout.size().height - 9)
        if readoutOrigin.y < 4 { readoutOrigin.y = rect.minY + 8 }
        drawPill(readout, at: clamped(readoutOrigin, readout.size()), fill: NSColor.black.withAlphaComponent(0.6), padding: 5)
    }

    private func clamped(_ origin: NSPoint, _ size: NSSize) -> NSPoint {
        NSPoint(x: min(max(origin.x, 8), max(bounds.maxX - size.width - 8, 8)), y: origin.y)
    }

    private func drawPill(_ text: NSAttributedString, at origin: NSPoint, fill: NSColor, padding: CGFloat) {
        let size = text.size()
        let rect = NSRect(x: origin.x - padding, y: origin.y - padding / 2, width: size.width + padding * 2, height: size.height + padding)
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        text.draw(at: origin)
    }

    private static func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, monospaced: Bool = false) -> NSAttributedString {
        let font = monospaced
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }
}
