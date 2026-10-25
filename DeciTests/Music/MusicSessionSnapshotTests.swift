// DeciTests/Music/MusicSessionSnapshotTests.swift
// The remembered session: what the file holds, how a long queue is cut to fit, and what counts as the same state.

import Foundation
import Testing
@testable import Deci

@Suite("MusicSessionSnapshot")
struct MusicSessionSnapshotTests {
    private let saved = Date(timeIntervalSince1970: 1_800_000_000)

    /// A radio queue of `count` songs ("v0", "v1", ...) standing on song `index`, with a next page still to load.
    private func radioQueue(count: Int, index: Int = 0, continuation: String? = "next-page") -> MusicQueue {
        let songs = (0..<count).map { MusicSamples.track("v\($0)", title: "Song \($0)") }
        var queue = MusicQueue()
        queue.start(with: songs[0])
        queue.append(Array(songs.dropFirst()), continuation: continuation)
        if index > 0 { queue.jump(to: "v\(index)") }
        return queue
    }

    private func snapshot(_ queue: MusicQueue, position: TimeInterval = 42.5, channel: String = "chan-a") -> MusicSessionSnapshot {
        MusicSessionSnapshot(savedAt: saved, channelKey: channel, position: position, queue: queue)
    }

    // MARK: - Round trip

    @Test("A page queue with every kind of edit comes back from the file exactly, private state included")
    func roundTrip() throws {
        let page = (1...6).map { MusicSamples.track("p\($0)", title: "Page \($0)") }
        var queue = MusicQueue()
        queue.start(page: page, playing: page[1], browseId: "VLPL1", continuation: "tok", automixPlaylistId: "RDAMPL1")
        var generator = MusicShuffleGenerator(seed: 7)
        queue.shuffle(mixingEarlier: true, using: &generator)
        queue.playNext(MusicSamples.track("q1"))
        queue.addToQueue(MusicSamples.track("q2"))
        queue.remove(videoId: "p4")
        queue.stageAutoplay([MusicSamples.track("a1"), MusicSamples.track("a2")], continuation: "auto-tok", seed: "p6")
        queue.advance()

        let original = snapshot(queue)
        let restored = try #require(MusicSessionSnapshot.decode(try original.encoded()))

        #expect(restored == original)
        #expect(restored.queue == queue)
        #expect(restored.queue.current?.videoId == queue.current?.videoId)
        #expect(restored.queue.isShuffled)
        #expect(restored.queue.autoplay.map(\.videoId) == ["a1", "a2"])
        #expect(restored.queue.automixPlaylistId == "RDAMPL1")
        #expect(restored.queue.source == .page(browseId: "VLPL1"))
        #expect(restored.position == 42.5)
        #expect(restored.channelKey == "chan-a")
        #expect(restored.savedAt == saved)

        // What the listener took out stays out, and the staged radio still joins the queue.
        var resumed = restored.queue
        #expect(resumed.addableCount(of: [MusicSamples.track("p4")]) == 0)
        let tookAutoplay = resumed.takeAutoplay()
        #expect(tookAutoplay)
    }

    @Test("A radio queue keeps its seed and its next page")
    func radioRoundTrip() throws {
        let original = snapshot(radioQueue(count: 8, index: 3))
        let restored = try #require(MusicSessionSnapshot.decode(try original.encoded()))
        #expect(restored.queue == original.queue)
        #expect(restored.queue.continuation == "next-page")
        #expect(restored.queue.seedVideoId == "v0")
        #expect(restored.queue.hasPrevious)
        #expect(restored.queue.upcomingCount == 4)
    }

    @Test("Every field of a song survives, unicode and emoji too")
    func trackFieldsSurvive() throws {
        var song = MusicSamples.track(
            "uni1", title: "Café ☕ 日本語 🎵 \"quoted\" \\ back", artist: "Sigur Rós & Björk", seconds: 245,
            albumBrowseId: "MPREb_x", setVideoId: "SET1", album: "Ágætis byrjun", plays: 1_500_000
        )
        song.artistLinks = [MusicArtistLink(name: "Sigur Rós", browseId: "UC1"), MusicArtistLink(name: "Björk", browseId: "UC2")]
        let withThumbnail = Deci.MusicTrack(
            videoId: "uni2", title: "Plain", artist: "A", album: nil, durationSeconds: nil,
            thumbnailURL: URL(string: "https://lh3.example.test/cover=w544-h544")
        )
        var queue = MusicQueue()
        queue.start(with: song)
        queue.append([withThumbnail], continuation: nil)

        let restored = try #require(MusicSessionSnapshot.decode(try snapshot(queue).encoded()))
        #expect(restored.queue.tracks == [song, withThumbnail])
        let first = try #require(restored.queue.tracks.first)
        #expect(first.title == "Café ☕ 日本語 🎵 \"quoted\" \\ back")
        #expect(first.artistLinks.map(\.browseId) == ["UC1", "UC2"])
        #expect(first.albumBrowseId == "MPREb_x")
        #expect(first.playlistSetVideoId == "SET1")
        #expect(first.plays == 1_500_000)
        #expect(restored.queue.tracks[1].thumbnailURL?.host == "lh3.example.test")
        #expect(restored.queue.tracks[1].durationSeconds == nil)
    }

