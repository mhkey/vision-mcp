import CoreGraphics
import Foundation

struct FaceDetection {
    /// Normalized to the frame, origin at the top left.
    var box: CGRect
    /// Radians.
    var yaw: Double?
    var pitch: Double?
    var roll: Double?
    /// Pupil position relative to the eye's center, in eye widths, averaged over both eyes.
    var eyeOffset: CGPoint?

    var pose: PoseSample? {
        guard let yaw, let pitch else { return nil }
        return PoseSample(yaw: yaw * 180 / .pi, pitch: pitch * 180 / .pi, eye: eyeOffset)
    }
}

struct HandDetection {
    /// "left" or "right" as Vision reports it.
    var side: String?
    var wrist: CGPoint?
    /// One array per finger, base to tip, confident joints only. Normalized, origin at the top left.
    var fingers: [[CGPoint]]
    var box: CGRect
}

struct FrameAnalysis {
    var time: Date
    var faces: [FaceDetection]
    /// Upper-body boxes, normalized like face boxes.
    var bodies: [CGRect]
    /// Nil on frames where hands were not analyzed.
    var hands: [HandDetection]?
    var frameSize: CGSize
    var analysisMs: Double

    var bodyCount: Int { bodies.count }
}

enum CameraStatus: String {
    case starting, running, paused, locked, error
    case permissionPending = "permission_pending"
    case permissionDenied = "permission_denied"
    case noCamera = "no_camera"
}

struct SceneEvent {
    var type: String
    var time: Date
    var detail: [String: Any]

    var summary: String {
        let id = detail["id"] as? String ?? "face"
        switch type {
        case "face_appeared":
            return "\(id) appeared"
        case "face_left":
            return "\(id) left after \(detail["visible_for_s"] ?? "?")s"
        case "people_count_changed":
            let to = detail["to"] as? Int ?? 0
            guard let from = detail["from"] as? Int else { return "People in view: \(to)" }
            return "People in view: \(from) → \(to)"
        case "looking_at_changed":
            let to = detail["to"] as? String ?? GazeProfile.away
            return to == GazeProfile.away ? "\(id) looked away" : "\(id) looking at \(to)"
        case "camera_status":
            return "Camera \((detail["status"] as? String ?? "").replacingOccurrences(of: "_", with: " "))"
        default:
            return type
        }
    }
}

/// What the preview window shows.
struct SceneOverlay {
    struct Face {
        /// Nil until the track is confirmed.
        var id: Int?
        var detection: FaceDetection
        var facingCamera: Bool?
        var firstSeen: Date
        var position: String
        var distance: String
        /// A display name or `GazeProfile.away`. Nil without a calibration.
        var lookingAt: String?
        var lookingSince: Date?
    }

    var status: CameraStatus
    var statusDetail: String?
    var device: String?
    /// False when the camera is not delivering fresh frames, so the scene is unknown.
    var sceneKnown: Bool
    var peopleCount: Int?
    var presenceChanged: Date?
    var faces: [Face]
    var bodies: [CGRect]
    var hands: [HandDetection]
    /// Display names of the active calibration, empty without one.
    var calibratedDisplays: [String]
    var analysisMs: Double?
    var frameSize: CGSize?
    /// Newest first.
    var events: [SceneEvent]

    /// The largest confirmed face: the person nearest the camera.
    var primaryFace: Face? {
        faces.filter { $0.id != nil }.max { $0.detection.box.height < $1.detection.box.height }
    }
}

/// The current scene and a short event history, held in memory only.
final class SceneState {
    private struct Track {
        /// Assigned once the face has been seen in `confirmHits` frames.
        var id: Int?
        var face: FaceDetection
        var firstSeen: Date
        var lastSeen: Date
        var hits: Int
        var lookingAt: String?
        var lookingSince: Date?
        var pendingLook: String?
        var pendingHits = 0
    }

    private static let confirmHits = 2
    /// Consecutive frames a new gaze target must hold before it replaces the current one.
    private static let lookHits = 2
    private static let trackExpiry: TimeInterval = 3
    private static let staleAfter: TimeInterval = 5
    private static let eventLimit = 200
    private static let bodyWindow = 5
    static let facingLimitDegrees = 20.0

    let analysisFPS: Double
    var onStatusChange: ((CameraStatus) -> Void)?
    /// Called on the camera queue with the nearest face's head pose, for calibration.
    var onPose: ((PoseSample) -> Void)?

