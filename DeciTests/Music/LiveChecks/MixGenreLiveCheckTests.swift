// DeciTests/Music/LiveChecks/MixGenreLiveCheckTests.swift
// Opt-in (TEST_RUNNER_DECI_LIVE=1): what the genres of real songs do to the plans. The tags come from the real services, once, and
// are kept in genre-tags.json next to the report. First the numbers on paper for every ordered pair, with and without the tags,
// then a few pairs through the real MusicService and two-deck engine into the muted capture. Numbers go to style-report.txt.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MixGenreLiveCheckTests", .serialized, .enabled(if: liveGate))
struct MixGenreLiveCheckTests {
    typealias Style = MixStyleLiveCheckTests

    private static let tagsURL = LiveDirs.root.appendingPathComponent("genre-tags.json")

    private func tags(_ world: LiveWorld) async -> [String: [String]] {
        var known = (try? Data(contentsOf: Self.tagsURL)).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        let client = MusicSongFactsClient.live()
        for song in world.songs where known[song.videoId] == nil {
            let query = MusicSongFactsQuery(artist: song.artist, title: song.title, durationSeconds: nil)
            switch await client.lookup(query) {
            case .found(let facts), .partial(let facts): known[song.videoId] = facts.tags ?? []
            case .notFound: known[song.videoId] = []
            case .failed: continue
            }
            try? JSONEncoder().encode(known).write(to: Self.tagsURL, options: .atomic)
        }
        return known
    }

    private func inputs(_ world: LiveWorld, _ a: LiveSong, _ b: LiveSong, tagged: Bool) -> MusicTransitionInputs? {
        guard var i = Style.inputs(world, a, b) else { return nil }
        i.outgoing.vocalIntervals = world.lyricIntervals[a.videoId]
        i.incoming.vocalIntervals = world.lyricIntervals[b.videoId]
        i.outgoing.lyricCues = world.lyricLines[a.videoId].map { MusicLyricCues.from(lines: $0, duration: a.duration) }
        i.incoming.lyricCues = world.lyricLines[b.videoId].map { MusicLyricCues.from(lines: $0, duration: b.duration) }
        i.vocalGuardEnabled = true
        i.djLength = true
        if tagged {
            i.outgoing.genres = world.genreTags[a.videoId] ?? []
            i.incoming.genres = world.genreTags[b.videoId] ?? []
        }
        return i
    }

    private func count(_ plans: [TransitionPlan]) -> String {
        let styles = Dictionary(grouping: plans) { $0.style.rawValue }.mapValues(\.count).sorted { $0.key < $1.key }
        let bars = Dictionary(grouping: plans.filter { $0.style == .longBlend }) { $0.overlapBars }.mapValues(\.count).sorted { $0.key < $1.key }
        return "styles \(styles.map { "\($0.key)=\($0.value)" }.joined(separator: " ")); blend bars \(bars.map { "\($0.key)=\($0.value)" }.joined(separator: " "))"
    }

