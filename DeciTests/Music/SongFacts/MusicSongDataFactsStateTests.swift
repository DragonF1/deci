// DeciTests/Music/SongFacts/MusicSongDataFactsStateTests.swift
// The Song data store's music state: looking up, then data; looking up, measuring, then measured; a switch or a close
// drops what is out; and the quiet problems (offline, signed out, rate limited).

import Foundation
import Testing
@testable import Deci

/// A gate a fake service waits on, so a test decides when it answers.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class FactsWorld {
    var held: [String: ResolvedStream] = [:]
    var analyses: [String: MusicAnalysis] = [:]
    var cached: [String: MusicSongFactsCached] = [:]
    var offline = false
    var signedOut = false

    var lookups: [String] = []
    var measures: [(videoId: String, needAnalysis: Bool, needBPM: Bool)] = []
    var activeMeasures = 0
    var mostActiveMeasures = 0

    var lookupGate: Gate?
    var measureGates: [String: Gate] = [:]
    /// What the lookup stores for a song.
    var afterLookup: [String: MusicSongFactsCached] = [:]
    /// What a finished measure stores for a song.
    var afterMeasure: [String: (facts: MusicSongFacts, analysis: MusicAnalysis?)] = [:]
    var measureResult = MusicSongMeasureResult(problem: nil)
}

@MainActor
private struct FactsHarness {
    let backend = FakeMusicBackend()
    let store: MusicSongDataStore
    let world = FactsWorld()

    init(withFacts: Bool = true) {
        store = MusicSongDataStore(backend: backend)
        let world = self.world
        var sources = MusicSongDataStore.Sources(
            heldStream: { world.held[$0] },
            analysis: { world.analyses[$0] },
            isOffline: { world.offline }
        )
        if withFacts {
            sources.isSignedOut = { world.signedOut }
            sources.cachedFacts = { world.cached[$0] }
            sources.lookupFacts = { track in
                world.lookups.append(track.videoId)
                await world.lookupGate?.wait()
                if let stored = world.afterLookup[track.videoId] { world.cached[track.videoId] = stored }
            }
            sources.measure = { stream, needAnalysis, needBPM in
                world.measures.append((stream.videoId, needAnalysis, needBPM))
                world.activeMeasures += 1
                world.mostActiveMeasures = max(world.mostActiveMeasures, world.activeMeasures)
                await world.measureGates[stream.videoId]?.wait()
                world.activeMeasures -= 1
                if let done = world.afterMeasure[stream.videoId] {
                    world.cached[stream.videoId] = MusicSongFactsCached(facts: done.facts, lookupIsFresh: true, measureAttempted: true)
                    if let row = done.analysis { world.analyses[stream.videoId] = row }
                }
                return world.measureResult
            }
        }
        store.sources = sources
    }

    func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    func letLateWorkLand() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(40))
    }

    func hold(_ id: String, file: Bool = false) {
        var stream = MusicSamples.stream(videoId: id)
        if file { stream = Self.fileStream(id) }
        world.held[id] = stream
    }

    static func fileStream(_ id: String) -> ResolvedStream {
        ResolvedStream(
            videoId: id, url: URL(fileURLWithPath: "/Volumes/Storage/_test/deci-songdata/\(id).m4a"), itag: 251,
            durationSeconds: 200, expiresAt: .distantFuture, playbackTrackingURL: nil, httpHeaders: [:], origin: .download
        )
    }

    func row(_ id: String) -> MusicAnalysis {
        MusicAnalysis(
            videoId: id, version: 1, format: .init(codec: "opus", itag: 251, durationMs: 200_000), analyzedAt: Date(),
            source: .download, silenceStart: 0, silenceEnd: 200, introEnd: 10, outroStart: 190, integratedLUFS: -14,
            samplePeakDb: -1, introLUFS: nil, outroLUFS: nil, energy: [], youtubeLoudnessDb: nil,
            youtubePerceptualLoudnessDb: nil
        )
    }

    func facts(bpm: Double? = nil, source: MusicSongFacts.Source = .reccobeats) -> MusicSongFacts {
        var facts = MusicSongFacts(fetchedAt: Date())
        facts.isrc = "USUG11904206"
        facts.claim(.isrc, .deezer)
        if let bpm {
            facts.bpm = bpm
            facts.claim(.bpm, source)
        }
        return facts
    }

    func song(_ id: String) -> MusicTrack { MusicSamples.track(id, title: "Song \(id)") }
}

