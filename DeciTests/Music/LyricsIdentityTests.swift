// DeciTests/Music/LyricsIdentityTests.swift
// Does a search hit describe the song that was asked for? Made-up titles and artists only.

import Foundation
import Testing
@testable import Deci

@Suite("Lyrics identity")
struct LyricsIdentityTests {

    private func matches(
        _ recordTitle: String?, _ recordArtist: String?, title: String = "Test Song", artist: String = "Test Artist"
    ) -> Bool {
        LyricsIdentity.matches(recordTitle: recordTitle, recordArtist: recordArtist, title: title, artist: artist)
    }

    // MARK: - Title

    @Test("The same title and artist match")
    func exact() {
        #expect(matches("Test Song", "Test Artist"))
    }

    @Test("Case and diacritics do not matter")
    func folding() {
        #expect(matches("TEST SONG", "test artist"))
        #expect(matches("Café Song", "Test Artist", title: "Cafe Song"))
        #expect(matches("Cafe Song", "Test Artist", title: "CAFÉ SONG"))
        #expect(matches("Test Song", "Zoë Artist", artist: "Zoe Artist"))
    }

    @Test("A record that only adds packaging to the title still matches")
    func recordAddsPackaging() {
        #expect(matches("Test Song (Remastered 2011)", "Test Artist"))
        #expect(matches("Test Song - Remastered 2011", "Test Artist"))
        #expect(matches("Test Song [Live]", "Test Artist"))
        #expect(matches("Test Song (feat. Guest Person)", "Test Artist"))
    }

    @Test("A query that carries packaging the record lacks still matches")
    func queryAddsPackaging() {
        #expect(matches("Test Song", "Test Artist", title: "Test Song (Official Video)"))
        #expect(matches("Test Song", "Test Artist", title: "Test Song (feat. Guest Person) [Remastered]"))
        #expect(matches("Test Song", "Test Artist", title: "Test Song - Radio Edit"))
    }

    @Test("A different song does not match, even by the same artist")
    func differentTitle() {
        #expect(!matches("Another Song", "Test Artist"))
        #expect(!matches("Completely Unrelated", "Test Artist"))
    }

    @Test("A title that merely starts the same way is a different song")
    func wordBoundary() {
        #expect(!matches("Stayin Alive", "Test Artist", title: "Stay"))
        #expect(!matches("Stay", "Test Artist", title: "Stayin Alive"))
        #expect(matches("Stay (Remastered 2011)", "Test Artist", title: "Stay"))
    }

    @Test("A generic title by another artist does not match")
    func genericTitleOtherArtist() {
        #expect(!matches("Stay", "Somebody Else", title: "Stay"))
        #expect(!matches("Intro", "Somebody Else", title: "Intro", artist: "Test Artist"))
    }

    @Test("Apostrophes, ampersands and punctuation are not part of the comparison")
    func punctuation() {
        #expect(matches("Don't Stop Me", "Test Artist", title: "Dont Stop Me"))
        #expect(matches("Don\u{2019}t Stop Me", "Test Artist", title: "Don't Stop Me"))
        #expect(matches("Rock and Roll", "Test Artist", title: "Rock & Roll"))
        #expect(matches("Rock & Roll", "Test Artist", title: "Rock and Roll"))
        #expect(matches("Test - Song!", "Test Artist", title: "Test Song"))
    }

    // MARK: - Artist

    @Test("The record artist may list more names than the first queried one")
    func recordArtistContainsFirst() {
        #expect(matches("Test Song", "Test Artist & Friend"))
        #expect(matches("Test Song", "Test Artist feat. Friend"))
        #expect(matches("Test Song", "Friend, Test Artist"))
    }

    @Test("Only the first queried artist is compared")
    func queryArtistListUsesTheFirst() {
        #expect(matches("Test Song", "Test Artist", artist: "Test Artist, Friend"))
        #expect(matches("Test Song", "Test Artist", artist: "Test Artist & Friend"))
        #expect(matches("Test Song", "Test Artist", artist: "Test Artist feat. Friend"))
        #expect(!matches("Test Song", "Friend", artist: "Test Artist, Friend"))
    }

    @Test("The first queried artist may contain the record artist")
    func firstContainsRecordArtist() {
        #expect(matches("Test Song", "Test", artist: "Test Artist"))
    }

    @Test("Another artist does not match")
    func differentArtist() {
        #expect(!matches("Test Song", "Somebody Else"))
        #expect(!matches("Test Song", "Testing Arts"))
    }

    @Test("A blank queried artist puts no condition on the artist")
    func blankQueriedArtist() {
        #expect(matches("Test Song", "Anyone At All", artist: ""))
        #expect(matches("Test Song", "Anyone At All", artist: "   "))
    }

    // MARK: - Odd input

    @Test("A record with no title or no artist cannot be checked and does not match")
    func missingFields() {
        #expect(!matches(nil, "Test Artist"))
        #expect(!matches("Test Song", nil))
        #expect(!matches("", "Test Artist"))
        #expect(!matches("Test Song", ""))
    }

    @Test("Titles in other scripts and emoji compare as they are")
    func unicode() {
        #expect(matches("\u{591C}\u{306B}\u{99C6}\u{3051}\u{308B}", "Test Artist", title: "\u{591C}\u{306B}\u{99C6}\u{3051}\u{308B}"))
        #expect(!matches("\u{591C}\u{306B}", "Test Artist", title: "\u{591C}\u{306B}\u{99C6}\u{3051}\u{308B}"))
        #expect(matches("\u{1F3B5}", "Test Artist", title: "\u{1F3B5}"))
        #expect(!matches("\u{1F3B6}", "Test Artist", title: "\u{1F3B5}"))
    }

    @Test("A title with nothing to compare never matches everything")
    func emptyAfterFolding() {
        #expect(!matches("Test Song", "Test Artist", title: "???"))
        #expect(matches("???", "Test Artist", title: "???"))
    }
}