    private let lock = NSLock()
    private var status: CameraStatus = .starting
    private var statusDetail: String?
    private var device: String?
    private var tracks: [Track] = []
    private var nextID = 1
    private var events: [SceneEvent] = []
    private var recentBodyCounts: [Int] = []
    private var peopleCount: Int?
    private var presenceChanged: Date?
    private var lastFrame: Date?
    private var lastAnalysisMs: Double?
    private var lastBodies: [CGRect] = []
    private var frameSize: CGSize?
    private var hands: [HandDetection] = []
    /// Keyed by camera name.
    private var gazeProfiles: [String: GazeProfile]

    init(analysisFPS: Double, gazeProfiles: [String: GazeProfile] = [:]) {
        self.analysisFPS = analysisFPS
        self.gazeProfiles = gazeProfiles
    }

    var currentDevice: String? {
        lock.lock()
        defer { lock.unlock() }
        return device
    }

    /// The running camera's name, or nil when no fresh frames are arriving.
    var liveDevice: String? {
        lock.lock()
        defer { lock.unlock() }
        return isKnown(at: Date()) ? device : nil
    }

    func setGazeProfile(_ profile: GazeProfile) {
        lock.lock()
        gazeProfiles[profile.camera] = profile
        for index in tracks.indices {
            tracks[index].lookingAt = nil
            tracks[index].lookingSince = nil
            tracks[index].pendingLook = nil
            tracks[index].pendingHits = 0
        }
        lock.unlock()
    }

    func setCamera(_ newStatus: CameraStatus, device newDevice: String? = nil, detail: String? = nil) {
        lock.lock()
        let changed = newStatus != status
        status = newStatus
        statusDetail = detail
        device = newDevice
        tracks = []
        hands = []
        recentBodyCounts = []
        peopleCount = nil
        presenceChanged = nil
        lastFrame = nil
        lastBodies = []
        if changed {
            record("camera_status", at: Date(), ["status": newStatus.rawValue])
        }
        lock.unlock()
        if changed { onStatusChange?(newStatus) }
    }

    func update(_ analysis: FrameAnalysis) {
        lock.lock()
        guard status == .starting || status == .running else {
            lock.unlock()
            return
        }
        let becameRunning = status == .starting
        if becameRunning {
            status = .running
            record("camera_status", at: analysis.time, ["status": CameraStatus.running.rawValue])
        }
        lastFrame = analysis.time
        lastAnalysisMs = analysis.analysisMs
        lastBodies = analysis.bodies
        frameSize = analysis.frameSize
        matchFaces(analysis)
        updatePeopleCount(analysis)
        if let detected = analysis.hands { hands = detected }
        lock.unlock()

        if becameRunning { onStatusChange?(.running) }
        if let onPose, let pose = analysis.faces.max(by: { $0.box.height < $1.box.height })?.pose {
            onPose(pose)
        }
    }

    private func matchFaces(_ analysis: FrameAnalysis) {
        var pairs: [(track: Int, face: Int, score: Double)] = []
        for (t, track) in tracks.enumerated() {
            for (f, face) in analysis.faces.enumerated() {
                let score = Self.similarity(track.face.box, face.box)
                if score > 0 { pairs.append((t, f, score)) }
            }
        }
        pairs.sort { $0.score > $1.score }

        var usedTracks = Set<Int>()
        var usedFaces = Set<Int>()
        for pair in pairs where !usedTracks.contains(pair.track) && !usedFaces.contains(pair.face) {
            usedTracks.insert(pair.track)
            usedFaces.insert(pair.face)
            tracks[pair.track].face = analysis.faces[pair.face]
            tracks[pair.track].lastSeen = analysis.time
            tracks[pair.track].hits += 1
            if tracks[pair.track].id == nil, tracks[pair.track].hits >= Self.confirmHits {
                tracks[pair.track].id = nextID
                record("face_appeared", at: analysis.time, ["id": "face-\(nextID)"])
                nextID += 1
            }
            updateLook(pair.track, at: analysis.time)
        }
        for (f, face) in analysis.faces.enumerated() where !usedFaces.contains(f) {
            tracks.append(Track(id: nil, face: face, firstSeen: analysis.time, lastSeen: analysis.time, hits: 1))
        }
        tracks.removeAll { track in
            guard analysis.time.timeIntervalSince(track.lastSeen) > Self.trackExpiry else { return false }
            if let id = track.id {
                record("face_left", at: analysis.time, [
                    "id": "face-\(id)",
                    "visible_for_s": Self.round1(track.lastSeen.timeIntervalSince(track.firstSeen)),
                ])
            }
            return true
        }
    }