@MainActor
@Suite("MusicSongDataStore song facts")
struct MusicSongDataFactsStateTests {
    @Test("opening reads Looking up until the services answer, then shows the data")
    func lookingUpThenData() async {
        let h = FactsHarness()
        let gate = Gate()
        h.world.lookupGate = gate
        h.hold("a")
        h.world.analyses["a"] = h.row("a")
        let found = h.facts(bpm: 171)
        h.world.afterLookup["a"] = MusicSongFactsCached(facts: found, lookupIsFresh: true, measureAttempted: false)

        h.store.show(h.song("a"))
        #expect(h.store.music.lookingUp)
        #expect(h.store.music.facts == nil)
        #expect(await h.until { h.world.lookups == ["a"] })

        gate.open()
        #expect(await h.until { !h.store.music.lookingUp })
        #expect(h.store.music.facts == found)
        #expect(h.store.music.problem == nil)
        // The song has its analysis and a tempo: nothing is measured.
        await h.letLateWorkLand()
        #expect(h.world.measures.isEmpty)
        #expect(h.store.music.measuringTempo == false)
    }

    @Test("a fresh cache answers with no lookup at all")
    func cacheHit() async {
        let h = FactsHarness()
        h.hold("a")
        h.world.analyses["a"] = h.row("a")
        let found = h.facts(bpm: 120)
        h.world.cached["a"] = MusicSongFactsCached(facts: found, lookupIsFresh: true, measureAttempted: false)
        h.store.show(h.song("a"))
        #expect(await h.until { !h.store.music.lookingUp })
        #expect(h.store.music.facts == found)
        #expect(h.world.lookups.isEmpty)
    }

    @Test("a stale cache is looked up again")
    func staleCache() async {
        let h = FactsHarness()
        h.hold("a")
        h.world.analyses["a"] = h.row("a")
        h.world.cached["a"] = MusicSongFactsCached(facts: nil, lookupIsFresh: false, measureAttempted: true)
        h.store.show(h.song("a"))
        #expect(await h.until { !h.store.music.lookingUp })
        #expect(h.world.lookups == ["a"])
    }

    @Test("looking up, then measuring, then measured: the tempo is the song's own")
    func lookingUpMeasuringMeasured() async {
        let h = FactsHarness()
        let lookupGate = Gate()
        let measureGate = Gate()
        h.world.lookupGate = lookupGate
        h.world.measureGates["a"] = measureGate
        h.hold("a")
        // The services know the song but not its tempo, and it has no analysis row.
        h.world.afterLookup["a"] = MusicSongFactsCached(facts: h.facts(), lookupIsFresh: true, measureAttempted: false)
        var measured = h.facts()
        measured.setMeasuredTempo(bpm: 104, confidence: 0.8)
        h.world.afterMeasure["a"] = (measured, h.row("a"))

        h.store.show(h.song("a"))
        #expect(h.store.music.lookingUp)
        #expect(h.store.music.measuringTempo == false)

        lookupGate.open()
        #expect(await h.until { h.store.music.measuringTempo })
        #expect(h.store.music.lookingUp == false)
        #expect(h.store.music.measuringAnalysis)
        #expect(h.world.measures.count == 1)
        #expect(h.world.measures.first?.needAnalysis == true)
        #expect(h.world.measures.first?.needBPM == true)

        measureGate.open()
        #expect(await h.until { !h.store.music.measuringTempo })
        #expect(h.store.music.measuringAnalysis == false)
        #expect(h.store.music.facts?.bpm == 104)
        #expect(h.store.music.facts?.source(of: .bpm) == .deci)
        #expect(h.store.analysis != nil)
        #expect(h.store.music.problem == nil)
    }

    @Test("a tempo from a service is not measured, and a missing analysis alone is")
    func onlyWhatIsMissing() async {
        let h = FactsHarness()
        h.hold("a")
        h.world.cached["a"] = MusicSongFactsCached(facts: h.facts(bpm: 171), lookupIsFresh: true, measureAttempted: false)
        h.store.show(h.song("a"))
        #expect(await h.until { !h.world.measures.isEmpty })
        #expect(h.world.measures.first?.needAnalysis == true)
        #expect(h.world.measures.first?.needBPM == false)
    }

    @Test("a tempo that was measured before (even an empty one) is not measured again")
    func measuredBefore() async {
        let h = FactsHarness()
        h.hold("a")
        h.world.analyses["a"] = h.row("a")
        h.world.cached["a"] = MusicSongFactsCached(facts: nil, lookupIsFresh: true, measureAttempted: true)
        h.store.show(h.song("a"))
        await h.letLateWorkLand()
        #expect(h.world.measures.isEmpty)
        #expect(h.store.music.facts == nil)
    }

