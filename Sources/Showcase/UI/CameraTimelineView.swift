import SwiftUI

struct CameraTimelineView: View {
    @ObservedObject var model: EditorModel
    let geometry: TimelineGeometry

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(.primary.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.06)))
                .contentShape(Rectangle())
                .onTapGesture { location in model.seek(to: geometry.time(for: location.x)) }
                .onTapGesture(count: 2) { location in
                    model.seek(to: geometry.time(for: location.x))
                    model.addCameraSection()
                }

            if model.project.resolvedCameraSegments.isEmpty {
                Button(action: model.addCameraSection) {
                    Label("Add camera section at playhead", systemImage: "video.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.plain).disabled(!model.canAddCamera)
                .frame(width: geometry.width, height: 44)
            }

            ForEach(Array(model.project.resolvedCameraSegments.enumerated()), id: \.element.id) { index, section in
                CameraTimelineBlock(model: model, section: section, geometry: geometry, number: index + 1)
                    .frame(width: max(24, geometry.width(from: section.startTime, to: section.endTime)), height: 42)
                    .offset(x: geometry.x(for: section.startTime), y: 1)
                    .zIndex(model.selectedCameraID == section.id ? 1 : 0)
            }

            HStack(spacing: 0) {
                Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.75))
                    .frame(width: geometry.x(for: model.trimStart))
                Spacer(minLength: 0)
                Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.75))
                    .frame(width: max(0, geometry.width - geometry.x(for: model.trimEnd)))
            }
            .allowsHitTesting(false).zIndex(2)
        }
        .frame(height: 44)
        .coordinateSpace(name: "camera-track")
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("Add camera section at playhead", action: model.addCameraSection).disabled(!model.canAddCamera)
            Button("Split camera at playhead", action: model.splitCameraSection).disabled(!model.canSplitCamera)
        }
    }
}

private struct CameraTimelineBlock: View {
    @ObservedObject var model: EditorModel
    let section: CameraSegment
    let geometry: TimelineGeometry
    let number: Int
    @State private var projection: TimelineDragProjection?
    @State private var isHovered = false
    private var selected: Bool { model.selectedCameraID == section.id }
    private var visible: Bool {
        model.project.resolvedCameraOverlay.isVisible
            && (section.settings ?? model.project.resolvedCameraOverlay).isVisible
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [.mint.opacity(selected ? 0.48 : 0.28),
                                                  .mint.opacity(selected ? 0.27 : 0.12)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.mint.opacity(selected ? 1 : isHovered ? 0.8 : 0.4),
                                      lineWidth: selected ? 2 : 1))
                    .contentShape(Rectangle())
                    .gesture(drag(.move))
                    .onTapGesture { model.selectCamera(id: section.id) }
                if proxy.size.width >= 60 {
                    HStack(spacing: 6) {
                        Image(systemName: visible ? "video.fill" : "video.slash")
                            .foregroundStyle(.mint)
                        if proxy.size.width >= 110 { Text("Camera \(number)").lineLimit(1) }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11, weight: .medium)).padding(.horizontal, 17)
                    .allowsHitTesting(false)
                }
                HStack(spacing: 0) {
                    handle.gesture(drag(.start))
                    Spacer(minLength: 0)
                    handle.gesture(drag(.end))
                }.padding(.horizontal, 2)
            }
            .opacity(visible ? 1 : 0.5)
            .onHover { isHovered = $0 }
            .help("Camera \(number) · Drag to move, or drag either edge to resize")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Camera \(number)")
            .accessibilityValue("\(section.startTime.formatted()) to \(section.endTime.formatted()) seconds")
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
            .accessibilityAction { model.selectCamera(id: section.id) }
            .contextMenu {
                Button("Edit camera section") { model.selectCamera(id: section.id) }
                Button("Split at playhead") {
                    model.selectCamera(id: section.id, seekToStart: false)
                    model.splitCameraSection()
                }.disabled(model.playheadTime - section.startTime < 0.1 || section.endTime - model.playheadTime < 0.1)
                Button("Delete camera section", role: .destructive) { model.deleteCameraSection(id: section.id) }
            }
        }
    }

    private var handle: some View {
        Capsule().fill(.primary.opacity(selected || isHovered ? 0.85 : 0.4))
            .frame(width: 3, height: 18).frame(width: 10, height: 42).contentShape(Rectangle())
    }

    private func drag(_ edge: EditorModel.CameraTimingEdit) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("camera-track"))
            .onChanged { value in
                if projection == nil {
                    model.player.pause()
                    model.beginHistoryTransaction(actionName: edge == .move ? "Move Camera Section" : "Resize Camera Section")
                    projection = TimelineDragProjection(initialTime: edge == .end ? section.endTime : section.startTime,
                                                        pointerStartX: value.startLocation.x, geometry: geometry)
                    model.selectCamera(id: section.id, seekToStart: false)
                }
                guard let projection else { return }
                model.updateCameraTiming(id: section.id, to: projection.time(atPointerX: value.location.x), edge: edge)
            }
            .onEnded { _ in
                projection = nil
                model.commitTimelineEdit()
            }
    }
}
