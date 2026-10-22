// DeciTests/Music/MusicPlayerLogicTests.swift
// The rules of the player column and the panels beside it kept apart from the views: what the output control says, what
// the Up next list shows and where it comes from, what the Up next header and the lyrics header and foot read, and
// where the slider's knob sits.

import SwiftUI
import Testing

@testable import Deci

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

    @Test("a shuffled page lists every other song of the page, in the shuffled order")
    func shuffledPage() {
        var queue = MusicQueue()
        let tracks = ["a", "b", "c", "d", "e"].map { MusicSamples.track($0) }
        queue.start(page: tracks, playing: tracks[2], browseId: "VLPLsample", continuation: nil)
        var generator = MusicShuffleGenerator(seed: 5)
        queue.shuffle(mixingEarlier: true, using: &generator)
        let listing = MusicQueueListing(queue: queue)
        #expect(listing.current?.videoId == "c")
        #expect(ids(listing.upcoming) == ids(Array(queue.tracks.dropFirst())))
        #expect(Set(ids(listing.upcoming)) == ["a", "b", "d", "e"])
    }

    @Test("under Loop playlist the next lap follows: the songs before the current one, from the start")
    func nextLap() {
        var queue = MusicQueue()
        let tracks = ["a", "b", "c", "d", "e"].map { MusicSamples.track($0) }
        queue.start(page: tracks, playing: tracks[2], browseId: "VLPLsample", continuation: nil)
        #expect(ids(MusicQueueListing(queue: queue, listsNextLap: true).upcoming) == ["d", "e", "a", "b"])
        var single = MusicQueue()
        single.start(page: [tracks[0]], playing: tracks[0], browseId: "VLPLsample", continuation: nil)
        #expect(ids(MusicQueueListing(queue: single, listsNextLap: true).upcoming) == ["a"])
    }

    @Test("with Autoplay the staged radio follows the page; without it, or on a radio, nothing is added")
    func autoplayRows() {
        var queue = MusicQueue()
        let tracks = ["a", "b", "c"].map { MusicSamples.track($0) }
        queue.start(page: tracks, playing: tracks[1], browseId: "VLPLsample", continuation: nil)
        queue.stageAutoplay(MusicSamples.tracks("r1", "r2"), continuation: nil, seed: "c")
        #expect(ids(MusicQueueListing(queue: queue, listsAutoplay: true).upcoming) == ["c", "r1", "r2"])
        #expect(ids(MusicQueueListing(queue: queue).upcoming) == ["c"])
        #expect(ids(MusicQueueListing(queue: queue, listsNextLap: true, listsAutoplay: true).upcoming) == ["c", "a"])
    }

    /// A page of a, b, c playing `playing`, with a radio of r1 and r2 staged behind it.
    private func stagedPage(playing: Int) -> MusicQueue {
        var queue = MusicQueue()
        let tracks = ["a", "b", "c"].map { MusicSamples.track($0) }
        queue.start(page: tracks, playing: tracks[playing], browseId: "VLPLsample", continuation: nil)
        queue.stageAutoplay(MusicSamples.tracks("r1", "r2"), continuation: nil, seed: "c")
        return queue
    }

    @Test("the staged radio starts after the page's own songs, wherever the page is played from")
    func autoplayStartIsTheOwnSongCount() {
        for (playing, own) in [(0, 2), (1, 1), (2, 0)] {
            let listing = MusicQueueListing(queue: stagedPage(playing: playing), listsAutoplay: true)
            #expect(listing.autoplayStart == own, "playing row \(playing)")
            #expect(Array(ids(listing.upcoming).dropFirst(own)) == ["r1", "r2"], "playing row \(playing)")
        }
    }

    @Test("without a staged radio on show there is no Autoplay start: Autoplay off, a radio queue, the next lap, nothing staged")
    func autoplayStartIsNilWithoutAStagedRadio() {
        let page = stagedPage(playing: 1)
        #expect(MusicQueueListing(queue: page).autoplayStart == nil)
        #expect(MusicQueueListing(queue: page, listsNextLap: true, listsAutoplay: true).autoplayStart == nil)

        var radio = MusicQueue()
        radio.start(with: MusicSamples.track("a"))
        radio.append(MusicSamples.tracks("b", "c"), continuation: nil)
        #expect(MusicQueueListing(queue: radio, listsAutoplay: true).autoplayStart == nil)

        var bare = MusicQueue()
        let tracks = ["a", "b", "c"].map { MusicSamples.track($0) }
        bare.start(page: tracks, playing: tracks[1], browseId: "VLPLsample", continuation: nil)
        #expect(MusicQueueListing(queue: bare, listsAutoplay: true).autoplayStart == nil)
        #expect(MusicQueueListing(queue: MusicQueue(), listsAutoplay: true).autoplayStart == nil)
    }

    @Test("the staged radio goes once the queue takes it, and the listing counts the queue's own songs only")
    func queuedCountLeavesOutTheRadio() {
        var queue = stagedPage(playing: 1)
        let staged = MusicQueueListing(queue: queue, listsAutoplay: true)
        #expect(staged.upcoming.count == 3)
        #expect(staged.queuedCount == 1)

        queue.takeAutoplay()
        let taken = MusicQueueListing(queue: queue, listsAutoplay: true)
        #expect(ids(taken.upcoming) == ["c", "r1", "r2"])
        #expect(taken.autoplayStart == nil)
        #expect(taken.queuedCount == 3)

        let hidden = MusicQueueListing(queue: stagedPage(playing: 1))
        #expect(hidden.queuedCount == 1)
        #expect(MusicQueueListing(queue: MusicQueue()).queuedCount == 0)
    }

    @Test("the label over the staged songs reads AUTOPLAY")
    func autoplayKicker() {
        #expect(MusicQueueListing.autoplayKicker == "AUTOPLAY")
    }

    @Test("unfiltered, the label opens the row at the Autoplay start and no other")
    func opensAutoplayUnfiltered() {
        let matches = Array(0..<5)
        let opening = (0..<5).filter { MusicQueueListing.opensAutoplay(shownIndex: $0, matches: matches, autoplayStart: 2) }
        #expect(opening == [2])
        let first = (0..<5).filter { MusicQueueListing.opensAutoplay(shownIndex: $0, matches: matches, autoplayStart: 0) }
        #expect(first == [0])
    }

    @Test("with no Autoplay start no row opens the label, and a row that is not shown cannot")
    func opensAutoplayNeedsAStartAndARow() {
        let matches = Array(0..<3)
        #expect((0..<3).allSatisfy { !MusicQueueListing.opensAutoplay(shownIndex: $0, matches: matches, autoplayStart: nil) })
        #expect(!MusicQueueListing.opensAutoplay(shownIndex: 3, matches: matches, autoplayStart: 0))
        #expect(!MusicQueueListing.opensAutoplay(shownIndex: -1, matches: matches, autoplayStart: 0))
        #expect(!MusicQueueListing.opensAutoplay(shownIndex: 0, matches: [], autoplayStart: 0))
    }

    @Test("filtered, the label opens the first shown row from the radio, even when none of the queue's own songs match")
    func opensAutoplayFiltered() {
        // Five songs, the radio starting at 3. Rows 1, 3 and 4 match.
        let matches = [1, 3, 4]
        let opening = matches.indices.filter { MusicQueueListing.opensAutoplay(shownIndex: $0, matches: matches, autoplayStart: 3) }
        #expect(opening == [1])
        // Only radio rows match: the first of them opens the label at the top of the list.
        let radioOnly = [3, 4]
        let top = radioOnly.indices.filter { MusicQueueListing.opensAutoplay(shownIndex: $0, matches: radioOnly, autoplayStart: 3) }
        #expect(top == [0])
    }

    @Test("filtered, a list where no staged song matches never opens the label")
    func opensAutoplayFilteredWithoutRadioMatches() {
        let matches = [0, 2]
        #expect(matches.indices.allSatisfy { !MusicQueueListing.opensAutoplay(shownIndex: $0, matches: matches, autoplayStart: 3) })
    }

    @Test("a radio queue says it comes from the radio")
    func radioSource() {
        var queue = MusicQueue()
        queue.start(with: MusicSamples.track("a"))
        #expect(MusicQueueListing(queue: queue).sourceLine == "From radio")
    }

    @Test("a tapped song with Autoplay off names no source, because no radio is coming")
    func loneSongWithoutAutoplayNamesNoSource() {
        var queue = MusicQueue()
        queue.start(with: MusicSamples.track("a"))
        let off = MusicQueueListing(queue: queue, autoplayIsOn: false)

        #expect(off.sourceLine == nil)
        #expect(MusicQueueListing.nowPlayingKicker(sourceLine: off.sourceLine) == "NOW PLAYING")
        // With Autoplay on the radio is on its way, so the line already says so.
        let on = MusicQueueListing(queue: queue, autoplayIsOn: true)
        #expect(on.sourceLine == "From radio")
        #expect(MusicQueueListing.nowPlayingKicker(sourceLine: on.sourceLine) == "NOW PLAYING \u{00B7} FROM RADIO")
    }

    @Test("once a radio has answered the queue says it comes from the radio, whatever Autoplay is set to")
    func answeredRadioNamesItsSource() {
        var queue = MusicQueue()
        queue.start(with: MusicSamples.track("a"))
        queue.adoptRadio(seedVideoId: "a")

        #expect(MusicQueueListing(queue: queue, autoplayIsOn: false).sourceLine == "From radio")
        #expect(MusicQueueListing(queue: queue, autoplayIsOn: true).sourceLine == "From radio")
    }

    @Test("a radio parked behind the tapped song names no source; a playing song from the radio keeps it")
    func parkedRadioNamesItsSourceByTheSong() {
        var queue = MusicQueue()
        queue.start(with: MusicSamples.track("a"))
        queue.adoptRadio(seedVideoId: "a")
        queue.append(MusicSamples.tracks("r1", "r2", "r3"), continuation: nil)
        var played = queue
        played.advance()

        queue.parkRadio()
        let tapped = MusicQueueListing(queue: queue, autoplayIsOn: false)
        #expect(tapped.sourceLine == nil)
        #expect(MusicQueueListing.nowPlayingKicker(sourceLine: tapped.sourceLine) == "NOW PLAYING")

        // The song that plays came from the radio, so the radio stays its source even though the rest is parked.
        played.parkRadio()
        let fromRadio = MusicQueueListing(queue: played, autoplayIsOn: false)
        #expect(fromRadio.sourceLine == "From radio")
        #expect(MusicQueueListing.nowPlayingKicker(sourceLine: fromRadio.sourceLine) == "NOW PLAYING \u{00B7} FROM RADIO")

        // Autoplay on again: the radio is back and the tapped song is from it.
        queue.restoreRadio()
        #expect(MusicQueueListing(queue: queue, autoplayIsOn: true).sourceLine == "From radio")
    }

    @Test("a parked radio is not listed in Up next, but the songs the listener queued are")
    func parkedRadioIsNotListed() {
        var queue = MusicQueue()
        queue.start(with: MusicSamples.track("a"))
        queue.adoptRadio(seedVideoId: "a")
        queue.append(MusicSamples.tracks("r1", "r2", "r3"), continuation: "c1")
        queue.playNext(MusicSamples.track("x"))
        #expect(ids(MusicQueueListing(queue: queue).upcoming) == ["x", "r1", "r2", "r3"])

        queue.parkRadio()
        let listing = MusicQueueListing(queue: queue, autoplayIsOn: false)

        #expect(ids(listing.upcoming) == ["x"])
        #expect(listing.queuedCount == 1)
        #expect(listing.autoplayStart == nil)
    }

    @Test("a page queue names its source with Autoplay off too")
    func pageSourceWithoutAutoplay() {
        var queue = MusicQueue()
        let track = MusicSamples.track("a")
        queue.start(page: [track], playing: track, browseId: "VLPLsample", continuation: nil)

        #expect(MusicQueueListing(queue: queue, autoplayIsOn: false).sourceLine == "From playlist")
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

    @Test("a mix names itself, whichever kind of source the queue currently is")
    func mixSources() {
        for source in [
            MusicQueue.Source.page(browseId: "VLRDTMAK5uy_mix"), .page(browseId: "VLPLsample"), .page(browseId: "MPREb_sample"),
            .page(browseId: "VLLM"), .page(browseId: "UCsample"), .radio(seedVideoId: "a"),
        ] {
            #expect(MusicQueueListing.sourceLine(for: source, isMix: true) == "From mix", "\(source)")
        }
    }

    @Test("a queue that is not a mix names its source as it always did")
    func notMixSources() {
        let sources: [(MusicQueue.Source, String)] = [
            (.radio(seedVideoId: "a"), "From radio"), (.page(browseId: "MPREb_sample"), "From album"),
            (.page(browseId: "VLLM"), "From Liked music"), (.page(browseId: "VLPLsample"), "From playlist"),
            (.page(browseId: "UCsample"), "From playlist or album"),
        ]
        for (source, line) in sources {
            #expect(MusicQueueListing.sourceLine(for: source, isMix: false) == line, "\(source)")
            #expect(MusicQueueListing.sourceLine(for: source) == line, "\(source)")
        }
    }

    @Test("a queue with no source has no source line, mix or not")
    func noSourceNoLine() {
        #expect(MusicQueueListing.sourceLine(for: nil, isMix: true) == nil)
        #expect(MusicQueueListing.sourceLine(for: nil, isMix: false) == nil)
        #expect(MusicQueueListing.sourceLine(for: nil) == nil)
    }

    @Test("a queue started from a mix page says it comes from a mix, and says so after the mix answered")
    func mixQueueListing() {
        var queue = MusicQueue()
        let track = MusicSamples.track("a")
        queue.start(page: [track], playing: track, browseId: "VLRDTMAK5uy_mix", continuation: nil, mixPlaylistId: "RDTMAK5uy_mix")
        #expect(MusicQueueListing(queue: queue).sourceLine == "From mix")
        #expect(MusicQueueListing(queue: queue, autoplayIsOn: false).sourceLine == "From mix")

        queue.adoptRadio(seedVideoId: "a")
        #expect(MusicQueueListing(queue: queue).sourceLine == "From mix")
        #expect(MusicQueueListing(queue: queue, autoplayIsOn: false).sourceLine == "From mix")
        #expect(MusicQueueListing.nowPlayingKicker(sourceLine: MusicQueueListing(queue: queue).sourceLine) == "NOW PLAYING \u{00B7} FROM MIX")
    }

    @Test("a mix that was forgotten goes back to naming its page or its radio")
    func forgottenMixListing() {
        var queue = MusicQueue()
        let track = MusicSamples.track("a")
        queue.start(page: [track], playing: track, browseId: "VLRDTMAK5uy_mix", continuation: nil, mixPlaylistId: "RDTMAK5uy_mix")
        queue.forgetMix()
        #expect(MusicQueueListing(queue: queue).sourceLine == "From playlist")

        queue.adoptRadio(seedVideoId: "a")
        #expect(MusicQueueListing(queue: queue).sourceLine == "From radio")
    }

    @Test("the kicker over the song in the player names the source in capitals")
    func nowPlayingKicker() {
        #expect(MusicQueueListing.nowPlayingKicker(sourceLine: "From playlist") == "NOW PLAYING \u{00B7} FROM PLAYLIST")
        #expect(MusicQueueListing.nowPlayingKicker(sourceLine: "From Liked music") == "NOW PLAYING \u{00B7} FROM LIKED MUSIC")
        #expect(MusicQueueListing.nowPlayingKicker(sourceLine: "From radio") == "NOW PLAYING \u{00B7} FROM RADIO")
    }

    @Test("a queue with no known source has a kicker without a source")
    func nowPlayingKickerWithoutSource() {
        #expect(MusicQueueListing.nowPlayingKicker(sourceLine: nil) == "NOW PLAYING")
        #expect(MusicQueueListing.nowPlayingKicker(sourceLine: "") == "NOW PLAYING")
        #expect(MusicQueueListing.nowPlayingKicker(sourceLine: MusicQueueListing(queue: MusicQueue()).sourceLine) == "NOW PLAYING")
    }

    @Test("the kicker over the later songs counts them")
    func nextKicker() {
        #expect(MusicQueueListing.nextKicker(count: 12) == "NEXT IN QUEUE \u{00B7} 12")
        #expect(MusicQueueListing.nextKicker(count: 0) == "NEXT IN QUEUE \u{00B7} 0")
        #expect(MusicQueueListing.nextKicker(count: 2000) == "NEXT IN QUEUE \u{00B7} 2000")
        #expect(MusicQueueListing.nextKicker(count: -3) == "NEXT IN QUEUE \u{00B7} 0")
    }

    @Test("over a filtered queue the kicker says how many of the later songs match")
    func filteredNextKicker() {
        #expect(MusicQueueListing.nextKicker(matched: 1, total: 4) == "NEXT IN QUEUE \u{00B7} 1 OF 4")
        #expect(MusicQueueListing.nextKicker(matched: 0, total: 4) == "NEXT IN QUEUE \u{00B7} 0 OF 4")
        #expect(MusicQueueListing.nextKicker(matched: -1, total: -2) == "NEXT IN QUEUE \u{00B7} 0 OF 0")
    }
}