    @Test("real songs are mixed the way their genres are")
    func genres() async throws {
        let world = try await LiveWorld.shared()
        guard let audio = await LiveAudio.shared(world: world) else { Issue.record("capture not proven: \(LiveAudio.failure ?? "?")"); return }
        LiveSong.forceLocal = true
        defer { LiveAudio.end(); LiveSong.forceLocal = false; world.genreTags = [:] }
        Style.note("== Genres \(Date())")
        world.genreTags = await tags(world)
        var tagged = 0
        for song in world.songs {
            guard let row = world.rows[song.videoId] else { continue }
            var side = MusicTransitionPlannerTests.side(song.videoId, duration: song.duration, analysis: row)
            let guess = MusicGenre(of: side)
            side.genres = world.genreTags[song.videoId] ?? []
            let genre = MusicGenre(of: side)
            if !genre.isGuess { tagged += 1 }
            Style.note("  \(song.artist) - \(song.title): \(genre.family.rawValue)\(genre.isGuess ? " (guess)" : ""), guess alone \(guess.family.rawValue), bpm \(liveF(row.usableGrid?.bpm ?? .nan, 1)), tags \(side.genres.joined(separator: ", "))")
        }
        #expect(tagged * 2 > world.songs.count, "only \(tagged) of \(world.songs.count) songs have a genre")

        var plans: [(a: LiveSong, b: LiveSong, plan: TransitionPlan, cuts: Bool)] = []
        var before: [TransitionPlan] = []
        for (a, b) in Style.allPairs(world) {
            guard let plain = inputs(world, a, b, tagged: false), let i = inputs(world, a, b, tagged: true) else { continue }
            before.append(MusicTransitionPlanner.plan(plain))
            plans.append((a, b, MusicTransitionPlanner.plan(i), MusicMixHabits.pair(for: i).cutsOnSections))
        }
        Style.note("pairs \(plans.count), tagged songs \(tagged) of \(world.songs.count)")
        Style.note("  without tags: \(count(before))")
        Style.note("  with tags:    \(count(plans.map(\.plan)))")
        let early = plans.filter { $0.plan.style.isCutLike }
        Style.note("  cuts and echoes: \(early.count), at a DJ exit \(early.filter { $0.plan.djSection != nil }.count), share of the song played min \(liveF(early.map { ($0.plan.mixOutSec ?? $0.a.duration) / $0.a.duration }.min() ?? .nan, 2))")
        // A cut in the middle of a song is only right at a section end, between genres that are cut.
        for p in early where (p.plan.mixOutSec ?? p.a.duration) < p.a.duration - 30 {
            #expect(p.plan.djSection != nil && p.cuts, "\(p.a.title) > \(p.b.title)")
        }

        // Cuts and echoes out of the middle first, then the 4 bar blends, then the 8 bar ones; each song once.
        var seen = Set<String>(), proved = 0
        let order = early.filter { $0.plan.djSection != nil }.prefix(6) + plans.filter { $0.plan.overlapBars == 4 }.prefix(6)
            + plans.filter { $0.plan.overlapBars == 8 && $0.plan.style == .longBlend && $0.cuts }.prefix(6)
        var perKind: [String: Int] = [:]
        for p in order where proved < 5 && !seen.contains(p.a.videoId) && !seen.contains(p.b.videoId) {
            let kind = p.plan.style.isCutLike ? "cut" : "\(p.plan.overlapBars) bars"
            guard perKind[kind, default: 0] < 2 else { continue }
            if await play(world, audio, p.a, p.b, p.plan) {
                proved += 1
                perKind[kind, default: 0] += 1
                seen.formUnion([p.a.videoId, p.b.videoId])
            }
        }
        #expect(proved >= 3, "only \(proved) real pairs were played")
    }

    private func play(_ world: LiveWorld, _ audio: LiveAudio, _ a: LiveSong, _ b: LiveSong, _ pure: TransitionPlan) async -> Bool {
        MusicRenderRecorder.mutesOutput = true
        let checks = LiveChecks(world: world)
        checks.audio = audio
        let leaves = pure.djSection == nil ? nil : pure.mixOutSec
        let out = await checks.realRun(audio, beatMix: true, count: 1, tracks: [a.track(), b.track()], leavesAt: leaves)
        let name = "\(a.title) > \(b.title)"
        guard let t = out.transitions.first, t.crossfaded, let genre = t.lines.compactMap(LiveLine.init).last(where: { $0.name == "transition_genre" }) else {
            Style.note("  \(name): not played (\(out.transitions.first?.failure ?? "no overlap or no genre line"))"); return false
        }
        let style = t.lines.compactMap(LiveLine.init).last { $0.name == "transition_style" }?.kv["style"] ?? "longBlend"
        Style.note("  \(name): out=\(genre.kv["out"] ?? "-") in=\(genre.kv["in"] ?? "-") bars=\(genre.kv["bars"] ?? "-") cuts=\(genre.kv["cuts"] ?? "-"); pure \(pure.style.rawValue) \(pure.overlapBars) bars, played \(style), left at \(liveF(t.mixOut ?? .nan)) of \(liveF(a.duration)) s, heard overlap \(liveF(t.overlapSec)) s; dropouts=\(t.dropouts) nonFinite=\(t.nonFinite) stalls=\(t.stalls) rateWrites=\(t.engineRateWrites) peak \(liveF(Double(t.capturePeak), 3)) \(t.dropoutDetail)")
        #expect(style == pure.style.rawValue)
        #expect(t.dropouts == 0, "dropouts \(t.dropoutDetail)")
        #expect(t.nonFinite == 0)
        #expect(t.engineRateWrites == 0)
        return true
    }
}
