import AppKit

/// The attached displays, with names made unique so a calibration can tell twin monitors apart.
enum Displays {
    static func current() -> [(name: String, frame: CGRect)] {
        var seen: [String: Int] = [:]
        return NSScreen.screens.map { screen in
            let count = (seen[screen.localizedName] ?? 0) + 1
            seen[screen.localizedName] = count
            return (count == 1 ? screen.localizedName : "\(screen.localizedName) \(count)", screen.frame)
        }
    }
}

/// Walks a dot across every display and records the head pose at each stop.
final class CalibrationController {
    private struct Target {
        var display: Int
        var name: String
        /// Position on the display from 0 to 1, origin at the bottom left.
        var unit: CGPoint
    }

    private enum Phase {
        case intro
        case target(Int)
        case done(String)
    }

    private static let introSeconds = 3.0
    private static let settleSeconds = 0.9
    private static let sampleSeconds = 1.1
    private static let doneSeconds = 1.8
    private static let minimumSamples = 4
    private static let sampleFPS = 10.0
    private static let stops = [
        CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.06, y: 0.94), CGPoint(x: 0.94, y: 0.94),
        CGPoint(x: 0.94, y: 0.06), CGPoint(x: 0.06, y: 0.06),
    ]

    private let state: SceneState
    private let capture: CameraCapture
    private var windows: [NSWindow] = []
    private var views: [CalibrationView] = []
    private var targets: [Target] = []
    private var samples: [[PoseSample]] = []
    private var phase = Phase.intro
    private var phaseStart = Date()
    private var retried = false
    private var camera = ""
    private var timer: Timer?
    private var keyMonitor: Any?

    init(state: SceneState, capture: CameraCapture) {
        self.state = state
        self.capture = capture
    }

    /// Returns why calibration could not start, or nil when it started.
    func start() -> String? {
        guard timer == nil else { return "Calibration is already running." }
        guard let device = state.liveDevice else { return "The camera is not running." }
        camera = device
        let displays = Displays.current()
        targets = displays.enumerated().flatMap { index, display in
            Self.stops.map { Target(display: index, name: display.name, unit: $0) }
        }
        samples = Array(repeating: [], count: targets.count)
        phase = .intro
        phaseStart = Date()
        retried = false

        for display in displays {
            let window = CalibrationWindow(contentRect: display.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(display.frame, display: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = NSColor.black.withAlphaComponent(0.92)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            let view = CalibrationView(frame: NSRect(origin: .zero, size: display.frame.size))
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
            views.append(view)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.close()
            return nil
        }
        state.onPose = { [weak self] sample in
            DispatchQueue.main.async { self?.add(sample) }
        }
        capture.setAnalysisFPS(Self.sampleFPS)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.step() }
        return nil
    }

    private func add(_ sample: PoseSample) {
        guard case .target(let index) = phase else { return }
        let elapsed = Date().timeIntervalSince(phaseStart)
        if elapsed >= Self.settleSeconds, elapsed <= Self.settleSeconds + Self.sampleSeconds {
            samples[index].append(sample)
        }
    }

    private func step() {
        let elapsed = Date().timeIntervalSince(phaseStart)
        switch phase {
        case .intro:
            if elapsed >= Self.introSeconds { begin(.target(0)) }
        case .target(let index):
            guard elapsed >= Self.settleSeconds + Self.sampleSeconds else { break }
            if samples[index].count >= Self.minimumSamples {
                retried = false
                if index + 1 < targets.count { begin(.target(index + 1)) } else { complete() }
            } else if !retried {
                retried = true
                samples[index] = []
                phaseStart = Date()
            } else {
                begin(.done("Calibration stopped: no face was visible. Nothing was changed."))
            }
        case .done:
            if elapsed >= Self.doneSeconds { close() }
        }
        draw()
    }

    private func begin(_ next: Phase) {
        phase = next
        phaseStart = Date()
    }

    private func complete() {
        let profile = GazeProfile.build(
            camera: camera,
            targets: zip(targets, samples).map { (display: $0.name, samples: $1) })
        GazeStore.save(profile)
        state.setGazeProfile(profile)
        begin(.done("Calibrated \(profile.displays.count) display\(profile.displays.count == 1 ? "" : "s")."))
    }

    private func draw() {
        let elapsed = Date().timeIntervalSince(phaseStart)
        for (index, view) in views.enumerated() {
            var content = CalibrationView.Content()
            switch phase {
            case .intro where index == 0:
                content.lines = [
                    "Display calibration",
                    "Look at each dot as it appears, turning your head the way you normally would.",
                    "Starting in \(max(Int((Self.introSeconds - elapsed).rounded(.up)), 1)). Press Esc to cancel.",
                ]
            case .target(let target) where targets[target].display == index:
                content.dot = targets[target].unit
                content.progress = min(max((elapsed - Self.settleSeconds) / Self.sampleSeconds, 0), 1)
                content.lines = ["\(targets[target].name), \(target + 1) of \(targets.count)"]
                if retried { content.lines.append("Can't see your face. Check that you are in the camera's view.") }
            case .done(let message) where index == 0:
                content.lines = [message]
            default:
                break
            }
            view.content = content
        }
    }

    private func close() {
        timer?.invalidate()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        state.onPose = nil
        capture.setAnalysisFPS(nil)
        windows.forEach { $0.orderOut(nil) }
        windows = []
        views = []
    }
}

private final class CalibrationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class CalibrationView: NSView {
    struct Content {
        var lines: [String] = []
        /// Position from 0 to 1, origin at the bottom left.
        var dot: CGPoint?
        var progress = 0.0
    }

    var content = Content() {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        var y = bounds.height * 0.72
        for (index, line) in content.lines.enumerated() {
            let text = NSAttributedString(string: line, attributes: [
                .font: NSFont.systemFont(ofSize: index == 0 ? 26 : 17, weight: index == 0 ? .semibold : .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(index == 0 ? 1 : 0.75),
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: y - size.height))
            y -= size.height + 12
        }

        guard let dot = content.dot else { return }
        let center = NSPoint(x: bounds.width * dot.x, y: bounds.height * dot.y)
        let ring = NSBezierPath()
        ring.appendArc(withCenter: center, radius: 30, startAngle: 0, endAngle: 360)
        ring.lineWidth = 5
        NSColor.white.withAlphaComponent(0.25).setStroke()
        ring.stroke()
        if content.progress > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: 30, startAngle: 90, endAngle: 90 - 360 * content.progress, clockwise: true)
            arc.lineWidth = 5
            arc.lineCapStyle = .round
            NSColor.systemGreen.setStroke()
            arc.stroke()
        }
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)).fill()
    }
}