@MainActor
@Suite("MusicPlaybackToggle")
struct MusicPlaybackToggleTests {
    @Test("the header carries Shuffle, Loop and Autoplay, in that order")
    func order() {
        #expect(MusicPlaybackToggle.allCases == [.shuffle, .loop, .autoplay])
    }

    @Test("each toggle has its own glyph, and the loop's follows its mode")
    func symbols() {
        #expect(MusicPlaybackToggle.shuffle.symbol(loop: .off) == "shuffle")
        #expect(MusicPlaybackToggle.autoplay.symbol(loop: .off) == "infinity")
        #expect(MusicPlaybackToggle.loop.symbol(loop: .off) == "repeat")
        #expect(MusicPlaybackToggle.loop.symbol(loop: .playlist) == "repeat")
        #expect(MusicPlaybackToggle.loop.symbol(loop: .song) == "repeat.1")
    }

    @Test("each toggle is on by its own setting, and any loop mode but off lights the loop")
    func isOn() {
        #expect(MusicPlaybackToggle.shuffle.isOn(shuffle: true, loop: .off, autoplay: false))
        #expect(!MusicPlaybackToggle.shuffle.isOn(shuffle: false, loop: .song, autoplay: true))
        #expect(MusicPlaybackToggle.autoplay.isOn(shuffle: false, loop: .off, autoplay: true))
        #expect(!MusicPlaybackToggle.autoplay.isOn(shuffle: true, loop: .song, autoplay: false))
        #expect(!MusicPlaybackToggle.loop.isOn(shuffle: true, loop: .off, autoplay: true))
        #expect(MusicPlaybackToggle.loop.isOn(shuffle: false, loop: .playlist, autoplay: false))
        #expect(MusicPlaybackToggle.loop.isOn(shuffle: false, loop: .song, autoplay: false))
    }