    private func updateLook(_ index: Int, at time: Date) {
        guard let id = tracks[index].id,
              let profile = device.flatMap({ gazeProfiles[$0] }),
              let pose = tracks[index].face.pose
        else { return }
        let target = profile.classify(pose)
        if target == tracks[index].lookingAt {
            tracks[index].pendingLook = nil
            tracks[index].pendingHits = 0
            return
        }
        if target == tracks[index].pendingLook {
            tracks[index].pendingHits += 1
        } else {
            tracks[index].pendingLook = target
            tracks[index].pendingHits = 1
        }
        let previous = tracks[index].lookingAt
        guard previous == nil || tracks[index].pendingHits >= Self.lookHits else { return }
        tracks[index].lookingAt = target
        tracks[index].lookingSince = time
        tracks[index].pendingLook = nil
        tracks[index].pendingHits = 0
        if let previous {
            record("looking_at_changed", at: time, ["id": "face-\(id)", "from": previous, "to": target])
        }
    }

    private func updatePeopleCount(_ analysis: FrameAnalysis) {
        recentBodyCounts.append(analysis.bodyCount)
        if recentBodyCounts.count > Self.bodyWindow { recentBodyCounts.removeFirst() }
        let count = max(tracks.filter { $0.id != nil }.count, medianBodyCount)
        guard count != peopleCount else { return }
        if (peopleCount ?? 0 == 0) != (count == 0) || presenceChanged == nil {
            presenceChanged = analysis.time
        }
        record("people_count_changed", at: analysis.time, ["from": peopleCount ?? NSNull(), "to": count])
        peopleCount = count
    }

    private var medianBodyCount: Int {
        guard !recentBodyCounts.isEmpty else { return 0 }
        return recentBodyCounts.sorted()[recentBodyCounts.count / 2]
    }

    private func record(_ type: String, at time: Date, _ detail: [String: Any]) {
        events.append(SceneEvent(type: type, time: time, detail: detail))
        if events.count > Self.eventLimit { events.removeFirst(events.count - Self.eventLimit) }
    }

    /// Overlap of two boxes, or a small score for boxes whose centers are close.
    private static func similarity(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        if !intersection.isNull {
            let overlap = intersection.width * intersection.height
            let union = a.width * a.height + b.width * b.height - overlap
            if union > 0, overlap / union > 0.1 { return overlap / union }
        }
        let distance = hypot(a.midX - b.midX, a.midY - b.midY)
        return distance < 0.15 ? 0.1 * (1 - distance / 0.15) : 0
    }

    private func isKnown(at now: Date) -> Bool {
        guard status == .running, let lastFrame else { return false }
        return now.timeIntervalSince(lastFrame) <= Self.staleAfter
    }

    private var primaryTrack: Track? {
        tracks.filter { $0.id != nil }.max { $0.face.box.height < $1.face.box.height }
    }

    // MARK: - Output

    func snapshot(includeEvents: Bool) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let known = isKnown(at: now)
        let profile = device.flatMap { gazeProfiles[$0] }

        var camera: [String: Any] = [
            "status": status.rawValue,
            "device": device ?? NSNull(),
            "analysis_fps": analysisFPS,
        ]
        if let statusDetail { camera["detail"] = statusDetail }
        if let lastFrame { camera["last_frame_age_s"] = Self.round1(now.timeIntervalSince(lastFrame)) }
        if let lastAnalysisMs { camera["last_analysis_ms"] = Self.round1(lastAnalysisMs) }
        if let frameSize, status == .running {
            camera["frame_size"] = "\(Int(frameSize.width))x\(Int(frameSize.height))"
        }

