# SmoothScreen

SmoothScreen is a local, macOS-only screen recorder for creating polished product demos. It records the screen separately from mouse input so cursor smoothing and camera movement can be applied non-destructively after recording.

## Current milestone

The first vertical slice includes:

- Display and window discovery through ScreenCaptureKit
- Cursor-free screen recording with system audio
- Timestamped mouse, click, scroll, and keyboard metadata
- A recoverable `.screenproject` directory format
- A minimal SwiftUI source picker and recording controller

Automatic zoom generation, synthetic cursor rendering, preview, and final composition are the next milestones.

## Requirements

- macOS 14 or newer
- Xcode 16 or newer
- Screen Recording permission
- Input Monitoring permission for global mouse and keyboard metadata

## Run during development

Open `Package.swift` in Xcode and run the `SmoothScreen` executable, or use:

```bash
swift run SmoothScreen
```

The first capture prompts for macOS permissions. Restart the application after granting Screen Recording permission if macOS requests it.

## Project layout

```text
Sources/SmoothScreen/
├── App/       Application state and entry point
├── Capture/   ScreenCaptureKit and input event capture
├── Project/   Project models and persistence
└── UI/        SwiftUI screens
```
