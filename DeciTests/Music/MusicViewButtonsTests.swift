// DeciTests/Music/MusicViewButtonsTests.swift
// The three words under the player column's transport (Lyrics, Related, Up next): their order and titles, when each is
// pressable, and the check that the three fit the 142 pt row in the column's label font with room between them. The
// words are measured offscreen as attributed strings; nothing is drawn.

import AppKit
import SwiftUI
import Testing
@testable import Deci

@MainActor
@Suite("MusicViewButtons")
struct MusicViewButtonsTests {
    /// The width of a word in the font the column draws its labels in: `MusicStyle.Typeface.columnLabel`, with its
    /// tracking.
    private func width(of title: String) -> CGFloat {
        let style = MusicStyle.Typeface.columnLabel
        let attributes: [NSAttributedString.Key: Any] = [.font: style.measuringFont, .kern: style.appliedTracking]
        return NSAttributedString(string: title, attributes: attributes).size().width
    }

    private var titles: [String] { MusicViewButtons.Kind.allCases.map(\.title) }

    // MARK: - Words

    @Test("the buttons read Lyrics, Related, Up next, in that order")
    func titlesInOrder() {
        #expect(titles == ["Lyrics", "Related", "Up next"])
        #expect(MusicViewButtons.Kind.allCases == [.lyrics, .related, .queue])
    }

    @Test("the label font these words are measured in is the column's own: 10 pt medium, no tracking")
    func measuredFontIsTheColumnsFont() {
        let style = MusicStyle.Typeface.columnLabel
        #expect(style.size == 10)
        #expect(style.weight == .medium)
        #expect(style.appliedTracking == 0)
        #expect(style.mono == false)
        #expect(style.measuringFont == NSFont.systemFont(ofSize: 10, weight: .medium))
    }

    // MARK: - Fit

    @Test("the three words fit the 142 pt row with at least 8 pt between neighbours")
    func fitsWithRoomBetween() {
        let widths = titles.map(width(of:))
        let gap = MusicViewButtons.gap(labelWidths: widths)

        #expect(MusicPopupMetrics.playerColumnContentWidth == 142)
        #expect(widths.allSatisfy { $0 > 0 })
        #expect(widths.reduce(0, +) < MusicPopupMetrics.playerColumnContentWidth)
        #expect(gap >= MusicViewButtons.minGap)
    }

    @Test("the least gap is 8 pt")
    func minimumGap() {
        #expect(MusicViewButtons.minGap == 8)
    }

    @Test("a longer word for Related would not fit, so the check can fail")
    func checkCanFail() {
        let widths = [width(of: "Lyrics"), width(of: "Related songs about this one"), width(of: "Up next")]
        #expect(MusicViewButtons.gap(labelWidths: widths) < MusicViewButtons.minGap)
    }

    // MARK: - Gap rule

    @Test("the spare width is shared equally by the spaces between the words")
    func gapIsEqualShare() {
        #expect(MusicViewButtons.gap(labelWidths: [30, 40, 32], rowWidth: 142) == 20)
        #expect(MusicViewButtons.gap(labelWidths: [10, 10], rowWidth: 100) == 80)
    }

    @Test("words wider than the row leave a negative gap")
    func overfullRowIsNegative() {
        #expect(MusicViewButtons.gap(labelWidths: [60, 60, 60], rowWidth: 142) < 0)
    }

    @Test("fewer than two words, or a row without a finite width, leave no gap to speak of")
    func degenerateInput() {
        #expect(MusicViewButtons.gap(labelWidths: []) == 0)
        #expect(MusicViewButtons.gap(labelWidths: [40]) == 0)
        #expect(MusicViewButtons.gap(labelWidths: [10, 10, 10], rowWidth: .infinity) == 0)
        #expect(MusicViewButtons.gap(labelWidths: [10, 10, 10], rowWidth: .nan) == 0)
    }

    // MARK: - Availability

    private func available(
        _ kind: MusicViewButtons.Kind,
        enabled: Bool = true, lyrics: Bool = false, song: Bool = false, queue: Bool = false, relatedOpen: Bool = false
    ) -> Bool {
        MusicViewButtons.isAvailable(
            kind, controlsAreEnabled: enabled, hasLyrics: lyrics, hasSong: song, hasQueue: queue,
            relatedIsOpen: relatedOpen
        )
    }

    @Test("Lyrics needs lyrics, Related a song, Up next a queue; each ignores the others")
    func availability() {
        #expect(available(.lyrics, lyrics: true))
        #expect(!available(.lyrics, song: true, queue: true))

        #expect(available(.related, song: true))
        #expect(!available(.related, lyrics: true, queue: true))

        #expect(available(.queue, queue: true))
        #expect(!available(.queue, lyrics: true, song: true))
    }

    @Test("with nothing at all every button is unavailable")
    func nothingAvailable() {
        for kind in MusicViewButtons.Kind.allCases {
            #expect(!available(kind))
        }
    }

    @Test("an open Related panel keeps its button available with no song, so the button can close it")
    func openRelatedStaysAvailable() {
        #expect(available(.related, relatedOpen: true))
        #expect(available(.related, song: true, relatedOpen: true))
        // Open or not, it is only Related that gets this: the other panels close when their content goes.
        #expect(!available(.lyrics, relatedOpen: true))
        #expect(!available(.queue, relatedOpen: true))
    }

    @Test("with the controls switched off (nothing plays, signed out) only an open Related stays available")
    func switchedOffControls() {
        #expect(!available(.lyrics, enabled: false, lyrics: true))
        #expect(!available(.related, enabled: false, song: true))
        #expect(!available(.queue, enabled: false, queue: true))
        #expect(available(.related, enabled: false, relatedOpen: true))
        #expect(available(.related, enabled: false, song: true, relatedOpen: true))
    }
}

extension MusicStyle.TextStyle {
    /// The AppKit font of this style, for measuring a word offscreen.
    @MainActor
    fileprivate var measuringFont: NSFont {
        let weights: [(Font.Weight, NSFont.Weight)] = [
            (.ultraLight, .ultraLight), (.thin, .thin), (.light, .light), (.regular, .regular), (.medium, .medium),
            (.semibold, .semibold), (.bold, .bold), (.heavy, .heavy), (.black, .black),
        ]
        let appKitWeight = weights.first { $0.0 == weight }?.1 ?? .regular
        return NSFont.systemFont(ofSize: size, weight: appKitWeight)
    }
}
