// Deci/Views/Music/MusicHighlightedText.swift
import SwiftUI

private struct MusicHighlightTermsKey: EnvironmentKey {
    static let defaultValue: [String] = []
}

extension EnvironmentValues {
    /// The words a screen's filter field holds, for the rows under it to tint where they match. Empty everywhere else,
    /// and then every row draws its plain text.
    var musicHighlightTerms: [String] {
        get { self[MusicHighlightTermsKey.self] }
        set { self[MusicHighlightTermsKey.self] = newValue }
    }
}

extension Text {
    /// `string` with every place `terms` match (case and diacritics aside) in `color`. With no terms, or no match, it is
    /// the plain text. The caller's own `foregroundStyle` still colours the rest.
    static func highlighted(_ string: String, terms: [String], color: Color) -> Text {
        guard !terms.isEmpty else { return Text(verbatim: string) }
        let ranges = MusicLocalSearch.highlights(in: string, terms: terms)
        guard !ranges.isEmpty else { return Text(verbatim: string) }
        var attributed = AttributedString(string)
        for range in ranges {
            guard let target = Range(range, in: attributed) else { continue }
            attributed[target].foregroundColor = color
        }
        return Text(attributed)
    }
}
