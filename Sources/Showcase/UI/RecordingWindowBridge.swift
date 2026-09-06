import AppKit
import SwiftUI

/// Applies native window behavior while SwiftUI owns the recording/editor views.
struct RecordingWindowBridge: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WindowAttachmentView { WindowAttachmentView() }

    func updateNSView(_ view: WindowAttachmentView, context: Context) {
        view.attach = { [weak model, coordinator = context.coordinator] window in
            guard let model else { return }
            coordinator.update(window: window, model: model)
        }
        if let window = view.window {
            DispatchQueue.main.async { view.attach?(window) }
        }
    }

    final class WindowAttachmentView: NSView {
        var attach: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { DispatchQueue.main.async { self.attach?(window) } }
        }
    }

    @MainActor
    final class Coordinator {
        private var mode: Mode?
        private var highlight: NSPanel?
        private var editorFrame: NSRect?
        private var setupFrame: NSRect?
        private weak var observedWindow: NSWindow?

        private enum Mode { case setup, recording, editor }

        func update(window: NSWindow, model: AppModel) {
            let next: Mode = model.editor != nil ? .editor : (model.isRecording ? .recording : .setup)
            if mode != next || observedWindow !== window {
                if mode == .editor { editorFrame = window.frame }
                if mode == .setup { setupFrame = window.frame }
                observedWindow = window
                window.title = "Showcase"
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = next != .editor
                window.isOpaque = next == .editor
                window.backgroundColor = next == .editor ? .windowBackgroundColor : .clear
                window.hasShadow = next == .editor
                window.isMovableByWindowBackground = next != .editor
                window.level = next == .editor ? .normal : .floating
                window.collectionBehavior = next == .recording ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]
                // ScreenCaptureKit excludes this process from display captures.
                // Keep the setup/editor window available to normal screenshots.
                window.sharingType = .readOnly
                if next == .editor {
                    window.contentMaxSize = NSSize(width: 10_000, height: 10_000)
                    let toolbar = window.toolbar
                    window.styleMask = [.titled, .resizable, .closable, .miniaturizable]
                    window.toolbar = toolbar
                    window.toolbar?.isVisible = true
                    window.contentMinSize = NSSize(width: 940, height: 660)
                    if let editorFrame { window.setFrame(editorFrame, display: true) }
                    else { window.setContentSize(NSSize(width: 1_140, height: 800)); window.center() }
                } else {
                    // A borderless window removes all titlebar backing. Keeping
                    // the resizable capability lets AppKit make it key; matching
                    // content limits below keep the recorder at its fixed size.
                    window.styleMask = [.borderless, .resizable]
                    let size = next == .recording ? NSSize(width: 360, height: 96) : NSSize(width: 520, height: 88)
                    window.contentMinSize = size
                    window.contentMaxSize = size
                    window.setContentSize(size)
                    if next == .recording {
                        let screen = window.screen ?? NSScreen.main
                        if let visible = screen?.visibleFrame {
                            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24))
                        }
                    } else if let setupFrame {
                        window.setFrameOrigin(setupFrame.origin)
                    } else if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 40))
                    }
                }
                for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    window.standardWindowButton(button)?.isHidden = next != .editor
                }
                mode = next
            }
            if next == .editor { window.toolbar?.isVisible = true }
            // Prevent closing the only stop control while capture is starting or active.
            if model.isStartingOrStopping || model.isRecording {
                window.styleMask.remove(.closable)
            } else {
                window.styleMask.insert(.closable)
            }
            if model.countdownRemaining != nil, let source = model.selectedSource {
                showHighlight(for: source.descriptor.frame.cgRect)
            } else {
                highlight?.orderOut(nil)
            }
        }

        private func showHighlight(for source: CGRect) {
            let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
            let frame = RecordingWindowLayout.appKitRect(source, desktopTop: desktopTop)
            if highlight == nil {
                let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.level = .floating
                panel.sharingType = .none
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.contentView = NSHostingView(rootView:
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.red, lineWidth: 4)
                        .padding(2)
                )
                highlight = panel
            }
            highlight?.setFrame(frame, display: true)
            highlight?.orderFrontRegardless()
        }
    }
}

enum RecordingWindowLayout {
    static func appKitRect(_ source: CGRect, desktopTop: CGFloat) -> CGRect {
        CGRect(x: source.minX, y: desktopTop - source.maxY, width: source.width, height: source.height)
    }
}

/// The floating recorder can present a popover before its window becomes key.
/// Give the popover focus when attached, so its first pointer click stays inside it.
struct RecordingPopoverFocusBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> FocusView { FocusView() }
    func updateNSView(_ view: FocusView, context: Context) {}

    final class FocusView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeKey()
            }
        }
    }
}
