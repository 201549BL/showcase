import AVFoundation
import SwiftUI

struct ZoomTimelineView: View {
    @ObservedObject var model: EditorModel
    @State private var scrubProjection: TimelineDragProjection?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                let geometry = TimelineGeometry(duration: model.recordingDuration, width: proxy.size.width)
                let ruler = TimelineRuler(duration: model.recordingDuration, width: proxy.size.width)

                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        timelineRuler(geometry: geometry, ruler: ruler)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                            .gesture(seekGesture(geometry: geometry))

                        TrimTimelineView(model: model, geometry: geometry)
                            .frame(height: 28).padding(.bottom, 8)

                        ZStack(alignment: .topLeading) {
                            timelineBackground(geometry: geometry)

                            ForEach(Array(model.clickTimestamps.enumerated()), id: \.offset) { _, time in
                                Circle()
                                    .fill(.orange.opacity(0.85))
                                    .frame(width: 4, height: 4)
                                    .offset(x: geometry.x(for: time) - 2, y: 5)
                                    .allowsHitTesting(false)
                            }

                            ForEach(Array(model.project.zoomSegments.enumerated()), id: \.element.id) { order, zoom in
                                ZoomTimelineBlock(
                                    model: model, zoom: zoom, geometry: geometry,
                                    number: order + 1, isSelected: model.selectedZoomID == zoom.id
                                )
                                .frame(
                                    width: max(24, geometry.width(from: zoom.startTime, to: zoom.endTime)),
                                    height: 42
                                )
                                .offset(x: geometry.x(for: zoom.startTime), y: 14)
                                .zIndex(TimelineBlockStacking.zIndex(
                                    isSelected: model.selectedZoomID == zoom.id, order: order
                                ))
                            }

                            if model.project.zoomSegments.isEmpty {
                                Text("Add a zoom at the playhead to get started")
                                    .font(.callout).foregroundStyle(.secondary)
                                    .frame(width: geometry.width, height: 64)
                                    .allowsHitTesting(false)
                            }
                            trimmedOverlay(geometry: geometry)
                        }
                        .frame(height: 64)
                        .coordinateSpace(name: ZoomTimelineCoordinateSpace.track)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        if model.hasAudio {
                            audioBand(geometry: geometry).frame(height: 36).padding(.top, 8)
                        }
                        if model.project.hasCamera {
                            CameraTimelineView(model: model, geometry: geometry).padding(.top, 8)
                        }
                        if model.showsCameraEmphasisTrack {
                            CameraEmphasisTimelineView(model: model, geometry: geometry).padding(.top, 8)
                        }
                    }
                    playhead(geometry: geometry)
                }
                .coordinateSpace(name: "playhead-timeline")
            }
            .frame(height: 128 + model.cameraTimelineExtraHeight + (model.hasAudio ? 44 : 0))

            HStack(spacing: 14) {
                if model.hasAudio { legend("Audio", color: .teal) }
                legend("Trim", color: .orange)
                legend("Manual", color: .cyan)
                legend("Automatic", color: .indigo)
                legend("Clicks", color: .orange)
                if model.project.hasCamera { legend("Camera", color: .mint) }
                if model.showsCameraEmphasisTrack { legend("Camera effects", color: .purple) }
                Spacer(minLength: 12)
                Text(model.selectedZoom == nil && model.selectedCamera == nil && model.selectedCameraEmphasis == nil ? "Select a section to edit" : "Drag to move · Drag edges to resize · ⌫ to delete")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.caption)
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 16)
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).foregroundStyle(.secondary)
        }
    }

    private func audioBand(geometry: TimelineGeometry) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(0.055))
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.teal.opacity(model.project.resolvedIsAudioMuted ? 0.12 : 0.3))
                .frame(width: max(0, geometry.width(from: model.trimStart, to: model.trimEnd)))
                .offset(x: geometry.x(for: model.trimStart))
            HStack {
                Toggle(isOn: Binding(
                    get: { !model.project.resolvedIsAudioMuted },
                    set: { model.setAudioMuted(!$0) }
                )) {
                    Label("Recorded audio", systemImage: model.project.resolvedIsAudioMuted
                        ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                Spacer()
                Text(model.project.resolvedIsAudioMuted ? "Muted" : "On")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            Rectangle()
                .fill(.white.opacity(0.8))
                .frame(width: 2)
                .offset(x: geometry.x(for: model.playheadTime) - 1)
                .allowsHitTesting(false)
        }
        .clipped()
        .help("Include recorded audio in preview and export")
    }

    private func timelineBackground(geometry: TimelineGeometry) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(.primary.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.06)))
        }
        .contentShape(Rectangle())
        .gesture(seekGesture(geometry: geometry))
    }

    private func trimmedOverlay(geometry: TimelineGeometry) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.75))
                .frame(width: geometry.x(for: model.trimStart))
            Spacer(minLength: 0)
            Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.75))
                .frame(width: max(0, geometry.width - geometry.x(for: model.trimEnd)))
        }
        .frame(width: geometry.width, height: 64)
        .allowsHitTesting(false)
        .zIndex(15_000)
    }

    private func seekGesture(geometry: TimelineGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            model.seek(to: geometry.time(for: value.location.x))
        }
    }

    private func timelineRuler(geometry: TimelineGeometry, ruler: TimelineRuler) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(ruler.ticks, id: \.self) { time in
                let x = geometry.x(for: time)
                Text(ruler.label(for: time))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: time == 0 ? .leading : .center)
                    .offset(x: min(max(0, x - 28), max(0, geometry.width - 56)))
                Rectangle().fill(.primary.opacity(0.2)).frame(width: 1, height: 5)
                    .offset(x: x, y: 18)
            }
        }
        .frame(width: geometry.width, height: 28, alignment: .topLeading)
    }

    private func playhead(geometry: TimelineGeometry) -> some View {
        let x = min(max(1, geometry.x(for: model.playheadTime)), max(1, geometry.width - 1))
        let marker = colorScheme == .dark ? Color.white : Color(white: 0.12)
        let edge = colorScheme == .dark ? Color.black.opacity(0.6) : Color.white.opacity(0.8)
        return ZStack(alignment: .top) {
            Rectangle().fill(edge).frame(width: 4, height: 114 + model.cameraTimelineExtraHeight + (model.hasAudio ? 44 : 0))
                .overlay(Rectangle().fill(marker).frame(width: 2.5))
                .offset(y: 14)
                .allowsHitTesting(false)

            TimelinePlayheadCap()
                .fill(marker)
                .overlay(TimelinePlayheadCap().stroke(edge, lineWidth: 0.75))
                .frame(width: 16, height: 16)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .frame(width: 28, height: 24, alignment: .top)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("playhead-timeline"))
                    .onChanged { value in
                        if scrubProjection == nil {
                            model.player.pause()
                            scrubProjection = TimelineDragProjection(
                                initialTime: model.playheadTime,
                                pointerStartX: value.startLocation.x,
                                geometry: geometry
                            )
                        }
                        guard let scrubProjection else { return }
                        model.seek(to: scrubProjection.time(atPointerX: value.location.x))
                    }
                    .onEnded { _ in scrubProjection = nil })
                .help("Drag to scrub")
                .accessibilityLabel("Playhead")
                .accessibilityValue(model.playheadTime.formatted(.number.precision(.fractionLength(1))) + " seconds")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: model.stepFrame(by: 1)
                    case .decrement: model.stepFrame(by: -1)
                    @unknown default: break
                    }
                }
        }
        .offset(x: x - 14)
    }
}

