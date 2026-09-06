import SwiftUI

struct CameraEmphasisTimelineView: View {
    @ObservedObject var model: EditorModel
    let geometry: TimelineGeometry

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.025))
                .contentShape(Rectangle())
                .onTapGesture { location in model.seek(to: geometry.time(for: location.x)) }
            ForEach(Array(model.project.cameraTimelineEmphases.enumerated()), id: \.element.id) { index, effect in
                CameraEmphasisBlock(model: model, effect: effect, geometry: geometry, number: index + 1)
                    .frame(width: max(24, geometry.width(from: effect.startTime, to: effect.endTime)), height: 36)
                    .offset(x: geometry.x(for: effect.startTime))
                    .zIndex(model.selectedCameraEmphasisID == effect.id ? 3 : 1)
            }
            HStack(spacing: 0) {
                Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.75))
                    .frame(width: geometry.x(for: model.trimStart))
                Spacer(minLength: 0)
                Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.75))
                    .frame(width: max(0, geometry.width - geometry.x(for: model.trimEnd)))
            }.allowsHitTesting(false).zIndex(4)
        }
        .frame(height: 36).coordinateSpace(name: "camera-effects-track")
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Add camera effect", action: model.addCameraEmphasis).disabled(!model.canAddCameraEmphasis)
        }
    }
}

private struct CameraEmphasisBlock: View {
    @ObservedObject var model: EditorModel
    let effect: CameraEmphasis
    let geometry: TimelineGeometry
    let number: Int
    @State private var projection: TimelineDragProjection?
    @State private var hovered = false
    private var selected: Bool { model.selectedCameraEmphasisID == effect.id }
    private var tint: Color { .purple }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [tint.opacity(selected ? 0.4 : 0.25), tint.opacity(0.12)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(tint.opacity(selected ? 1 : 0.4), lineWidth: selected ? 2 : 1))
                    .contentShape(Rectangle())
                    .gesture(drag(.move))
                    .onTapGesture { model.selectCameraEmphasis(id: effect.id) }
                if proxy.size.width >= 65 {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").foregroundStyle(tint)
                        if proxy.size.width >= 145 { Text("Effect \(number)").lineLimit(1) }
                        Spacer(minLength: 0)
                        Text(effect.targetSize.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit().fixedSize()
                    }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 15)
                        .allowsHitTesting(false)
                }
                HStack(spacing: 0) {
                    handle.gesture(drag(.start))
                    Spacer(minLength: 0)
                    handle.gesture(drag(.end))
                }.padding(.horizontal, 2)
            }
            .onHover { hovered = $0 }
            .help("Camera effect \(number) · Drag to move, or drag either edge to resize")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Camera effect \(number)")
            .accessibilityValue("\(effect.startTime.formatted()) to \(effect.endTime.formatted()) seconds, size \(effect.targetSize.formatted(.percent))")
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
            .accessibilityAction { model.selectCameraEmphasis(id: effect.id) }
            .contextMenu {
                Button("Edit camera effect") { model.selectCameraEmphasis(id: effect.id) }
                Button("Remove camera effect", role: .destructive) { model.deleteCameraEmphasis(id: effect.id) }
            }
        }
    }

    private var handle: some View {
        Capsule().fill(.primary.opacity(selected || hovered ? 0.85 : 0.4))
            .frame(width: 3, height: 16).frame(width: 10, height: 36).contentShape(Rectangle())
    }

    private func drag(_ edge: EditorModel.CameraTimingEdit) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("camera-effects-track"))
            .onChanged { value in
                if projection == nil {
                    model.beginHistoryTransaction(actionName: edge == .move ? "Move Camera Effect" : "Resize Camera Effect")
                    projection = TimelineDragProjection(initialTime: edge == .end ? effect.endTime : effect.startTime,
                                                        pointerStartX: value.startLocation.x, geometry: geometry)
                    model.selectCameraEmphasis(id: effect.id, seekToPeak: false)
                }
                guard let projection else { return }
                model.updateCameraEmphasisTiming(id: effect.id, to: projection.time(atPointerX: value.location.x), edge: edge)
            }
            .onEnded { _ in
                projection = nil
                model.commitTimelineEdit()
            }
    }
}
