import SwiftUI

struct ZoomTimelineView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Zoom timeline", systemImage: "timeline.selection")
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

                        ForEach(model.project.zoomSegments) { zoom in
                            ZoomTimelineBlock(
                                model: model,
                                zoom: zoom,
                                geometry: geometry,
                                isSelected: model.selectedZoomID == zoom.id
                            )
                            .frame(
                                width: max(24, geometry.width(from: zoom.startTime, to: zoom.endTime)),
                                height: 34
                            )
                            .offset(x: geometry.x(for: zoom.startTime), y: 17)
                        }

                        playhead(geometry: geometry)
                    }
                    .frame(height: 58)
                    .clipped()
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

    @State private var moveAnchor: Double?
    @State private var startAnchor: Double?
    @State private var endAnchor: Double?

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
                    model.selectZoom(id: zoom.id)
                }

            HStack(spacing: 0) {
                resizeHandle
                    .gesture(startResizeGesture)
                Spacer(minLength: 0)
                resizeHandle
                    .gesture(endResizeGesture)
            }
            .padding(.horizontal, 3)
        }
        .help("Drag to move. Drag either edge to change duration.")
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
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if moveAnchor == nil {
                    moveAnchor = zoom.startTime
                    model.selectZoom(id: zoom.id, seekToFocus: false)
                }
                guard let moveAnchor else { return }
                let delta = geometry.timeDelta(for: value.translation.width)
                model.moveZoom(id: zoom.id, toStart: moveAnchor + delta)
            }
            .onEnded { _ in
                moveAnchor = nil
                model.commitTimelineEdit()
            }
    }

    private var startResizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if startAnchor == nil {
                    startAnchor = zoom.startTime
                    model.selectZoom(id: zoom.id, seekToFocus: false)
                }
                guard let startAnchor else { return }
                let delta = geometry.timeDelta(for: value.translation.width)
                model.resizeZoomStart(id: zoom.id, to: startAnchor + delta)
            }
            .onEnded { _ in
                startAnchor = nil
                model.commitTimelineEdit()
            }
    }

    private var endResizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if endAnchor == nil {
                    endAnchor = zoom.endTime
                    model.selectZoom(id: zoom.id, seekToFocus: false)
                }
                guard let endAnchor else { return }
                let delta = geometry.timeDelta(for: value.translation.width)
                model.resizeZoomEnd(id: zoom.id, to: endAnchor + delta)
            }
            .onEnded { _ in
                endAnchor = nil
                model.commitTimelineEdit()
            }
    }
}