    // MARK: - Cap

    @Test("A queue past the cap keeps the song, 500 after it and 100 before it, and drops the page it can no longer join")
    func capCutsBothEnds() {
        let queue = radioQueue(count: 700, index: 150)
        let cut = snapshot(queue).queue

        #expect(cut.current?.videoId == "v150")
        #expect(cut.upcomingCount == MusicSessionSnapshot.maxUpcoming)
        #expect(cut.upcomingCount == 500)
        #expect(cut.tracks.count - cut.upcomingCount - 1 == MusicSessionSnapshot.maxPlayed)
        #expect(cut.tracks.first?.videoId == "v50")
        #expect(cut.tracks.last?.videoId == "v650")
        // The tail it cut sat between the queue and the next page, so the page is not asked for.
        #expect(cut.continuation == nil)
        // The queue it was cut from is untouched.
        #expect(queue.tracks.count == 700)
        #expect(queue.continuation == "next-page")
    }

    @Test("A queue within the cap is stored whole, next page included")
    func capLeavesAShortQueueAlone() {
        let queue = radioQueue(count: 300, index: 10)
        let stored = snapshot(queue).queue
        #expect(stored == queue)
        #expect(stored.continuation == "next-page")
    }

    @Test("Only the played end is cut when the upcoming end fits")
    func capCutsOnlyThePlayedEnd() {
        let queue = radioQueue(count: 400, index: 300)
        let cut = snapshot(queue).queue
        #expect(cut.current?.videoId == "v300")
        #expect(cut.tracks.count == 100 + 1 + 99)
        #expect(cut.upcomingCount == 99)
        // Nothing after the last song was cut, so its page still follows.
        #expect(cut.continuation == "next-page")
    }

    @Test("A shuffled queue that was cut can still be put back in order, and the songs the listener took out stay out")
    func capKeepsShuffleAndRemovals() throws {
        var queue = radioQueue(count: 700, index: 0, continuation: nil)
        var generator = MusicShuffleGenerator(seed: 11)
        queue.shuffle(using: &generator)
        let removed = try #require(queue.upcoming.dropFirst(5).first)
        queue.remove(videoId: removed.videoId)
        let current = try #require(queue.current?.videoId)

        var cut = snapshot(queue).queue
        #expect(cut.isShuffled)
        #expect(cut.upcomingCount == 500)
        #expect(cut.addableCount(of: [removed]) == 0)
        cut.unshuffle()
        #expect(cut.current?.videoId == current)
        #expect(!cut.isShuffled)
        let ids = cut.tracks.map(\.videoId)
        #expect(ids == ids.sorted { Int($0.dropFirst())! < Int($1.dropFirst())! })
    }

    @Test("The staged radio and a parked radio are cut to the cap too")
    func capCutsStagedLists() throws {
        let page = (0..<5).map { MusicSamples.track("p\($0)") }
        var queue = MusicQueue()
        queue.start(page: page, playing: page[0], browseId: "VLPL", continuation: nil)
        let staged = (0..<650).map { MusicSamples.track("s\($0)") }
        queue.stageAutoplay(staged, continuation: "more", seed: "p4")
        let cut = snapshot(queue).queue
        #expect(cut.autoplay.count == 500)
        #expect(cut.autoplay.first?.videoId == "s0")

        var radio = radioQueue(count: 700, index: 0)
        radio.parkRadio()
        #expect(radio.parked.count == 699)
        let parkedCut = snapshot(radio).queue
        #expect(parkedCut.radioIsParked)
        #expect(parkedCut.parked.count == 500)
        #expect(parkedCut.parked.first?.videoId == "v1")
    }

    // MARK: - Reading