    @Test("the names are what VoiceOver says, and the loop's says its mode")
    func titles() {
        #expect(MusicPlaybackToggle.shuffle.title(loop: .song) == "Shuffle")
        #expect(MusicPlaybackToggle.autoplay.title(loop: .song) == "Autoplay")
        #expect(MusicPlaybackToggle.loop.title(loop: .off) == "Loop off")
        #expect(MusicPlaybackToggle.loop.title(loop: .playlist) == "Loop playlist")
        #expect(MusicPlaybackToggle.loop.title(loop: .song) == "Loop song")
    }
}

@MainActor
@Suite("MusicLyricsCaption")
struct MusicLyricsCaptionTests {
    @Test("the header's title is always Lyrics")
    func title() {
        #expect(MusicLyricsCaption.title == "Lyrics")
    }

    @Test("only plain lyrics carry the 'Not synced' tag")
    func tag() {
        #expect(MusicLyricsCaption.tag(for: .loaded(.plain("words"))) == "Not synced")
        #expect(MusicLyricsCaption.tag(for: .loaded(.synced([]))) == nil)
        #expect(MusicLyricsCaption.tag(for: .loaded(.instrumental)) == nil)
        #expect(MusicLyricsCaption.tag(for: .loaded(.notFound)) == nil)
        #expect(MusicLyricsCaption.tag(for: .idle) == nil)
        #expect(MusicLyricsCaption.tag(for: .loading) == nil)
        #expect(MusicLyricsCaption.tag(for: .failed("x", retryAfter: nil)) == nil)
    }

