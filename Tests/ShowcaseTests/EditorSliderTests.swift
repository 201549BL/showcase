import Foundation
import Testing
@testable import Showcase

@Suite("Editor value fields")
struct EditorSliderTests {
    @Test("Values use display units, locale decimals, and bounded finite input")
    func valueParsing() {
        let norwegian = Locale(identifier: "nb_NO")
        #expect(EditorSlider.Unit.percent.value(from: "140", range: 0.75...2.5) == 1.4)
        #expect(EditorSlider.Unit.percent.value(from: "22", range: 0.12...0.4) == 0.22)
        #expect(EditorSlider.Unit.seconds.value(from: "0,55", range: 0.2...1.2, locale: norwegian) == 0.55)
        #expect(EditorSlider.Unit.pixels.value(from: "999", range: 0...160) == 160)
        #expect(EditorSlider.Unit.pixels.value(from: "-10", range: 0...160) == 0)
        #expect(EditorSlider.Unit.seconds.value(from: "NaN", range: 0...1) == nil)
        #expect(EditorSlider.Unit.seconds.value(from: "inf", range: 0...1) == nil)
        #expect(EditorSlider.Unit.seconds.value(from: "2abc", range: 0...1) == nil)
        #expect(EditorSlider.Unit.seconds.value(from: "", range: 0...1) == nil)
    }
}