private struct TimelinePlayheadCap: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + 2, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + 2),
                              control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 2))
            path.addQuadCurve(to: CGPoint(x: rect.minX + 2, y: rect.minY),
                              control: CGPoint(x: rect.minX, y: rect.minY))
            path.closeSubpath()
        }
    }
}

private struct ZoomTimelineBlock: View {
    @ObservedObject var model: EditorModel
    let zoom: ZoomSegment
    let geometry: TimelineGeometry
    let number: Int
    let isSelected: Bool
    @State private var isHovered = false

    @State private var moveProjection: TimelineDragProjection?
    @State private var startProjection: TimelineDragProjection?
    @State private var endProjection: TimelineDragProjection?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(blockGradient)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(tint.opacity(isSelected ? 1 : isHovered ? 0.8 : 0.4),
                                          lineWidth: isSelected ? 2 : 1)
                    }
                    .contentShape(Rectangle())
                    .gesture(moveGesture)
                    .onTapGesture { model.selectZoom(id: zoom.id) }

                if proxy.size.width >= 64 {
                    HStack(spacing: 6) {
                        if proxy.size.width >= 110 {
                            Image(systemName: zoom.source == .automatic ? "sparkles" : "plus.magnifyingglass")
                                .foregroundStyle(tint)
                        }
                        if proxy.size.width >= 145 {
                            Text("Zoom \(number)").lineLimit(1)
                            Spacer(minLength: 2)
                        }
                        Text(zoom.scale.formatted(.number.precision(.fractionLength(1))) + "×")
                            .monospacedDigit().fixedSize()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 17)
                    .allowsHitTesting(false)
                }

                HStack(spacing: 0) {
                    resizeHandle.gesture(startResizeGesture)
                    Spacer(minLength: 0)
                    resizeHandle.gesture(endResizeGesture)
                }
                .padding(.horizontal, 2)
            }
            .onHover { isHovered = $0 }
            .help("Zoom \(number) · \(zoom.source == .automatic ? "Automatic" : "Manual") · Drag to move, or drag either edge to resize")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Zoom \(number), \(zoom.source == .automatic ? "automatic" : "manual")")
            .accessibilityValue("\(zoom.scale.formatted()) times, \(zoom.startTime.formatted()) to \(zoom.endTime.formatted()) seconds")
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
            .accessibilityAction { model.selectZoom(id: zoom.id) }
        }
    }

    private var tint: Color { zoom.source == .automatic ? .indigo : .cyan }

    private var blockGradient: LinearGradient {
        LinearGradient(
            colors: [tint.opacity(isSelected ? 0.48 : 0.28), tint.opacity(isSelected ? 0.27 : 0.12)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var resizeHandle: some View {
        Capsule()
            .fill(.primary.opacity(isSelected || isHovered ? 0.85 : 0.4))
            .frame(width: 3, height: 18)
            .frame(width: 10, height: 42)
            .contentShape(Rectangle())
    }

    private var moveGesture: some Gesture {
        DragGesture(
            minimumDistance: 2,
            coordinateSpace: .named(ZoomTimelineCoordinateSpace.track)
        )
            .onChanged { value in
                if moveProjection == nil {
                    model.beginHistoryTransaction(actionName: "Move Zoom")
                    moveProjection = TimelineDragProjection(
                        initialTime: zoom.startTime,
                        pointerStartX: value.startLocation.x,
                        geometry: geometry
                    )
                    model.selectZoom(id: zoom.id, seekToFocus: false)
                }
                guard let moveProjection else { return }
                model.moveZoom(
                    id: zoom.id,
                    toStart: moveProjection.time(atPointerX: value.location.x)
                )
            }
            .onEnded { _ in
                moveProjection = nil
                model.commitTimelineEdit()
            }
    }

    private var startResizeGesture: some Gesture {
        DragGesture(
            minimumDistance: 1,
            coordinateSpace: .named(ZoomTimelineCoordinateSpace.track)
        )
            .onChanged { value in
                if startProjection == nil {
                    model.beginHistoryTransaction(actionName: "Resize Zoom")
                    startProjection = TimelineDragProjection(
                        initialTime: zoom.startTime,
                        pointerStartX: value.startLocation.x,
                        geometry: geometry
                    )
                    model.selectZoom(id: zoom.id, seekToFocus: false)
                }
                guard let startProjection else { return }
                model.resizeZoomStart(
                    id: zoom.id,
                    to: startProjection.time(atPointerX: value.location.x)
                )
            }
            .onEnded { _ in
                startProjection = nil
                model.commitTimelineEdit()
            }
    }

    private var endResizeGesture: some Gesture {
        DragGesture(
            minimumDistance: 1,
            coordinateSpace: .named(ZoomTimelineCoordinateSpace.track)
        )
            .onChanged { value in
                if endProjection == nil {
                    model.beginHistoryTransaction(actionName: "Resize Zoom")
                    endProjection = TimelineDragProjection(
                        initialTime: zoom.endTime,
                        pointerStartX: value.startLocation.x,
                        geometry: geometry
                    )
                    model.selectZoom(id: zoom.id, seekToFocus: false)
                }
                guard let endProjection else { return }
                model.resizeZoomEnd(
                    id: zoom.id,
                    to: endProjection.time(atPointerX: value.location.x)
                )
            }
            .onEnded { _ in
                endProjection = nil
                model.commitTimelineEdit()
            }
    }


}

private enum ZoomTimelineCoordinateSpace {
    static let track = "Showcase.ZoomTimeline.Track"
}
