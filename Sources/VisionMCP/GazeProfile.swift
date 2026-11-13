import CoreGraphics
import Foundation

/// A head pose in degrees, with the eye offset when landmarks were found.
struct PoseSample {
    var yaw: Double
    var pitch: Double
    var eye: CGPoint?
}

/// Where the head points when looking at each display, measured for one camera position.
/// Holds head-pose statistics only: no image and nothing that identifies a person.
struct GazeProfile: Codable {
    struct Display: Codable {
        var name: String
        /// The spread of the calibration targets' mean poses, in degrees.
        var yawMin: Double
        var yawMax: Double
        var pitchMin: Double
        var pitchMax: Double
        var yawMean: Double
        var yawStd: Double
        var pitchMean: Double
        var pitchStd: Double
        var eyeXMean: Double?
        var eyeXStd: Double?
        var eyeYMean: Double?
        var eyeYStd: Double?

        /// The pose falls inside the calibrated range, widened by a quarter of the range or 4 degrees.
        func contains(_ sample: PoseSample) -> Bool {
            let yawMargin = max((yawMax - yawMin) * 0.25, 4)
            let pitchMargin = max((pitchMax - pitchMin) * 0.25, 4)
            return sample.yaw >= yawMin - yawMargin && sample.yaw <= yawMax + yawMargin
                && sample.pitch >= pitchMin - pitchMargin && sample.pitch <= pitchMax + pitchMargin
        }

        /// Distance from this display's typical pose, in standard deviations, including the eyes when both sides have them.
        func distance(_ sample: PoseSample) -> Double {
            var terms = [
                (sample.yaw - yawMean) / max(yawStd, 2),
                (sample.pitch - pitchMean) / max(pitchStd, 2),
            ]
            if let eye = sample.eye, let eyeXMean, let eyeXStd, let eyeYMean, let eyeYStd {
                terms.append((eye.x - eyeXMean) / max(eyeXStd, 0.03))
                terms.append((eye.y - eyeYMean) / max(eyeYStd, 0.03))
            }
            return (terms.map { $0 * $0 }.reduce(0, +) / Double(terms.count)).squareRoot()
        }
    }

    static let away = "away"

    var camera: String
    var created: Date
    var displays: [Display]

    /// The display being looked at, or `away`. Overlapping displays are settled by the closest typical pose.
    func classify(_ sample: PoseSample) -> String {
        let candidates = displays.filter { $0.contains(sample) }
        return candidates.min { $0.distance(sample) < $1.distance(sample) }?.name ?? Self.away
    }

    /// `targets` holds the samples taken while looking at one point on one display.
    static func build(camera: String, targets: [(display: String, samples: [PoseSample])]) -> GazeProfile {
        var order: [String] = []
        for target in targets where !order.contains(target.display) { order.append(target.display) }
        let displays = order.map { name -> Display in
            let own = targets.filter { $0.display == name && !$0.samples.isEmpty }
            let targetYaw = own.map { mean($0.samples.map(\.yaw)) }
            let targetPitch = own.map { mean($0.samples.map(\.pitch)) }
            let all = own.flatMap(\.samples)
            let eyes = all.compactMap(\.eye)
            let hasEyes = eyes.count >= all.count / 2 && !eyes.isEmpty
            return Display(
                name: name,
                yawMin: targetYaw.min() ?? 0, yawMax: targetYaw.max() ?? 0,
                pitchMin: targetPitch.min() ?? 0, pitchMax: targetPitch.max() ?? 0,
                yawMean: mean(all.map(\.yaw)), yawStd: std(all.map(\.yaw)),
                pitchMean: mean(all.map(\.pitch)), pitchStd: std(all.map(\.pitch)),
                eyeXMean: hasEyes ? mean(eyes.map { Double($0.x) }) : nil,
                eyeXStd: hasEyes ? std(eyes.map { Double($0.x) }) : nil,
                eyeYMean: hasEyes ? mean(eyes.map { Double($0.y) }) : nil,
                eyeYStd: hasEyes ? std(eyes.map { Double($0.y) }) : nil)
        }
        return GazeProfile(camera: camera, created: Date(), displays: displays)
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private static func std(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let center = mean(values)
        return (values.map { ($0 - center) * ($0 - center) }.reduce(0, +) / Double(values.count - 1)).squareRoot()
    }
}

/// Calibrations on disk, one per camera, in Application Support.
enum GazeStore {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VisionMCP", isDirectory: true)
            .appendingPathComponent("gaze-calibration.json")
    }

    static func load() -> [String: GazeProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let profiles = try? decoder.decode([String: GazeProfile].self, from: data)
        else { return [:] }
        return profiles
    }

    static func save(_ profile: GazeProfile) {
        var profiles = load()
        profiles[profile.camera] = profile
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(profiles) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