    @Test("A file of another version, a damaged one and an empty one read as nothing")
    func unreadableFilesAreNothing() throws {
        let good = try snapshot(radioQueue(count: 3)).encoded()
        #expect(MusicSessionSnapshot.decode(good) != nil)

        var object = try #require(JSONSerialization.jsonObject(with: good) as? [String: Any])
        #expect(object["version"] as? Int == MusicSessionSnapshot.version)
        object["version"] = MusicSessionSnapshot.version + 1
        let newer = try JSONSerialization.data(withJSONObject: object)
        #expect(MusicSessionSnapshot.decode(newer) == nil)

        // A future format may not even have the fields this one reads.
        let onlyVersion = try JSONSerialization.data(withJSONObject: ["version": MusicSessionSnapshot.version + 1])
        #expect(MusicSessionSnapshot.decode(onlyVersion) == nil)

        #expect(MusicSessionSnapshot.decode(Data("not json at all".utf8)) == nil)
        #expect(MusicSessionSnapshot.decode(Data()) == nil)
        #expect(MusicSessionSnapshot.decode(Data("{}".utf8)) == nil)
        #expect(MusicSessionSnapshot.decode(good.prefix(good.count / 2)) == nil)
    }

    @Test("A file whose queue does not stand on one of its songs, or one far too big, reads as nothing")
    func impossibleQueueIsNothing() throws {
        let good = try snapshot(radioQueue(count: 3)).encoded()
        var object = try #require(JSONSerialization.jsonObject(with: good) as? [String: Any])
        var queue = try #require(object["queue"] as? [String: Any])
        #expect(queue["currentIndex"] as? Int == 0)

        queue["currentIndex"] = 3
        object["queue"] = queue
        #expect(MusicSessionSnapshot.decode(try JSONSerialization.data(withJSONObject: object)) == nil)
        queue["currentIndex"] = -1
        object["queue"] = queue
        #expect(MusicSessionSnapshot.decode(try JSONSerialization.data(withJSONObject: object)) == nil)
        queue.removeValue(forKey: "currentIndex")
        object["queue"] = queue
        #expect(MusicSessionSnapshot.decode(try JSONSerialization.data(withJSONObject: object)) == nil)

        var padded = good
        padded.append(Data(repeating: 0x20, count: MusicSessionSnapshot.maxFileSize))
        #expect(MusicSessionSnapshot.decode(padded) == nil)
    }

    @Test("A position that is not a number is stored as the start, and the file still encodes")
    func positionIsSanitised() throws {
        let nan = snapshot(radioQueue(count: 2), position: .nan)
        #expect(nan.position == 0)
        #expect(snapshot(radioQueue(count: 2), position: -5).position == 0)
        #expect(snapshot(radioQueue(count: 2), position: .infinity).position == 0)
        #expect(MusicSessionSnapshot.decode(try nan.encoded()) != nil)
    }

    // MARK: - Lifetime and position

    @Test("A session is remembered for one hour")
    func lifetimeIsOneHour() {
        #expect(MusicSessionSnapshot.lifetime == 3600)
    }

    @Test("The saved position is kept, held a couple of seconds short of the end, and is the start when the length is unknown")
    func clampedPosition() {
        let queue = radioQueue(count: 2)
        #expect(snapshot(queue, position: 199).clampedPosition(duration: 200) == 198)
        #expect(snapshot(queue, position: 195).clampedPosition(duration: 200) == 195)
        #expect(snapshot(queue, position: 200).clampedPosition(duration: 200) == 198)
        #expect(snapshot(queue, position: 50).clampedPosition(duration: 200) == 50)
        #expect(snapshot(queue, position: 0).clampedPosition(duration: 200) == 0)
        #expect(snapshot(queue, position: 50).clampedPosition(duration: nil) == 0)
        #expect(snapshot(queue, position: 50).clampedPosition(duration: 0) == 0)
        #expect(snapshot(queue, position: 50).clampedPosition(duration: .nan) == 0)
        // A song shorter than the margin starts from the beginning.
        #expect(snapshot(queue, position: 1).clampedPosition(duration: 1.5) == 0)
    }

    // MARK: - Same state

    @Test("Two snapshots are the same state when only the save time or a second of position differs")
    func sameState() {
        let queue = radioQueue(count: 5, index: 2)
        let base = snapshot(queue, position: 100)
        let later = MusicSessionSnapshot(
            savedAt: saved.addingTimeInterval(500), channelKey: "chan-a", position: 100.8, queue: queue
        )
        #expect(base != later)
        #expect(base.hasSameState(as: later))

        let moved = MusicSessionSnapshot(savedAt: saved, channelKey: "chan-a", position: 102, queue: queue)
        #expect(!base.hasSameState(as: moved))

        let otherChannel = MusicSessionSnapshot(savedAt: saved, channelKey: "chan-b", position: 100, queue: queue)
        #expect(!base.hasSameState(as: otherChannel))

        var edited = queue
        edited.playNext(MusicSamples.track("extra"))
        #expect(!base.hasSameState(as: snapshot(edited, position: 100)))
    }
}