    @Test("switching songs drops the measure that is out and measures one song at a time")
    func switchCancels() async {
        let h = FactsHarness()
        let gateA = Gate()
        h.world.measureGates["a"] = gateA
        h.hold("a")
        h.hold("b")
        h.world.cached["a"] = MusicSongFactsCached(facts: h.facts(), lookupIsFresh: true, measureAttempted: false)
        h.world.cached["b"] = MusicSongFactsCached(facts: h.facts(), lookupIsFresh: true, measureAttempted: false)
        var late = h.facts()
        late.setMeasuredTempo(bpm: 99, confidence: 0.9)
        h.world.afterMeasure["a"] = (late, h.row("a"))

        h.store.show(h.song("a"))
        #expect(await h.until { h.world.measures.count == 1 })

        h.store.show(h.song("b"))
        #expect(h.store.track?.videoId == "b")
        await h.letLateWorkLand()
        // b waits for a's run to end, so the two never overlap.
        #expect(h.world.measures.count == 1)

        gateA.open()
        #expect(await h.until { h.world.measures.count == 2 })
        #expect(h.world.measures.last?.videoId == "b")
        #expect(h.world.mostActiveMeasures == 1)
        await h.letLateWorkLand()
        // a's late answer landed nowhere.
        #expect(h.store.music.facts?.bpm != 99)
        #expect(h.store.analysis?.videoId != "a")
    }

    @Test("closing drops the facts and the measure that is out")
    func closeResets() async {
        let h = FactsHarness()
        let gate = Gate()
        h.world.measureGates["a"] = gate
        h.hold("a")
        h.world.cached["a"] = MusicSongFactsCached(facts: h.facts(), lookupIsFresh: true, measureAttempted: false)
        h.store.show(h.song("a"))
        #expect(await h.until { h.store.music.measuringTempo })
        h.store.close()
        #expect(h.store.music == MusicSongDataMusicState())
        gate.open()
        await h.letLateWorkLand()
        #expect(h.store.music == MusicSongDataMusicState())
    }

    @Test("offline: no lookup, no measure, and the panel says Offline quietly; the network back runs the lookup")
    func offline() async {
        let h = FactsHarness()
        h.world.offline = true
        h.hold("a")
        h.world.analyses["a"] = h.row("a")
        h.store.show(h.song("a"))
        #expect(await h.until { !h.store.music.lookingUp })
        #expect(h.world.lookups.isEmpty)
        #expect(h.world.measures.isEmpty)

        h.world.offline = false
        h.store.connectionReturned()
        #expect(await h.until { h.world.lookups == ["a"] })
        #expect(await h.until { !h.store.music.lookingUp })
    }

    @Test("offline with a song that needs measuring says Offline and starts nothing")
    func offlineProblem() async {
        let h = FactsHarness()
        h.world.offline = true
        h.hold("a")
        h.world.cached["a"] = MusicSongFactsCached(facts: nil, lookupIsFresh: true, measureAttempted: false)
        h.store.show(h.song("a"))
        #expect(await h.until { h.store.music.problem == .offline })
        #expect(h.world.measures.isEmpty)
    }

    @Test("a file on this Mac is measured even offline")
    func fileOffline() async {
        let h = FactsHarness()
        h.world.offline = true
        h.hold("a", file: true)
        h.world.cached["a"] = MusicSongFactsCached(facts: nil, lookupIsFresh: true, measureAttempted: false)
        h.store.show(h.song("a"))
        #expect(await h.until { !h.world.measures.isEmpty })
        #expect(h.store.music.problem == nil)
    }

    @Test("signed out: nothing is measured and the panel says so quietly")
    func signedOut() async {
        let h = FactsHarness()
        h.world.signedOut = true
        h.hold("a")
        h.world.cached["a"] = MusicSongFactsCached(facts: nil, lookupIsFresh: true, measureAttempted: false)
        h.store.show(h.song("a"))
        #expect(await h.until { h.store.music.problem == .signedOut })
        #expect(h.world.measures.isEmpty)
    }

    @Test("a stream that could not be had says it could not, quietly")
    func streamUnavailable() async {
        let h = FactsHarness()
        h.world.cached["a"] = MusicSongFactsCached(facts: nil, lookupIsFresh: true, measureAttempted: false)
        await h.backend.setResolveError("a", MusicError.noAudioFormat)
        h.store.show(h.song("a"))
        #expect(await h.until { h.store.music.problem != nil })
        #expect(h.store.music.problem == .failed)
    }

    @Test("a measure that met a rate limit says so and ends the Measuring text")
    func rateLimited() async {
        let h = FactsHarness()
        h.hold("a")
        h.world.cached["a"] = MusicSongFactsCached(facts: nil, lookupIsFresh: true, measureAttempted: false)
        h.world.measureResult = MusicSongMeasureResult(problem: .rateLimited)
        h.store.show(h.song("a"))
        #expect(await h.until { h.store.music.problem == .rateLimited })
        #expect(h.store.music.measuringTempo == false)
        #expect(h.store.music.measuringAnalysis == false)
    }

    @Test("a store with no facts side neither looks up nor measures")
    func noFactsSide() async {
        let h = FactsHarness(withFacts: false)
        h.hold("a")
        h.store.show(h.song("a"))
        await h.letLateWorkLand()
        #expect(h.store.music.lookingUp == false)
        #expect(h.store.music.facts == nil)
        #expect(h.store.music.problem == nil)
    }
}
