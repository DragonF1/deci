// DeciTests/Music/MusicMixMenuTests.swift
// Tier 2b P4: the two no-mix menu entries. Their words, their list per state (a row has one, the playing song has two
// when a song came before it), and the service helpers that build the list and flip the flags.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicMixMenu")
struct MusicMixMenuTests {
    @Test("the four titles")
    func titles() {
        #expect(MusicMixMenuItem.startClean(on: false).title == "Always start clean")
        #expect(MusicMixMenuItem.startClean(on: true).title == "Allow mixing into this song")
        #expect(MusicMixMenuItem.cleanAfterPrevious(on: false).title == "Start clean after the previous song")
        #expect(MusicMixMenuItem.cleanAfterPrevious(on: true).title == "Allow mixing after the previous song")
    }

    @Test("no title has an em-dash")
    func noEmDash() {
        for item in [
            MusicMixMenuItem.startClean(on: false), .startClean(on: true),
            .cleanAfterPrevious(on: false), .cleanAfterPrevious(on: true),
        ] {
            #expect(!item.title.contains("\u{2014}"))
        }
    }

    @Test("a row offers the song's entry only, worded for its flag")
    func rowItems() {
        #expect(MusicMixMenuItem.items(startsClean: false, pairIsClean: nil) == [.startClean(on: false)])
        #expect(MusicMixMenuItem.items(startsClean: true, pairIsClean: nil) == [.startClean(on: true)])
    }

    @Test("the playing song with a song before it offers both entries")
    func nowPlayingItems() {
        #expect(
            MusicMixMenuItem.items(startsClean: false, pairIsClean: false)
                == [.startClean(on: false), .cleanAfterPrevious(on: false)]
        )
        #expect(
            MusicMixMenuItem.items(startsClean: true, pairIsClean: true)
                == [.startClean(on: true), .cleanAfterPrevious(on: true)]
        )
    }

    @Test("the handler's mix members default to nothing, so an existing handler is unchanged")
    func handlerDefaults() {
        let handler = MusicTrackMenuHandler(actions: { _, _ in [] }, perform: { _, _, _ in }, isPinned: { _ in false })
        let track = MusicSamples.track("a")
        #expect(handler.mixItems(track, .none).isEmpty)
        handler.performMix(.startClean(on: false), track)
    }
}
