import AVFoundation
import Foundation

/// Owns the capture session and feeds sampled frames to the analyzer. Frames are never stored.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Hand pose costs more than faces, so it is analyzed at most this often.
    private static let handInterval: TimeInterval = 0.5

    private let session = AVCaptureSession()
    private let control = DispatchQueue(label: "vision-mcp.camera.control")
    private let frames = DispatchQueue(label: "vision-mcp.camera.frames")
    private let analyzer = SceneAnalyzer()
    private let state: SceneState
    private var interval: TimeInterval
    private var lastAnalysis = Date.distantPast
    private var lastHands = Date.distantPast
    private var errorObserver: NSObjectProtocol?

    init(state: SceneState) {
        self.state = state
        self.interval = 1 / state.analysisFPS
        super.init()
        errorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [state] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            state.setCamera(.error, detail: error?.localizedDescription ?? "The camera stopped.")
        }
    }

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// Overrides how often frames are analyzed. Nil restores the configured rate.
    func setAnalysisFPS(_ fps: Double?) {
        frames.async { [self] in
            interval = 1 / (fps ?? state.analysisFPS)
        }
    }

    func start(preferred: String?) {
        control.async { [self] in
            if session.isRunning { session.stopRunning() }
            state.setCamera(.starting)

            let all = Self.devices()
            let named = preferred.flatMap { name in
                all.first { $0.localizedName.localizedCaseInsensitiveContains(name) }
            }
            guard let device = named ?? AVCaptureDevice.systemPreferredCamera
                ?? AVCaptureDevice.default(for: .video) ?? all.first
            else {
                state.setCamera(.noCamera)
                return
            }

            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frames)
            guard let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input), session.canAddOutput(output)
            else {
                session.commitConfiguration()
                state.setCamera(.error, device: device.localizedName, detail: "Could not open \(device.localizedName).")
                return
            }
            session.addInput(input)
            session.addOutput(output)
            session.sessionPreset = Self.preset(for: device, in: session)
            session.commitConfiguration()

            state.setCamera(.starting, device: device.localizedName)
            session.startRunning()
        }
    }

    /// A small preset in the camera's own shape, so a widescreen camera is not cropped or squeezed to 4:3.
    private static func preset(for device: AVCaptureDevice, in session: AVCaptureSession) -> AVCaptureSession.Preset {
        let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let widescreen = size.height > 0 && Double(size.width) / Double(size.height) > 1.5
        let wanted: [AVCaptureSession.Preset] = widescreen ? [.hd1280x720, .vga640x480] : [.vga640x480]
        return wanted.first { session.canSetSessionPreset($0) } ?? session.sessionPreset
    }

    /// A display-only layer showing the live session.
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        return layer
    }

    func stop(as status: CameraStatus, detail: String? = nil) {
        control.async { [self] in
            if session.isRunning { session.stopRunning() }
            state.setCamera(status, detail: detail)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) >= interval,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        lastAnalysis = now
        let withHands = now.timeIntervalSince(lastHands) >= Self.handInterval
        if withHands { lastHands = now }
        if let analysis = analyzer.analyze(buffer, at: now, withHands: withHands) {
            state.update(analysis)
        }
    }
}
