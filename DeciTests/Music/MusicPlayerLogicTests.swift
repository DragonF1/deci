// DeciTests/Music/MusicPlayerLogicTests.swift
// The rules of the player screens kept apart from the views: how dark the cover's backdrop is on each screen, what the
// output control says, what the Up next list shows and where it comes from, what the lyrics caption reads, and where
// the slider's knob sits.

import SwiftUI
import Testing

@testable import Deci

@MainActor
@Suite("MusicPlayerDim")
struct MusicPlayerDimTests {
    @Test("every screen darkens more toward the bottom, so the controls stay readable over any cover")
    func darkensDownward() {
        for screen in [MusicShellScreen.browse, .nowPlaying, .lyrics, .queue] {
            let stops = MusicPlayerDim.stops(for: screen)
            #expect(stops.top < stops.middle)
            #expect(stops.middle < stops.bottom)
            #expect(stops.bottom <= 1)
        }
    }

    @Test("Lyrics and Up next sit behind text, so they are darker than Now Playing at every height")
    func textScreensAreDarker() {
        let art = MusicPlayerDim.stops(for: .nowPlaying)
        for screen in [MusicShellScreen.lyrics, .queue] {
            let text = MusicPlayerDim.stops(for: screen)
            #expect(text.top > art.top)
            #expect(text.middle > art.middle)
            #expect(text.bottom > art.bottom)
        }
        #expect(MusicPlayerDim.stops(for: .lyrics) == MusicPlayerDim.stops(for: .queue))
    }
}

@MainActor
@Suite("MusicOutputLabel")
struct MusicOutputLabelTests {
    @Test("a device with an EQ profile reads 'device · profile'")
    func deviceAndProfile() {
        #expect(MusicOutputLabel.text(deviceName: "Desk Speakers", profileName: "Flat Studio") == "Desk Speakers \u{00B7} Flat Studio")
    }

    @Test("a device without a profile reads as its name alone")
    func deviceOnly() {
        #expect(MusicOutputLabel.text(deviceName: "Desk Speakers", profileName: nil) == "Desk Speakers")
        #expect(MusicOutputLabel.text(deviceName: "Desk Speakers", profileName: "  ") == "Desk Speakers")
    }

    @Test("no known device reads as the default output, and a profile alone is not shown without its device")
    func unknownDevice() {
        #expect(MusicOutputLabel.text(deviceName: nil, profileName: nil) == "Default output")
        #expect(MusicOutputLabel.text(deviceName: "", profileName: "Flat Studio") == "Default output")
        #expect(MusicOutputLabel.text(deviceName: "   ", profileName: nil) == "Default output")
    }

    @Test("names are trimmed")
    func trimmed() {
        #expect(MusicOutputLabel.text(deviceName: "  Desk Speakers\n", profileName: " Flat Studio ") == "Desk Speakers \u{00B7} Flat Studio")
    }
}

@MainActor
@Suite("MusicQueueListing")
struct MusicQueueListingTests {
    private func ids(_ tracks: [MusicTrack]) -> [String] { tracks.map(\.videoId) }

    @Test("an empty queue lists nothing")
    func empty() {
        let listing = MusicQueueListing(queue: MusicQueue())
        #expect(listing.current == nil)
        #expect(listing.upcoming.isEmpty)
        #expect(listing.sourceLine == nil)
    }

    @Test("a page started from a middle row lists that row as playing and only the rows after it as up next")
    func pageFromTheMiddle() {
        var queue = MusicQueue()
        let tracks = ["a", "b", "c", "d", "e"].map { MusicSamples.track($0) }
        queue.start(page: tracks, playing: tracks[2], browseId: "VLPLsample", continuation: nil)
        let listing = MusicQueueListing(queue: queue)
        #expect(listing.current?.videoId == "c")
        #expect(ids(listing.upcoming) == ["d", "e"])
    }

