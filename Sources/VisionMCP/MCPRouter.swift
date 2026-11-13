import Foundation

/// Serves MCP (Streamable HTTP, stateless, JSON responses) and a plain JSON scene endpoint.
struct MCPRouter {
    static let serverVersion = "0.1.0"
    private static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private static let localHosts: Set<String> = ["127.0.0.1", "localhost"]

    let state: SceneState
    /// Starts the on-screen display calibration. Returns why it could not start, or nil.
    let startCalibration: () -> String?

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        guard isLocal(request) else {
            return .json(403, ["error": "Requests must come from this Mac."])
        }
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        switch (request.method, path) {
        case ("POST", "/mcp"):
            return rpcResponse(request.body)
        case (_, "/mcp"):
            return HTTPResponse(status: 405, headers: ["Allow": "POST"])
        case ("GET", "/scene"):
            return .json(200, state.snapshot(includeEvents: true), pretty: true)
        case ("GET", "/health"):
            return .json(200, ["ok": true, "name": "vision-mcp", "version": Self.serverVersion])
        default:
            return .json(404, ["error": "Not found"])
        }
    }

    /// Rejects requests a web page could forge: a foreign Origin, or a Host that only resolves here by DNS rebinding.
    private func isLocal(_ request: HTTPRequest) -> Bool {
        guard let host = request.headers["host"]?.lowercased(),
              let name = host.split(separator: ":").first,
              Self.localHosts.contains(String(name))
        else { return false }
        if let origin = request.headers["origin"] {
            guard let originHost = URL(string: origin)?.host?.lowercased(),
                  Self.localHosts.contains(originHost)
            else { return false }
        }
        return true
    }

    // MARK: - JSON-RPC

    private func rpcResponse(_ body: Data) -> HTTPResponse {
        guard let json = try? JSONSerialization.jsonObject(with: body) else {
            return .json(400, Self.error(NSNull(), -32700, "Parse error"))
        }
        if let batch = json as? [Any] {
            let replies = batch.compactMap { reply(to: $0) }
            return replies.isEmpty ? HTTPResponse(status: 202) : .json(200, replies)
        }
        guard let reply = reply(to: json) else { return HTTPResponse(status: 202) }
        return .json(200, reply)
    }

    private func reply(to message: Any) -> [String: Any]? {
        guard let message = message as? [String: Any] else {
            return Self.error(NSNull(), -32600, "Invalid request")
        }
        guard let method = message["method"] as? String else {
            let isResponse = message["result"] != nil || message["error"] != nil
            return isResponse ? nil : Self.error(message["id"] ?? NSNull(), -32600, "Invalid request")
        }
        guard let id = message["id"], !(id is NSNull) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = requested.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? "2025-06-18"
            return Self.result(id, [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "vision-mcp", "title": "Vision MCP", "version": Self.serverVersion],
                "instructions": Self.instructions,
            ])
        case "ping":
            return Self.result(id, [String: Any]())
        case "tools/list":
            return Self.result(id, ["tools": Self.tools])
        case "tools/call":
            guard let payload = toolPayload(params) else {
                return Self.error(id, -32602, "Unknown tool: \(params["name"] as? String ?? "")")
            }
            let text = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return Self.result(id, [
                "content": [["type": "text", "text": text]],
                "structuredContent": payload,
                "isError": false,
            ])
        default:
            return Self.error(id, -32601, "Method not found: \(method)")
        }
    }

    private func toolPayload(_ params: [String: Any]) -> [String: Any]? {
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        switch params["name"] as? String {
        case "get_scene":
            return state.snapshot(includeEvents: arguments["include_events"] as? Bool ?? true)
        case "list_cameras":
            let active = state.currentDevice
            return ["cameras": CameraCapture.devices().map {
                ["name": $0.localizedName, "active": $0.localizedName == active] as [String: Any]
            }]
        case "calibrate_displays":
            if let problem = startCalibration() { return ["started": false, "reason": problem] }
            return ["started": true, "note": "The user now follows a dot across each display for about 12 seconds per display."]
        default:
            return nil
        }
    }

    private static func result(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(_ id: Any, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message] as [String: Any]]
    }

    // MARK: - Definitions

    private static let instructions = """
        Vision MCP reports what this Mac's camera sees as structured data computed on the Mac. \
        It never returns images. Call get_scene to learn whether anyone is in view, how many people, \
        whether each face is turned toward the camera, which display the nearest person is looking at (after a calibration), \
        and which hands are visible. Face ids are anonymous: they say nothing \
        about who a person is, and they reset when a face leaves view or the app restarts. \
        When scene_known is false the scene is unknown, which is different from empty.
        """

    private static let tools: [[String: Any]] = [
        [
            "name": "get_scene",
            "title": "Get camera scene",
            "description": """
                Returns the current structured view of what this Mac's camera sees, computed on the Mac: \
                people_count, anonymous face tracks (head pose in degrees, facing_camera, position in the frame, \
                a distance hint, how long each has been visible), presence duration, and recent events \
                (face_appeared, face_left, people_count_changed, looking_at_changed, camera_status). \
                attention.looking_at names the display the nearest person's head is turned toward, or "away"; it needs \
                attention.calibrated to be true and is estimated from head pose, so small eye-only glances are missed. \
                hands lists the hands in view with their side and position. No image is captured, stored, \
                or returned. If scene_known is false (camera paused, locked, starting, or without permission) \
                the scene is unknown, not empty. facing_camera is a head-pose estimate, not eye tracking. \
                Box coordinates are normalized with the origin at the top left of the unmirrored frame.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "include_events": [
                        "type": "boolean",
                        "description": "Include the recent event history, newest first. Defaults to true.",
                    ] as [String: Any],
                ],
                "additionalProperties": false,
            ] as [String: Any],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "calibrate_displays",
            "title": "Calibrate displays",
            "description": "Starts an on-screen calibration that covers every display for about 12 seconds per display while the user looks at a moving dot. It teaches Vision MCP which head poses mean looking at which display, for the current camera. Call this only when the user asks to calibrate, since it takes over their screens.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false] as [String: Any],
            "annotations": ["readOnlyHint": false, "openWorldHint": false],
        ],
        [
            "name": "list_cameras",
            "title": "List cameras",
            "description": "Lists the cameras this Mac can use and which one Vision MCP is reading. The camera is chosen from the Vision MCP menu bar item.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false] as [String: Any],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
    ]
}
