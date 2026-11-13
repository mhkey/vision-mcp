import SwiftUI

final class PreviewModel: ObservableObject {
    @Published var scene: SceneOverlay
    @Published var displays: [(name: String, frame: CGRect)]
    @Published var now: Date
    let analysisFPS: Double
    let onCalibrate: () -> Void

    init(
        scene: SceneOverlay, analysisFPS: Double, displays: [(name: String, frame: CGRect)],
        now: Date = Date(), onCalibrate: @escaping () -> Void
    ) {
        self.scene = scene
        self.analysisFPS = analysisFPS
        self.displays = displays
        self.now = now
        self.onCalibrate = onCalibrate
    }
}

/// The readout beside the video: everything the scene state holds, as text and gauges.
struct PreviewSidebar: View {
    private static let shownFaces = 2

    @ObservedObject var model: PreviewModel

    private var scene: SceneOverlay { model.scene }
    private var confirmed: [SceneOverlay.Face] { scene.faces.filter { $0.id != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    section("Attention") { attention }
                    section("Faces") { faces }
                    section("Camera") { camera }
                    section("Recent events") { events }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Label("Display only. Nothing is saved or sent.", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.11))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(scene.peopleCount.map(String.init) ?? "?")
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(scene.peopleCount == 1 ? "person in view" : "people in view")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Text(presenceLine)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var presenceLine: String {
        if let reason = scene.unknownReason { return "Scene unknown: \(reason.lowercased())" }
        guard let since = scene.presenceChanged else { return " " }
        let duration = Self.duration(model.now.timeIntervalSince(since))
        return (scene.peopleCount ?? 0) > 0 ? "Someone present for \(duration)" : "Nobody in view for \(duration)"
    }

    @ViewBuilder private var attention: some View {
        let calibrated = !scene.calibratedDisplays.isEmpty
        let looking = scene.primaryFace?.lookingAt
        if calibrated {
            HStack(alignment: .firstTextBaseline) {
                Text(lookingTitle(looking))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(looking == nil ? Color.secondary : (looking == GazeProfile.away ? Color.orange : Color.green))
                    .lineLimit(1)
                Spacer()
                if let since = scene.primaryFace?.lookingSince {
                    Text(Self.duration(model.now.timeIntervalSince(since)))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Not calibrated for this camera. Calibrate to see which display is being looked at.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        DisplayMap(displays: model.displays, calibrated: scene.calibratedDisplays, active: looking)
            .frame(height: 74)
        Button(calibrated ? "Recalibrate displays" : "Calibrate displays", action: model.onCalibrate)
            .controlSize(.small)
            .disabled(!scene.sceneKnown)
    }

    private func lookingTitle(_ looking: String?) -> String {
        guard let looking else { return "No face to follow" }
        return looking == GazeProfile.away ? "Looking away" : looking
    }

    private var camera: some View {
        VStack(spacing: 6) {
            row("Device", scene.device ?? "None")
            HStack {
                Text("Status").foregroundStyle(.secondary)
                Spacer()
                Circle().fill(scene.sceneKnown ? Color.green : Color.gray).frame(width: 7, height: 7)
                Text(scene.status.rawValue.replacingOccurrences(of: "_", with: " "))
            }
            if let size = scene.frameSize, scene.sceneKnown {
                row("Frame", "\(Int(size.width)) x \(Int(size.height))")
            }
            if let ms = scene.analysisMs, scene.sceneKnown {
                row("Analysis", "\(String(format: "%.0f", ms)) ms, \(String(format: "%g", model.analysisFPS)) per second")
            }
            row("Upper bodies", scene.sceneKnown ? String(scene.bodies.count) : "unknown")
            row("Hands", scene.sceneKnown ? String(scene.hands.count) : "unknown")
        }
        .font(.callout)
    }

    @ViewBuilder private var faces: some View {
        if confirmed.isEmpty {
            Text(scene.sceneKnown ? "No faces in view" : "Unknown")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(confirmed.prefix(Self.shownFaces).enumerated()), id: \.offset) { _, face in
                faceCard(face)
            }
            if confirmed.count > Self.shownFaces {
                Text("and \(confirmed.count - Self.shownFaces) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        let unconfirmed = scene.faces.count - confirmed.count
        if unconfirmed > 0 {
            Text("\(unconfirmed) unconfirmed detection\(unconfirmed == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func faceCard(_ face: SceneOverlay.Face) -> some View {
        let tint = Color(nsColor: face.tint)
        let attention = face.attentionText.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Head pose unknown"
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(tint).frame(width: 9, height: 9)
                Text("face-\(face.id ?? 0)").fontWeight(.semibold)
                Spacer()
                Text(Self.duration(model.now.timeIntervalSince(face.firstSeen)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            Text("\(attention) · \(face.position) · \(face.distance) distance")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            PoseGauge(label: "yaw", radians: face.detection.yaw, range: 60, zone: SceneState.facingLimitDegrees)
            PoseGauge(label: "pitch", radians: face.detection.pitch, range: 60, zone: SceneState.facingLimitDegrees)
            PoseGauge(label: "roll", radians: face.detection.roll, range: 60, zone: nil)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.5), lineWidth: 1))
    }

    @ViewBuilder private var events: some View {
        if scene.events.isEmpty {
            Text("None yet").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(scene.events.prefix(6).enumerated()), id: \.offset) { _, event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.ago(model.now.timeIntervalSince(event.time)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                        Text(event.summary).lineLimit(1)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .kerning(0.8)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().lineLimit(1)
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(String(format: "%02d", total % 60))s" }
        return "\(total / 3600)h \(String(format: "%02d", total % 3600 / 60))m"
    }

    private static func ago(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        return "\(total / 3600)h"
    }
}

/// The displays in their macOS arrangement, with the one being looked at filled in.
private struct DisplayMap: View {
    let displays: [(name: String, frame: CGRect)]
    let calibrated: [String]
    let active: String?

    var body: some View {
        GeometryReader { geometry in
            let union = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            if !union.isNull, union.width > 0, union.height > 0 {
                let scale = min(geometry.size.width / union.width, geometry.size.height / union.height)
                let offsetX = (geometry.size.width - union.width * scale) / 2
                ForEach(Array(displays.enumerated()), id: \.offset) { _, display in
                    let isActive = display.name == active
                    let known = calibrated.contains(display.name)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isActive ? Color.green.opacity(0.45) : Color.white.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(isActive ? Color.green : Color.white.opacity(known ? 0.45 : 0.2), lineWidth: 1))
                        .overlay(
                            Text(display.name)
                                .font(.system(size: 9))
                                .foregroundStyle(isActive ? Color.white : Color.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 3))
                        .frame(width: max(display.frame.width * scale - 2, 4), height: max(display.frame.height * scale - 2, 4))
                        .position(
                            x: offsetX + (display.frame.midX - union.minX) * scale,
                            y: (union.maxY - display.frame.midY) * scale)
                }
            }
        }
    }
}

/// A head angle on a track from -range to +range degrees, with the facing-camera zone shaded.
private struct PoseGauge: View {
    let label: String
    let radians: Double?
    let range: Double
    let zone: Double?

    private var degrees: Double? { radians.map { $0 * 180 / .pi } }

    private var dotColor: Color {
        guard let degrees, let zone else { return .white }
        return abs(degrees) <= zone ? .green : .orange
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    if let zone {
                        Capsule()
                            .fill(Color.green.opacity(0.22))
                            .frame(width: width * zone / range)
                            .offset(x: width * (1 - zone / range) / 2)
                    }
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 1)
                        .offset(x: width / 2)
                    if let degrees {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 9, height: 9)
                            .offset(x: (min(max(degrees / range, -1), 1) + 1) / 2 * (width - 9))
                    }
                }
            }
            .frame(height: 9)
            Text(degrees.map { "\(String(format: "%.0f", $0))°" } ?? "n/a")
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .font(.caption)
    }
}
