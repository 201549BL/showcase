# SmoothScreen

SmoothScreen is a local, macOS-only screen recorder for creating polished product demos. It records the screen separately from mouse input so cursor smoothing and camera movement can be applied non-destructively after recording.

## Current milestone

The usable V1 includes:

- Display and window discovery through ScreenCaptureKit
- Cursor-free screen recording with system audio and optional microphone audio
- Timestamped mouse, click, scroll, and keyboard metadata
- A recoverable `.screenproject` directory format
- Smoothed, high-resolution synthetic cursor rendering
- Automatic click-driven zoom generation and manual zooms
- Live composed preview with background, framing, cursor, and zoom controls
- Visual click/zoom timeline with seeking, moving, and edge resizing
- Direct focus editing by clicking or dragging on the video preview
- Undo and redo for timeline, focus, zoom, trim, canvas, and cursor edits
- Landscape, square, vertical, and source-aspect exports
- Beginning/end trimming and 1080p or 4K MP4 export

## Requirements

- macOS 14 or newer
- Xcode 16 or newer
- Screen Recording permission
- Input Monitoring permission for global mouse and keyboard metadata

## Run during development

Build a signed local app bundle and open it:

```bash
./scripts/build-app.sh
open .build/SmoothScreen.app
```

The first capture prompts for macOS permissions. Restart the application after granting Screen Recording permission if macOS requests it.

For command-line development you can also use `swift run SmoothScreen`, but the app-bundle workflow provides a stable bundle identifier for macOS privacy permissions.

## Editing a recording

Open a `.screenproject` and use the timeline below the preview to edit the camera:

- Click the empty timeline to seek.
- Click a zoom block to select it, drag its body to move it, or drag either white edge to resize it.
- Orange marks show recorded clicks.
- Choose **Set Focus**, then click or drag to a point in the preview to center the selected zoom there.
- **Add Zoom Here** creates a manual zoom at the playhead; **Regenerate** rebuilds automatic zooms from recorded clicks.
- Use **Command-Z** to undo and **Shift-Command-Z** to redo. Slider drags and timeline drags each count as one edit.

## Project layout

```text
Sources/SmoothScreen/
├── App/       Application state and entry point
├── Capture/   ScreenCaptureKit and input event capture
├── Editor/    Project editing state
├── Motion/    Cursor smoothing and camera planning
├── Project/   Project models and persistence
├── Rendering/ Core Image preview and export composition
└── UI/        SwiftUI screens
```

Projects are saved under `~/Movies/SmoothScreen`. All processing stays on the Mac.
