// DeciTests/Music/LyricsTitleCleanerTests.swift
// The small rules that turn a YouTube title and artist line into what LRCLIB indexes.

import Testing
@testable import Deci

@Suite("Lyrics title cleaner")
struct LyricsTitleCleanerTests {

    @Test(
        "Noise in brackets, parentheses and after a dash is dropped",
        arguments: [
            ("Test Song (feat. Guest Artist)", "Test Song"),
            ("Test Song (ft. Guest Artist)", "Test Song"),
            ("Test Song (Featuring Guest Artist)", "Test Song"),
            ("Test Song (Official Video)", "Test Song"),
            ("Test Song (Official Music Video)", "Test Song"),
            ("Test Song (Official Audio)", "Test Song"),
            ("Test Song (Lyric Video)", "Test Song"),
            ("Test Song (Lyrics)", "Test Song"),
            ("Test Song (Visualizer)", "Test Song"),
            ("Test Song (Remastered 2011)", "Test Song"),
            ("Test Song (2011 Remaster)", "Test Song"),
            ("Test Song (Explicit)", "Test Song"),
            ("Test Song (Radio Edit)", "Test Song"),
            ("Test Song (Acoustic Version)", "Test Song"),
            ("Test Song [Official Video]", "Test Song"),
            ("Test Song [Remastered]", "Test Song"),
            ("Test Song [anything at all]", "Test Song"),
            ("Test Song - Remastered 2011", "Test Song"),
            ("Test Song - 2011 Remaster", "Test Song"),
            ("Test Song - Radio Edit", "Test Song"),
            ("Test Song - Live at Some Hall", "Test Song"),
            ("Test Song feat. Guest Artist", "Test Song"),
            ("Test Song ft Guest Artist", "Test Song"),
            ("Test Song (feat. Guest) [Remastered]", "Test Song"),
            ("Test Song (Official Video) - Remastered 2011", "Test Song"),
        ]
    )
    func stripsNoise(input: String, expected: String) {
        #expect(LyricsTitleCleaner.cleanTitle(input) == expected)
    }

    @Test(
        "A real part of the title stays",
        arguments: [
            "(Test Words) Song",
            "Test Song - Part Two",
            "Test Song (Part Two)",
            "Test Song (Reprise)",
            "Test - Song",
            "Plain Title",
        ]
    )
    func keepsRealTitles(title: String) {
        #expect(LyricsTitleCleaner.cleanTitle(title) == title)
    }

    @Test("A title that is nothing but noise is returned as it was")
    func allNoiseFallsBack() {
        #expect(LyricsTitleCleaner.cleanTitle("(Official Video)") == "(Official Video)")
        #expect(LyricsTitleCleaner.cleanTitle("[Remastered]") == "[Remastered]")
    }

    @Test("Spacing is collapsed and trimmed")
    func spacing() {
        #expect(LyricsTitleCleaner.cleanTitle("  Test   Song   (Official Video)  ") == "Test Song")
        #expect(LyricsTitleCleaner.cleanTitle("") == "")
        #expect(LyricsTitleCleaner.cleanTitle("   ") == "")
    }

    @Test("Unicode titles are left alone")
    func unicode() {
        #expect(LyricsTitleCleaner.cleanTitle("Ça va 🎵 (Official Video)") == "Ça va 🎵")
    }

    @Test(
        "The first artist of a joined line",
        arguments: [
            ("Main Artist, Guest Artist", "Main Artist"),
            ("Main Artist & Guest Artist", "Main Artist"),
            ("Main Artist feat. Guest Artist", "Main Artist"),
            ("Main Artist ft. Guest Artist", "Main Artist"),
            ("Main Artist x Guest Artist", "Main Artist"),
            ("Main Artist", "Main Artist"),
            ("  Main Artist  ", "Main Artist"),
            ("", ""),
        ]
    )
    func firstArtist(input: String, expected: String) {
        #expect(LyricsTitleCleaner.firstArtist(input) == expected)
    }

    @Test("Names with 'x' inside a word are not split")
    func artistWithX() {
        #expect(LyricsTitleCleaner.firstArtist("Lexx Band") == "Lexx Band")
    }
}
