import AppKit

/// Publishes file URLs so receiving apps can import videos without loading them into memory.
@MainActor
enum VideoClipboard {
    enum ClipboardError: LocalizedError {
        case writeFailed

        var errorDescription: String? {
            "macOS could not write the video files to the clipboard. Please try again."
        }
    }

    static func copy(_ urls: [URL], to pasteboard: NSPasteboard = .general) throws {
        guard !urls.isEmpty else { throw ClipboardError.writeFailed }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls.map { $0 as NSURL }) else {
            throw ClipboardError.writeFailed
        }
    }
}