    @Test("the foot names synced and plain lyrics, and nothing else")
    func footer() {
        #expect(MusicLyricsCaption.footer(for: .loaded(.synced([]))) == "SYNCED LYRICS")
        #expect(MusicLyricsCaption.footer(for: .loaded(.plain("words"))) == "PLAIN LYRICS")
        #expect(MusicLyricsCaption.footer(for: .loaded(.instrumental)) == nil)
        #expect(MusicLyricsCaption.footer(for: .loaded(.notFound)) == nil)
        #expect(MusicLyricsCaption.footer(for: .idle) == nil)
        #expect(MusicLyricsCaption.footer(for: .loading) == nil)
        #expect(MusicLyricsCaption.footer(for: .failed("x", retryAfter: nil)) == nil)
    }

    @Test("plain lyrics split into paragraphs on empty lines, each keeping its own lines in order")
    func stanzas() {
        let text = "Synthetic line one\nSynthetic line two\n\nSynthetic line three\n\n\n\nSynthetic line four"
        #expect(MusicLyricsCaption.stanzas(of: text) == [
            "Synthetic line one\nSynthetic line two", "Synthetic line three", "Synthetic line four",
        ])
    }

    @Test("a line of only spaces is an empty line, and lines are trimmed")
    func stanzasTrim() {
        #expect(MusicLyricsCaption.stanzas(of: "  one  \n   \n\ttwo\t") == ["one", "two"])
    }

    @Test("Windows line endings split the same way")
    func stanzasCarriageReturns() {
        #expect(MusicLyricsCaption.stanzas(of: "one\r\ntwo\r\n\r\nthree") == ["one\ntwo", "three"])
    }

    @Test("no text, or only blank lines, has no paragraphs")
    func stanzasEmpty() {
        #expect(MusicLyricsCaption.stanzas(of: "").isEmpty)
        #expect(MusicLyricsCaption.stanzas(of: "\n \n\t\n").isEmpty)
    }

    @Test("text with emoji and accents is kept as it is")
    func stanzasUnicode() {
        #expect(MusicLyricsCaption.stanzas(of: "caf\u{00E9} \u{1F3B5}\n\nna\u{00EF}ve") == ["caf\u{00E9} \u{1F3B5}", "na\u{00EF}ve"])
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
}
