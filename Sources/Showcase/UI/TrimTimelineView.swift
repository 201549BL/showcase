import AVFoundation
import SwiftUI

/// Trimming has its own range and handles, separate from playback and zoom edits.
struct TrimTimelineView: View {
    @ObservedObject var model: EditorModel
    let geometry: TimelineGeometry
    @State private var startProjection: TimelineDragProjection?
    @State private var endProjection: TimelineDragProjection?

    var body: some View {
        let start = geometry.x(for: model.trimStart)
        let end = geometry.x(for: model.trimEnd)
        let width = max(0, end - start)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.035))
            Rectangle()
                .fill(.orange.opacity(0.12))
                .overlay(Rectangle().strokeBorder(.orange.opacity(0.65), lineWidth: 1))
                .frame(width: width, height: 28).offset(x: start)
                .overlay(alignment: .leading) {
                    if width > 240 {
                        Text("Trim  ·  \(time(model.trimStart)) – \(time(model.trimEnd))  ·  \(duration)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.primary)
                            .frame(width: width, height: 28).offset(x: start)
                    } else if width > 60 {
                        Text(duration).font(.caption.monospacedDigit())
                            .frame(width: width, height: 28).offset(x: start)
                    }
                }
                .allowsHitTesting(false)

            handle(start: true)
                .offset(x: start - 16)
            handle(start: false)
                .offset(x: end - 4)
        }
        .frame(width: geometry.width, height: 28, alignment: .topLeading)
        .coordinateSpace(name: "trim-track")
        .onDisappear {
            if startProjection != nil || endProjection != nil { model.commitHistoryTransaction() }
        }
    }

    private var duration: String {
        (model.trimEnd - model.trimStart).formatted(.number.precision(.fractionLength(1))) + " s"
    }

    private func time(_ seconds: Double) -> String {
        String(format: "%02d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    private func handle(start: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.orange)
            .overlay(Capsule().fill(.black.opacity(0.65)).frame(width: 2, height: 13))
            .frame(width: 12, height: 28)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("trim-track"))
                .onChanged { value in
                    if (start ? startProjection : endProjection) == nil {
                        model.player.pause()
                        model.beginHistoryTransaction(actionName: start ? "Trim Start" : "Trim End")
                        let projection = TimelineDragProjection(
                            initialTime: start ? model.trimStart : model.trimEnd,
                            pointerStartX: value.startLocation.x, geometry: geometry
                        )
                        if start { startProjection = projection } else { endProjection = projection }
                    }
                    guard let projection = start ? startProjection : endProjection else { return }
                    updateBoundary(start: start, to: projection.time(atPointerX: value.location.x))
                }
                .onEnded { _ in
                    startProjection = nil
                    endProjection = nil
                    model.commitHistoryTransaction()
                })
            .help(start ? "Drag to trim the start" : "Drag to trim the end")
            .accessibilityLabel(start ? "Trim start" : "Trim end")
            .accessibilityValue(time(start ? model.trimStart : model.trimEnd))
            .accessibilityAdjustableAction { direction in
                let delta: Double
                switch direction {
                case .increment: delta = 1.0 / Double(max(1, model.project.recording.framesPerSecond))
                case .decrement: delta = -1.0 / Double(max(1, model.project.recording.framesPerSecond))
                @unknown default: return
                }
                model.player.pause()
                model.beginHistoryTransaction(actionName: start ? "Trim Start" : "Trim End")
                updateBoundary(start: start, to: (start ? model.trimStart : model.trimEnd) + delta)
                model.commitHistoryTransaction()
            }
    }

    private func updateBoundary(start: Bool, to time: Double) {
        if start { model.setTrimStart(time) } else { model.setTrimEnd(time) }
        model.seek(to: start ? model.trimStart : model.trimEnd)
    }
}
