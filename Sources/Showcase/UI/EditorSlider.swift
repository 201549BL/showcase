import SwiftUI

/// A shared slider with a precise, locale-aware value field. Text changes are
/// committed together on Return or focus loss, just like one slider drag.
struct EditorSlider: View {
    enum Unit {
        case pixels, percent, seconds, magnification

        var suffix: String {
            switch self {
            case .pixels: return "px"
            case .percent: return "%"
            case .seconds: return "s"
            case .magnification: return "×"
            }
        }
        var factor: Double { self == .percent ? 100 : 1 }
        var fractionDigits: Int { self == .pixels || self == .percent ? 0 : 2 }

        func text(for value: Double) -> String {
            (value * factor).formatted(.number.precision(.fractionLength(0...fractionDigits)))
        }

        func value(from text: String, range: ClosedRange<Double>, locale: Locale = .current) -> Double? {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
            guard let number = Double(normalized), number.isFinite else { return nil }
            return min(range.upperBound, max(range.lowerBound, number / factor))
        }
    }

    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: Unit
    let beginEditing: () -> Void
    let endEditing: () -> Void
    @State private var draft = ""
    @FocusState private var editingValue: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(title).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    TextField(title, text: $draft)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                        .focused($editingValue)
                        .onSubmit { commitValue(); editingValue = false }
                        .accessibilityLabel("\(title) value in \(unit.suffix)")
                    Text(unit.suffix).foregroundStyle(.secondary)
                }
                .font(.callout.monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.primary.opacity(editingValue ? 0.1 : 0.035), in: RoundedRectangle(cornerRadius: 5))
            }
            Slider(value: $value, in: range) { editing in
                if editing { beginEditing() }
                else { endEditing() }
            }
            .accessibilityLabel(title)
        }
        .onAppear { draft = unit.text(for: value) }
        .onChange(of: value) { if !editingValue { draft = unit.text(for: value) } }
        .onChange(of: editingValue) { if !editingValue { commitValue() } }
        .onDisappear { if editingValue { commitValue() } }
    }

    private func commitValue() {
        if let newValue = unit.value(from: draft, range: range),
           draft != unit.text(for: value), newValue != value {
            beginEditing()
            value = newValue
            endEditing()
        }
        draft = unit.text(for: value)
    }
}
