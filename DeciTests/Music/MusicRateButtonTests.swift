// DeciTests/Music/MusicRateButtonTests.swift
// The Like and Dislike icons of the Now playing hover card: which glyph, brightness and words each shows for the song's
// state, and the measures that keep them inside the title row. Pure values.

import Foundation
import Testing
@testable import Deci

@Suite("Music rate buttons")
struct MusicRateButtonTests {
    private let statuses: [MusicLikeStatus?] = [nil, .indifferent, .like, .dislike]

    @Test("Like is filled and full white only on a liked song")
    func likeActive() {
        for status in statuses {
            let look = MusicRateButtonLook(kind: .like, status: status)
            let liked = status == .like
            #expect(look.isActive == liked)
            #expect(look.symbolName == (liked ? "hand.thumbsup.fill" : "hand.thumbsup"))
            #expect(look.glyphOpacity == (liked ? 1 : 0.6))
        }
    }

    @Test("Dislike is filled and full white only on a disliked song")
    func dislikeActive() {
        for status in statuses {
            let look = MusicRateButtonLook(kind: .dislike, status: status)
            let disliked = status == .dislike
            #expect(look.isActive == disliked)
            #expect(look.symbolName == (disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
            #expect(look.glyphOpacity == (disliked ? 1 : 0.6))
        }
    }

    @Test("A song neither liked nor disliked, or not known yet, shows both outlined")
    func neitherActive() {
        for status in [nil, .indifferent] as [MusicLikeStatus?] {
            #expect(!MusicRateButtonLook(kind: .like, status: status).isActive)
            #expect(!MusicRateButtonLook(kind: .dislike, status: status).isActive)
        }
    }

    @Test("The help and the accessibility label are the action, and only an active button is selected")
    func words() {
        let like = MusicRateButtonLook(kind: .like, status: .like)
        let dislike = MusicRateButtonLook(kind: .dislike, status: .like)
        #expect(like.title == "Like")
        #expect(dislike.title == "Dislike")
        #expect(like.isSelected)
        #expect(!dislike.isSelected)
    }

    @Test("The icons are about 12 pt in a 22 by 18 hit area with 2 to 4 pt between them, so the title row keeps its height")
    func measures() {
        let m = MusicHoverCardMetrics.self
        #expect(m.rateGlyphSize == 12)
        #expect(m.rateButtonWidth == 22)
        #expect(m.rateButtonHeight == 18)
        #expect(m.rateButtonHeight <= m.titleRowHeight)
        #expect((2...4).contains(m.rateButtonSpacing))
        #expect(m.titleRowHeight == 18)
    }
}
