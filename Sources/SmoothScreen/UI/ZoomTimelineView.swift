import SwiftUI

struct ZoomTimelineView: View {
    @ObservedObject var model: EditorModel
    let onEditCameraPosition: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Timeline", systemImage: "timeline.selection")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(timeLabel(model.playheadTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let geometry = TimelineGeometry(
                    duration: model.recordingDuration,
                    width: proxy.size.width
                )

                VStack(spacing: 5) {
                    timelineRuler(geometry: geometry)
                        .frame(height: 14)

                    ZStack(alignment: .topLeading) {
                        timelineBackground(geometry: geometry)

                        ForEach(Array(model.clickTimestamps.enumerated()), id: \.offset) { _, time in
                            Capsule()
                                .fill(.orange.opacity(0.9))
                                .frame(width: 2, height: 9)
                                .offset(x: geometry.x(for: time) - 1, y: 4)
                                .allowsHitTesting(false)
                        }

                        ForEach(Array(model.project.zoomSegments.enumerated()), id: \.element.id) { order, zoom in
                            ZoomTimelineBlock(
                                model: model,
                                zoom: zoom,
                                geometry: geometry,
                                isSelected: model.selectedZoomID == zoom.id,
                                onEditCameraPosition: onEditCameraPosition
                            )
                            .frame(
                                width: max(24, geometry.width(from: zoom.startTime, to: zoom.endTime)),
                                height: 34
                            )
                            .offset(x: geometry.x(for: zoom.startTime), y: 17)
                            .zIndex(TimelineBlockStacking.zIndex(
                                isSelected: model.selectedZoomID == zoom.id,
                                order: order
                            ))
                        }

                        playhead(geometry: geometry)
                            .zIndex(20_000)
                    }
                    .frame(height: 58)
                    .coordinateSpace(name: ZoomTimelineCoordinateSpace.track)
                    .clipped()

                    if model.hasAudio {
                        audioBand(geometry: geometry)
                            .frame(height: 36)
                    }
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.08))
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
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(0.055))

            Rectangle()
                .fill(Color.black.opacity(0.28))
                .frame(width: geometry.x(for: model.trimStart))

            Rectangle()
                .fill(Color.black.opacity(0.28))
                .frame(width: max(0, geometry.width - geometry.x(for: model.trimEnd)))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    model.seek(to: geometry.time(for: value.location.x))
                }
        )
    }

    private func timelineRuler(geometry: TimelineGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<5, id: \.self) { index in
                let fraction = Double(index) / 4
                let time = model.recordingDuration * fraction
                Text(timeLabel(time))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .offset(
                        x: rulerLabelX(index: index, geometry: geometry),
                        y: 0
                    )
            }
        }
    }

    private func rulerLabelX(index: Int, geometry: TimelineGeometry) -> Double {
        let x = geometry.x(for: model.recordingDuration * Double(index) / 4)
        if index == 0 { return x }
        if index == 4 { return max(0, x - 34) }
        return x - 17
    }

    private func playhead(geometry: TimelineGeometry) -> some View {
        let x = geometry.x(for: model.playheadTime)
        return ZStack(alignment: .top) {
            Circle()
                .fill(.white)
                .frame(width: 8, height: 8)
            Capsule()
                .fill(.white)
                .frame(width: 2, height: 54)
                .offset(y: 4)
        }
        .shadow(color: .black.opacity(0.45), radius: 2)
        .offset(x: x - 4, y: 0)
        .allowsHitTesting(false)
    }

    private func timeLabel(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct ZoomTimelineBlock: View {
    @ObservedObject var model: EditorModel
    let zoom: ZoomSegment
    let geometry: TimelineGeometry
    let isSelected: Bool
    let onEditCameraPosition: () -> Void

    @State private var moveProjection: TimelineDragProjection?
    @State private var startProjection: TimelineDragProjection?
    @State private var endProjection: TimelineDragProjection?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(blockGradient)
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isSelected ? .white : .white.opacity(0.25), lineWidth: isSelected ? 2 : 1)
                }
                .contentShape(Rectangle())
                .gesture(moveGesture)
                .onTapGesture {
                    model.selectBaseViewbox(for: zoom.id)
                }
                .help("Drag to move. Drag either edge to change duration.")

            HStack(spacing: 0) {
                resizeHandle
                    .gesture(startResizeGesture)
                Spacer(minLength: 0)
                resizeHandle
                    .gesture(endResizeGesture)
            }
            .padding(.horizontal, 3)

            ForEach(model.cameraPositions(for: zoom)) { position in
                Button {
                    model.selectCameraPosition(position, in: zoom.id)
                    onEditCameraPosition()
                } label: {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(
                            isSelected && model.selectedViewboxTarget?.id == position.id
                                ? Color.white
                                : Color.white.opacity(0.72)
                        )
                        .shadow(color: .black.opacity(0.55), radius: 1)
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 28)
                .position(
                    x: geometry.x(for: position.time) - geometry.x(for: zoom.startTime),
                    y: 17
                )
                .help("Camera position at \(timeLabel(position.time))")
            }
        }
    }

    private var blockGradient: LinearGradient {
        let colors: [Color] = zoom.source == .automatic
            ? [Color.indigo.opacity(0.95), Color.purple.opacity(0.9)]
            : [Color.blue.opacity(0.95), Color.cyan.opacity(0.75)]
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    private var resizeHandle: some View {
        Capsule()
            .fill(.white.opacity(isSelected ? 0.9 : 0.55))
            .frame(width: 4, height: 20)
            .padding(.horizontal, 3)
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

    private func timeLabel(_ seconds: Double) -> String {
        String(format: "%02d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}

private enum ZoomTimelineCoordinateSpace {
    static let track = "SmoothScreen.ZoomTimeline.Track"
}
