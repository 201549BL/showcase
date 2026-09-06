# Showcase

A native Mac screen recorder for polished product demos. Record your screen, cursor, microphone, and face camera, then adjust the framing and motion in a live editor. Recording and editing stay on your Mac.

## Install

Download `Showcase-0.1.0-universal.zip` from [GitHub Releases](https://github.com/201549BL/Showcase/releases), unzip it, and drag **Showcase.app** into **Applications**.

- macOS 14 or newer; Apple silicon and Intel Macs.
- Microphone capture requires macOS 15 or newer.
- Native Liquid Glass on macOS 26, with translucent materials on earlier versions.
- Allow **Screen Recording** and **Input Monitoring** when prompted. Camera and microphone permissions are requested when you enable those inputs.

Restart Showcase after granting Screen Recording access if macOS asks you to. Release downloads are Developer ID signed and notarized; you should not need to disable Gatekeeper.

## Record

Choose a screen or window in the floating bar. Use the microphone, system audio, and camera buttons to configure your inputs. Press **Record** for a cancellable three-second countdown.

While recording, the floating bar shows elapsed time and a red **Stop recording** button. You can also stop from the recording item in the macOS menu bar. Stopping opens the editor. Showcase's own windows are excluded from full-display captures.

## Edit and export

- Adjust the background, padding, corners, and aspect ratio in **Frame**.
- Change cursor size, smoothing, and click animation in **Cursor**.
- Generate screen zooms from recorded clicks, or add one at the playhead using **Add effect**.
- Move timeline sections by dragging their bodies; resize them with the edge handles.
- Drag the playhead to scrub. Use the orange trim rail to shorten the recording.
- Use camera visibility sections to choose when your face appears. Camera effects change its size temporarily; touching effects blend directly into one another.
- During screen zooms, generated camera effects make the face camera smaller. Their size, timing, and transition remain editable.
- Undo with **⌘Z** and redo with **⇧⌘Z**.
- Export an MP4 in 1080p or 4K, with landscape, square, portrait, or source framing.

New recordings are saved in `~/Movies/Showcase` as recoverable `.screenproject` folders. Keep the entire folder together: it contains screen/camera media, input-event metadata, and edits. Use **Open recording…** in the source popover to reopen a project. Recordings previously saved in `~/Movies/SmoothScreen` continue to work.

## Privacy

Showcase saves screen recordings, optional camera/audio recordings, and timestamped cursor, click, scroll, and keyboard-event metadata locally. Keyboard metadata includes key codes and modifier flags. Treat a project folder as sensitive recording data when sharing it. Showcase has no account service, analytics, or upload feature; exporting writes a local video file.

## Build from source

Install Xcode 26 or newer and select its command-line tools, then run:

```bash
swift test
./scripts/build-app.sh debug
open .build/Showcase.app
```

Local builds use an available Apple Development certificate, or ad hoc signing when none is available. `SHOWCASE_SIGNING_IDENTITY` overrides the signing identity. Set `SHOWCASE_PROJECT` to a `.screenproject` path to open it at launch. The previous `SMOOTHSCREEN_` variable names remain supported for these two settings.

The bundle identifier remains `com.eirikbjorndal.SmoothScreen` so the rename preserves the app's existing identity.

See [the release guide](docs/RELEASING.md) for universal builds, Developer ID signing, notarization, and publishing.

## Source layout

```text
Sources/Showcase/
├── App/       Application state and entry point
├── Capture/   ScreenCaptureKit, camera, and input-event capture
├── Editor/    Editing state and undo history
├── Motion/    Cursor smoothing and camera planning
├── Project/   Project models and persistence
├── Rendering/ Core Image preview and export
└── UI/        SwiftUI recorder and editor
```