        var result: [String: Any] = [
            "camera": camera,
            "scene_known": known,
            "people_count": NSNull(),
            "faces": [Any](),
        ]
        if known {
            let count = peopleCount ?? 0
            result["people_count"] = count
            result["bodies_detected"] = medianBodyCount
            result["faces"] = tracks.filter { $0.id != nil }.map { Self.describe($0, now: now) }
            var presence: [String: Any] = ["present": count > 0]
            if let presenceChanged { presence["for_s"] = Self.round1(now.timeIntervalSince(presenceChanged)) }
            result["presence"] = presence

            var attention: [String: Any] = ["calibrated": profile != nil]
            if let profile {
                attention["displays"] = profile.displays.map(\.name)
                if let primary = primaryTrack, let id = primary.id {
                    attention["face"] = "face-\(id)"
                    attention["looking_at"] = primary.lookingAt ?? NSNull()
                    if let since = primary.lookingSince { attention["for_s"] = Self.round1(now.timeIntervalSince(since)) }
                }
            }
            result["attention"] = attention

            result["hands"] = hands.map { hand -> [String: Any] in
                [
                    "side": hand.side ?? NSNull(),
                    "frame_position": Self.position(hand.box),
                    "box": Self.box(hand.box),
                ]
            }
        }
        if includeEvents {
            let formatter = ISO8601DateFormatter()
            result["events"] = events.reversed().map { event -> [String: Any] in
                var entry = event.detail
                entry["type"] = event.type
                entry["at"] = formatter.string(from: event.time)
                entry["seconds_ago"] = Self.round1(now.timeIntervalSince(event.time))
                return entry
            }
        }
        return result
    }

    func overlay(eventLimit: Int = 8) -> SceneOverlay {
        lock.lock()
        defer { lock.unlock() }
        let known = isKnown(at: Date())
        return SceneOverlay(
            status: status,
            statusDetail: statusDetail,
            device: device,
            sceneKnown: known,
            peopleCount: known ? peopleCount : nil,
            presenceChanged: known ? presenceChanged : nil,
            faces: known ? tracks.map {
                SceneOverlay.Face(
                    id: $0.id, detection: $0.face, facingCamera: Self.facingCamera($0.face), firstSeen: $0.firstSeen,
                    position: Self.position($0.face.box), distance: Self.distance($0.face),
                    lookingAt: $0.lookingAt, lookingSince: $0.lookingSince)
            } : [],
            bodies: known ? lastBodies : [],
            hands: known ? hands : [],
            calibratedDisplays: device.flatMap { gazeProfiles[$0] }?.displays.map(\.name) ?? [],
            analysisMs: lastAnalysisMs,
            frameSize: frameSize,
            events: Array(events.suffix(eventLimit).reversed()))
    }

    func menuSummary() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var lines = ["Camera: \(status.rawValue.replacingOccurrences(of: "_", with: " "))" + (device.map { " (\($0))" } ?? "")]
        if status == .running, let peopleCount {
            lines.append("People in view: \(peopleCount)")
        }
        if status == .running, let looking = primaryTrack?.lookingAt {
            lines.append(looking == GazeProfile.away ? "Looking away" : "Looking at: \(looking)")
        }
        if let statusDetail { lines.append(statusDetail) }
        return lines
    }

    private static func describe(_ track: Track, now: Date) -> [String: Any] {
        let face = track.face
        var entry: [String: Any] = [
            "id": "face-\(track.id ?? 0)",
            "visible_for_s": round1(now.timeIntervalSince(track.firstSeen)),
            "frame_position": position(face.box),
            "distance_hint": distance(face),
            "box": box(face.box),
        ]
        var pose: [String: Any] = [:]
        if let yaw = face.yaw { pose["yaw"] = round1(yaw * 180 / .pi) }
        if let pitch = face.pitch { pose["pitch"] = round1(pitch * 180 / .pi) }
        if let roll = face.roll { pose["roll"] = round1(roll * 180 / .pi) }
        if !pose.isEmpty { entry["head_pose_deg"] = pose }
        entry["facing_camera"] = facingCamera(face) ?? NSNull()
        if let lookingAt = track.lookingAt { entry["looking_at"] = lookingAt }
        return entry
    }

    private static func box(_ rect: CGRect) -> [String: Any] {
        ["x": round3(rect.minX), "y": round3(rect.minY), "w": round3(rect.width), "h": round3(rect.height)]
    }

    private static func position(_ box: CGRect) -> String {
        box.midX < 1.0 / 3 ? "left" : (box.midX > 2.0 / 3 ? "right" : "center")
    }

    private static func distance(_ face: FaceDetection) -> String {
        face.box.height >= 0.4 ? "near" : (face.box.height >= 0.18 ? "mid" : "far")
    }

    /// Nil when Vision reported no yaw.
    private static func facingCamera(_ face: FaceDetection) -> Bool? {
        guard let yaw = face.yaw else { return nil }
        let limit = facingLimitDegrees * .pi / 180
        return abs(yaw) <= limit && abs(face.pitch ?? 0) <= limit
    }

    /// Decimal numbers, so JSON shows 1.9 and not the nearest binary double.
    private static func round1(_ value: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.1f", value)) }
    private static func round3(_ value: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.3f", value)) }
}
