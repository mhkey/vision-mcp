# vision-mcp

A local MCP server that lets agents perceive what a Mac's camera sees as structured data: how many people are in view, anonymous face tracks, head pose, which display the person is looking at, the hands in view, and who appeared or left. Everything is computed on the Mac with Apple's Vision framework. No image is stored or returned.

Status: proof of concept.

## How it works

Vision MCP is a small menu bar app. It owns the camera (with its own macOS camera permission), analyzes about four frames per second, keeps the current scene and a short event history in memory, and serves them over MCP on `http://127.0.0.1:7723/mcp`.

- The eye in the menu bar shows whether the camera is being read. The menu pauses it, picks the camera, and quits.
- Show Preview in that menu opens a live view of the camera with the detections drawn on top (faces, upper bodies, hand skeletons) and a readout of the scene and recent events. It is display only, and the window asks macOS to leave it out of screenshots and screen sharing.
- The camera stops while the screen is locked.
- Frames are analyzed and dropped. No image is written to disk and nothing leaves the Mac.
- Face ids such as `face-3` are anonymous. They do not identify anyone, and they reset when a face leaves view or the app restarts.
- The server listens on the loopback interface only and rejects requests with a foreign `Origin` or `Host`.

## Build and run

Requires macOS 14 or later and the Swift toolchain (Xcode or the command line tools).

```bash
make run    # build, bundle build/VisionMCP.app, and open it
make stop   # quit it
```

The first launch asks for camera access. The app is ad-hoc signed by default, so macOS may ask again after a rebuild. To sign with a stable identity instead: `make app SIGN_IDENTITY="Developer ID Application: ..."`.

Options, passed after `--args` when using `open`:

| Option | Meaning |
|---|---|
| `--port 7723` | Port to listen on |
| `--fps 4` | Frames analyzed per second (0.2 to 10) |
| `--camera "FaceTime"` | Camera whose name contains this text |
| `--paused` | Start with the camera off |
| `--preview` | Open the preview window at launch |
| `--calibrate` | Run the display calibration at launch |
| `--capturable` | Let screenshots include the preview window |

## Which display is being looked at

The displays are not in the camera's view, so this comes from head pose. Calibrate Displays (in the menu and the preview sidebar) covers every display and moves a dot to the center and corners of each one, about 12 seconds per display. Look at the dot the way you normally would. Vision MCP records the head yaw and pitch at each stop and from then on reports the display whose calibrated range contains the current pose, or `away`.

- The calibration belongs to one camera position. Recalibrate after moving the camera or the displays.
- It is saved to `~/Library/Application Support/VisionMCP/gaze-calibration.json`. The file holds angle ranges per display: no image and nothing that identifies a person.
- Eye direction (the pupil's offset inside the eye, from Vision's face landmarks) is used only to settle a pose that fits two displays. A glance made with the eyes alone, without turning the head, is missed.

## Hands

Hands come from Vision's hand pose request and are analyzed twice a second. The scene lists each hand's side and position, and the preview draws its skeleton.

## Connect an agent

Any client that speaks MCP over HTTP:

```bash
claude mcp add --transport http vision http://127.0.0.1:7723/mcp
```

Clients that only speak stdio can use the bridge, which relays to the running app:

```json
{
  "mcpServers": {
    "vision": {
      "command": "/path/to/VisionMCP.app/Contents/MacOS/VisionMCP",
      "args": ["--stdio"]
    }
  }
}
```

Anything else can read plain JSON:

```bash
curl http://127.0.0.1:7723/scene
```

## Tools

### `get_scene`

Arguments: `include_events` (boolean, default true).

```json
{
  "camera": { "status": "running", "device": "FaceTime HD Camera", "analysis_fps": 4, "frame_size": "1280x720", "last_frame_age_s": 0.1, "last_analysis_ms": 12.4 },
  "scene_known": true,
  "people_count": 1,
  "bodies_detected": 1,
  "presence": { "present": true, "for_s": 412.5 },
  "attention": { "calibrated": true, "displays": ["Studio Display", "Built-in Retina Display"], "face": "face-1", "looking_at": "Studio Display", "for_s": 37.2 },
  "faces": [
    {
      "id": "face-1",
      "looking_at": "Studio Display",
      "facing_camera": true,
      "head_pose_deg": { "yaw": -4.1, "pitch": 2.0, "roll": 0.6 },
      "frame_position": "center",
      "distance_hint": "near",
      "box": { "x": 0.38, "y": 0.21, "w": 0.24, "h": 0.42 },
      "visible_for_s": 412.5
    }
  ],
  "hands": [
    { "side": "right", "frame_position": "right", "box": { "x": 0.68, "y": 0.52, "w": 0.12, "h": 0.16 } }
  ],
  "events": [
    { "type": "looking_at_changed", "id": "face-1", "from": "away", "to": "Studio Display", "at": "2026-01-01T10:06:15Z", "seconds_ago": 37.2 }
  ]
}
```

- When `scene_known` is false (camera paused, locked, starting, or without permission), the scene is unknown, which is different from empty.
- `people_count` is the larger of the tracked faces and the upper bodies detected, so it also counts someone facing away.
- `attention` follows the nearest face. `looking_at` is a display name or `away`, and is absent until a calibration exists for the camera.
- `facing_camera` is a head-pose estimate (yaw and pitch within 20 degrees), not eye tracking.
- Event types: `face_appeared`, `face_left`, `people_count_changed`, `looking_at_changed`, `camera_status`. The last 200 are kept.

### `calibrate_displays`

Starts the on-screen calibration described above. It takes over the screens, so agents should call it only when asked.

### `list_cameras`

Lists available cameras and which one is active.

## Roadmap

1. Owner recognition: enroll one face on the Mac so the scene can say `owner` or `not owner`, with everyone else staying anonymous.
2. A local description tool backed by an on-device vision language model.
3. A consented, on-screen-confirmed image capture tool as the rare exception.