    @Test("the last song of a queue has nothing up next")
    func lastSong() {
        var queue = MusicQueue()
        queue.start(with: MusicSamples.track("a"))
        let listing = MusicQueueListing(queue: queue)
        #expect(listing.current?.videoId == "a")
        #expect(listing.upcoming.isEmpty)
    }

    @Test("a radio queue says it comes from the radio")
    func radioSource() {
        var queue = MusicQueue()
        queue.start(with: MusicSamples.track("a"))
        #expect(MusicQueueListing(queue: queue).sourceLine == "From radio")
    }

    @Test("a page queue names what kind of page it came from when the id says so")
    func pageSources() {
        func line(_ browseId: String) -> String? {
            var queue = MusicQueue()
            let track = MusicSamples.track("a")
            queue.start(page: [track], playing: track, browseId: browseId, continuation: nil)
            return MusicQueueListing(queue: queue).sourceLine
        }
        #expect(line("MPREb_sample") == "From album")
        #expect(line("VLLM") == "From Liked music")
        #expect(line("VLPLsample") == "From playlist")
        #expect(line("PLsample") == "From playlist")
        #expect(line("UCsample") == "From playlist or album")
    }
}

@MainActor
@Suite("MusicLyricsCaption")
struct MusicLyricsCaptionTests {
    @Test("plain lyrics are captioned 'Not synced' and every other state 'Lyrics'")
    func caption() {
        #expect(MusicLyricsCaption.text(for: .loaded(.plain("words"))) == "Not synced")
        #expect(MusicLyricsCaption.text(for: .loaded(.synced([]))) == "Lyrics")
        #expect(MusicLyricsCaption.text(for: .loaded(.instrumental)) == "Lyrics")
        #expect(MusicLyricsCaption.text(for: .loaded(.notFound)) == "Lyrics")
        #expect(MusicLyricsCaption.text(for: .idle) == "Lyrics")
        #expect(MusicLyricsCaption.text(for: .loading) == "Lyrics")
        #expect(MusicLyricsCaption.text(for: .failed("x", retryAfter: nil)) == "Lyrics")
    }
}

@MainActor
@Suite("MusicSliderGeometry")
struct MusicSliderGeometryTests {
    @Test("the knob's centre runs from half a knob in to half a knob short of the end, so it never leaves the track")
    func knobStaysInside() {
        #expect(MusicSliderGeometry.knobOffset(fraction: 0, width: 200, knob: 10) == 0)
        #expect(MusicSliderGeometry.knobOffset(fraction: 1, width: 200, knob: 10) == 190)
        #expect(MusicSliderGeometry.knobOffset(fraction: 0.5, width: 200, knob: 10) == 95)
    }

    @Test("a fraction outside 0...1 or not a number is held inside the track")
    func fractionIsContained() {
        #expect(MusicSliderGeometry.knobOffset(fraction: -3, width: 200, knob: 10) == 0)
        #expect(MusicSliderGeometry.knobOffset(fraction: 9, width: 200, knob: 10) == 190)
        #expect(MusicSliderGeometry.knobOffset(fraction: .nan, width: 200, knob: 10) == 0)
    }

    @Test("a track narrower than the knob keeps the knob at the start")
    func narrowTrack() {
        #expect(MusicSliderGeometry.knobOffset(fraction: 1, width: 4, knob: 10) == 0)
        #expect(MusicSliderGeometry.knobOffset(fraction: 1, width: .nan, knob: 10) == 0)
    }

    @Test("the filled part is the fraction of the width, held inside it")
    func filledWidth() {
        #expect(MusicSliderGeometry.filledWidth(fraction: 0.25, width: 200) == 50)
        #expect(MusicSliderGeometry.filledWidth(fraction: 2, width: 200) == 200)
        #expect(MusicSliderGeometry.filledWidth(fraction: -1, width: 200) == 0)
        #expect(MusicSliderGeometry.filledWidth(fraction: .nan, width: 200) == 0)
        #expect(MusicSliderGeometry.filledWidth(fraction: 0.5, width: .infinity) == 0)
    }
}
