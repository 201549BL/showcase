import AVKit
import SwiftUI

/// Playback controls live in the timeline, leaving the canvas unobstructed.
struct EditorVideoView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.allowsVideoFrameAnalysis = false
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}

/// Scope unmodified transport keys to this editor's window. Text editing and
/// native controls keep their own keys; sheets and popovers are separate windows.
struct EditorPlaybackShortcuts: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> ShortcutView {
        let view = ShortcutView()
        view.model = model
        view.installMonitor()
        return view
    }

    func updateNSView(_ view: ShortcutView, context: Context) { view.model = model }

    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) {
        view.removeMonitor()
    }

    final class ShortcutView: NSView {
        weak var model: EditorModel?
        private var monitor: Any?

        func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, let model = self.model,
                      NSApp.keyWindow === window, event.window === window,
                      window.attachedSheet == nil,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      !(window.firstResponder is NSTextView),
                      !(window.firstResponder is NSControl)
                else { return event }

                switch event.keyCode {
                case 49:
                    if !event.isARepeat { model.togglePlayback() }
                case 123: model.stepFrame(by: -1)
                case 124: model.stepFrame(by: 1)
                default: return event
                }
                return nil
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
