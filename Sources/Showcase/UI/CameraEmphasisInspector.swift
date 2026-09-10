import SwiftUI

struct CameraEmphasisInspector: View {
    @ObservedObject var model: EditorModel
    let effect: CameraEmphasis

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Camera effect", systemImage: "sparkles").font(.title3.weight(.semibold))
            Text("Changes the camera size. Touching effects blend directly into each other; gaps return to normal.")
                .font(.caption).foregroundStyle(.secondary)
            EditorSlider(title: "Camera size", value: binding(\.targetSize, range: 0.12...0.6),
                         range: 0.12...0.6, unit: .percent,
                         beginEditing: { model.beginHistoryTransaction(actionName: "Change Camera Effect Size") },
                         endEditing: model.commitHistoryTransaction)
            EditorSlider(title: "Transition", value: binding(\.transitionDuration, range: 0.1...1),
                         range: 0.1...1, unit: .seconds,
                         beginEditing: { model.beginHistoryTransaction(actionName: "Change Camera Effect Transition") },
                         endEditing: model.commitHistoryTransaction)
            Divider()
            HStack(spacing: 12) {
                timeField("Start", edge: .start)
                timeField("End", edge: .end)
            }
            Button(role: .destructive) { model.deleteCameraEmphasis(id: effect.id) } label: {
                Label("Delete effect", systemImage: "trash")
            }.buttonStyle(.borderless)
        }
    }

    private var current: CameraEmphasis {
        model.project.cameraTimelineEmphases.first { $0.id == effect.id } ?? effect
    }

    private func binding(_ keyPath: WritableKeyPath<CameraEmphasis, Double>, range: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: { current[keyPath: keyPath] }, set: { value in
            guard value.isFinite else { return }
            model.editCameraEmphasis(id: effect.id, actionName: "Change Camera Effect") {
                $0[keyPath: keyPath] = min(range.upperBound, max(range.lowerBound, value))
            }
        })
    }

    private func timeField(_ title: String, edge: EditorModel.CameraTimingEdit) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: {
                edge == .start ? current.startTime : current.endTime
            }, set: { value in
                guard value.isFinite else { return }
                model.beginHistoryTransaction(actionName: "Resize Camera Effect")
                model.updateCameraEmphasisTiming(id: effect.id, to: value, edge: edge)
                model.commitTimelineEdit()
            }), format: .number.precision(.fractionLength(1)))
            .textFieldStyle(.roundedBorder).monospacedDigit()
            .accessibilityLabel("Camera effect \(title.lowercased()) in seconds")
        }
    }
}
