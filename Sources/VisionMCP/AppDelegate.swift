import AVFoundation
import AppKit

struct Options {
    var port: UInt16 = 7723
    var fps: Double = 4
    var camera: String?
    var paused = false
    var preview = false
    var capturable = false
    var calibrate = false
    var stdio = false

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        if let port = ProcessInfo.processInfo.environment["VISION_MCP_PORT"].flatMap(UInt16.init) {
            options.port = port
        }
        var index = 1
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--port": if let port = value().flatMap(UInt16.init) { options.port = port }
            case "--fps": if let fps = value().flatMap(Double.init) { options.fps = min(max(fps, 0.2), 10) }
            case "--camera": options.camera = value()
            case "--paused": options.paused = true
            case "--preview": options.preview = true
            case "--capturable": options.capturable = true
            case "--calibrate": options.calibrate = true
            case "--stdio": options.stdio = true
            default: break
            }
            index += 1
        }
        return options
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let cameraDefaultsKey = "camera"

    private let options: Options
    private let state: SceneState
    private let capture: CameraCapture
    private var server: HTTPServer?
    private var preview: PreviewWindowController?
    private let calibration: CalibrationController
    private var calibrateWhenRunning: Bool
    private var statusItem: NSStatusItem?
    private var cameraChoice: String?
    private var userPaused: Bool
    private var locked = false

    init(options: Options) {
        self.options = options
        state = SceneState(analysisFPS: options.fps, gazeProfiles: GazeStore.load())
        capture = CameraCapture(state: state)
        calibration = CalibrationController(state: state, capture: capture)
        calibrateWhenRunning = options.calibrate
        cameraChoice = options.camera ?? UserDefaults.standard.string(forKey: Self.cameraDefaultsKey)
        userPaused = options.paused
    }

    private var endpoint: String { "http://127.0.0.1:\(options.port)/mcp" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateIcon(.starting)
        state.onStatusChange = { [weak self] status in
            DispatchQueue.main.async {
                self?.updateIcon(status)
                self?.calibrateIfRequested(status)
            }
        }

        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true
            self?.refreshCamera()
        }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = false
            self?.refreshCamera()
        }

        startServer()
        if options.preview { showPreview() }
    }

    private func startServer() {
        let router = MCPRouter(state: state) { [weak self] in
            DispatchQueue.main.sync {
                guard let self else { return "Vision MCP is shutting down." }
                return self.calibration.start()
            }
        }
        do {
            let server = try HTTPServer(port: options.port) { router.handle($0) }
            self.server = server
            server.start(
                onReady: { [weak self] in
                    DispatchQueue.main.async { self?.refreshCamera() }
                },
                onFailure: { error in
                    NSLog("Vision MCP could not listen on port \(self.options.port): \(error)")
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                })
        } catch {
            NSLog("Vision MCP could not start its server: \(error)")
            NSApp.terminate(nil)
        }
    }

    private func refreshCamera() {
        if userPaused {
            capture.stop(as: .paused)
            return
        }
        if locked {
            capture.stop(as: .locked)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            capture.start(preferred: cameraChoice)
        case .notDetermined:
            state.setCamera(.permissionPending)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshCamera() }
            }
        default:
            capture.stop(
                as: .permissionDenied,
                detail: "Allow Vision MCP in System Settings > Privacy & Security > Camera.")
        }
    }

    private func updateIcon(_ status: CameraStatus) {
        let watching = status == .running || status == .starting
        let image = NSImage(systemSymbolName: watching ? "eye" : "eye.slash", accessibilityDescription: "Vision MCP")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for line in state.menuSummary() + ["MCP: \(endpoint)"] {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Show Preview", #selector(showPreview)))
        menu.addItem(actionItem("Calibrate Displays…", #selector(calibrateDisplays)))
        menu.addItem(actionItem(userPaused ? "Resume Camera" : "Pause Camera", #selector(togglePause)))

        let cameras = NSMenu()
        let systemDefault = actionItem("System Default", #selector(selectCamera(_:)))
        systemDefault.state = cameraChoice == nil ? .on : .off
        cameras.addItem(systemDefault)
        cameras.addItem(.separator())
        for device in CameraCapture.devices() {
            let item = actionItem(device.localizedName, #selector(selectCamera(_:)))
            item.representedObject = device.localizedName
            item.state = cameraChoice == device.localizedName ? .on : .off
            cameras.addItem(item)
        }
        let cameraItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        cameraItem.submenu = cameras
        menu.addItem(cameraItem)

        menu.addItem(actionItem("Copy MCP URL", #selector(copyEndpoint)))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit Vision MCP", #selector(quit)))
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showPreview() {
        if preview == nil {
            preview = PreviewWindowController(state: state, capture: capture, capturable: options.capturable) { [weak self] in
                self?.calibrateDisplays()
            }
        }
        preview?.show()
    }

    @objc private func calibrateDisplays() {
        guard let problem = calibration.start() else { return }
        let alert = NSAlert()
        alert.messageText = "Calibration could not start"
        alert.informativeText = problem
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Runs the calibration asked for at launch once the camera has had a moment to find a face.
    private func calibrateIfRequested(_ status: CameraStatus) {
        guard calibrateWhenRunning, status == .running else { return }
        calibrateWhenRunning = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.calibrateDisplays() }
    }

    @objc private func togglePause() {
        userPaused.toggle()
        refreshCamera()
    }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        cameraChoice = sender.representedObject as? String
        UserDefaults.standard.set(cameraChoice, forKey: Self.cameraDefaultsKey)
        refreshCamera()
    }

    @objc private func copyEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpoint, forType: .string)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
