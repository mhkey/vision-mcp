import CoreVideo
import Foundation
import Vision

/// Runs the Vision requests on one frame. Used from the camera's frame queue only.
final class SceneAnalyzer {
    private static let minimumConfidence: Float = 0.5
    private static let jointConfidence: Float = 0.3
    private static let fingers: [[VNHumanHandPoseObservation.JointName]] = [
        [.thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.littleMCP, .littlePIP, .littleDIP, .littleTip],
    ]

    /// Nil when Vision could not analyze the frame. Hands are analyzed only when `withHands`.
    func analyze(_ buffer: CVPixelBuffer, at time: Date, withHands: Bool) -> FrameAnalysis? {
        let started = CFAbsoluteTimeGetCurrent()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let bodyRequest = VNDetectHumanRectanglesRequest()
        bodyRequest.upperBodyOnly = true
        var requests: [VNRequest] = [faceRequest, bodyRequest]

        let handRequest = VNDetectHumanHandPoseRequest()
        handRequest.maximumHandCount = 4
        if withHands { requests.append(handRequest) }

        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do {
            try handler.perform(requests)
        } catch {
            return nil
        }

        let faceResults = (faceRequest.results ?? []).filter { $0.confidence >= Self.minimumConfidence }
        let eyes = eyeOffsets(for: faceResults, handler: handler)
        let faces = faceResults.enumerated().map { index, face in
            FaceDetection(
                box: Self.topLeft(face.boundingBox),
                yaw: face.yaw?.doubleValue,
                pitch: face.pitch?.doubleValue,
                roll: face.roll?.doubleValue,
                eyeOffset: eyes[index])
        }
        let bodies = (bodyRequest.results ?? [])
            .filter { $0.confidence >= Self.minimumConfidence }
            .map { Self.topLeft($0.boundingBox) }

        return FrameAnalysis(
            time: time,
            faces: faces,
            bodies: bodies,
            hands: withHands ? (handRequest.results ?? []).compactMap(Self.hand) : nil,
            frameSize: CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)),
            analysisMs: (CFAbsoluteTimeGetCurrent() - started) * 1000)
    }

    /// Eye offsets by index into `faces`, for the faces whose landmarks were found.
    private func eyeOffsets(for faces: [VNFaceObservation], handler: VNImageRequestHandler) -> [Int: CGPoint] {
        guard !faces.isEmpty else { return [:] }
        let request = VNDetectFaceLandmarksRequest()
        request.inputFaceObservations = faces
        guard (try? handler.perform([request])) != nil else { return [:] }
        var offsets: [Int: CGPoint] = [:]
        for result in request.results ?? [] {
            guard let landmarks = result.landmarks,
                  let index = faces.firstIndex(where: {
                      abs($0.boundingBox.midX - result.boundingBox.midX) < 0.01 && abs($0.boundingBox.midY - result.boundingBox.midY) < 0.01
                  })
            else { continue }
            let both = [
                Self.eyeOffset(eye: landmarks.leftEye, pupil: landmarks.leftPupil),
                Self.eyeOffset(eye: landmarks.rightEye, pupil: landmarks.rightPupil),
            ].compactMap { $0 }
            guard !both.isEmpty else { continue }
            offsets[index] = CGPoint(
                x: both.map(\.x).reduce(0, +) / CGFloat(both.count),
                y: both.map(\.y).reduce(0, +) / CGFloat(both.count))
        }
        return offsets
    }

    private static func eyeOffset(eye: VNFaceLandmarkRegion2D?, pupil: VNFaceLandmarkRegion2D?) -> CGPoint? {
        guard let points = eye?.normalizedPoints, points.count >= 4,
              let pupil = pupil?.normalizedPoints.first,
              let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(), maxX - minX > 0.005
        else { return nil }
        let centerX = points.map(\.x).reduce(0, +) / CGFloat(points.count)
        let centerY = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        return CGPoint(x: (pupil.x - centerX) / (maxX - minX), y: (pupil.y - centerY) / (maxX - minX))
    }

    private static func hand(_ observation: VNHumanHandPoseObservation) -> HandDetection? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        func location(_ joint: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let point = points[joint], point.confidence >= jointConfidence else { return nil }
            return CGPoint(x: point.location.x, y: 1 - point.location.y)
        }
        let wrist = location(.wrist)
        let fingers = Self.fingers.map { $0.compactMap(location) }
        let all = fingers.flatMap { $0 } + (wrist.map { [$0] } ?? [])
        guard all.count >= 6,
              let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
              let minY = all.map(\.y).min(), let maxY = all.map(\.y).max()
        else { return nil }
        let side: String?
        switch observation.chirality {
        case .left: side = "left"
        case .right: side = "right"
        default: side = nil
        }
        return HandDetection(
            side: side, wrist: wrist, fingers: fingers,
            box: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -0.01, dy: -0.01))
    }

    /// Vision boxes have their origin at the bottom left.
    private static func topLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }
}
