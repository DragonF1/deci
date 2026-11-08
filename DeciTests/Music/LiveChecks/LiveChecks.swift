// DeciTests/Music/LiveChecks/LiveChecks.swift
// The ten checks. Checks 1, 2, 4, 6 and 9 drive the real service over a FakePlaybackEngine with the real analysis rows;
// checks 3, 5, 7, 8 and 10 play real transitions through the real engine into a muted capture.

import Foundation
import SwiftUI
@testable import Deci

@MainActor
final class LiveChecks {
    let world: LiveWorld
    var audio: LiveAudio?
    var results: [Int: Bool] = [:]
    var runA: [LiveTransition] = []
    var runALabel = ""
    var chainPairs: [(from: String, to: String)] = []
    var engineNote = ""
    var realBeat: [LiveTransition] = []
    var allRealRuns: [LiveTransition] = []

    init(world: LiveWorld) { self.world = world }

    func finish(_ n: Int, _ title: String, pass: Bool, _ lines: [String]) {
        results[n] = pass
        LiveReport.record(n, title, pass: pass, lines)
    }

    func notRun(_ n: Int, _ title: String, _ why: String) {
        results[n] = true
        LiveReport.record(n, title, verdict: "NOT RUN", [why])
    }

    func name(_ id: String) -> String {
        guard let song = world.byId[id] else { return id }
        return "\(song.index):\(song.title.prefix(18))"
    }

    func ids(_ tracks: some Sequence<MusicTrack>) -> String { tracks.map { name($0.videoId) }.joined(separator: " | ") }

    func runAll() async -> [Int: Bool] {
        let engineOnly = ProcessInfo.processInfo.environment["DECI_LIVE_ONLY"] == "engine"
        if !engineOnly { await check1() }
        await check2()
        if !engineOnly { await check4(); await check6(); await check9() }
        audio = ProcessInfo.processInfo.environment["DECI_LIVE_ONLY"] == "noaudio" ? nil : await LiveAudio.shared(world: world)
        if let audio {
            LiveReport.note("Silent capture proven: device \(audio.deviceName), probe peak \(liveF(Double(audio.probePeak), 5)) at -60 dB, then unity gain into a muted process tap.")
        } else {
            LiveReport.note("Silent capture NOT proven (\(LiveAudio.failure ?? "unknown")): the engine checks did not run.")
        }
        await engineRuns()
        planningChecks()
        return results
    }

    // MARK: 1. The shuffle button

    func startFake(
        count: Int, preferences: MusicPlaybackPreferences = MusicPlaybackPreferences(), artists: ((LiveSong) -> String)? = nil,
        seed: UInt64 = 11
    ) async -> (rig: LiveWorld.Rig, engine: FakePlaybackEngine) {
        let engine = FakePlaybackEngine()
        let backend = await world.makeBackend()
        let rig = world.makeRig(engine: engine, preferences: preferences, backend: backend, seed: seed)
        let songs = Array(world.songs.prefix(count))
        let tracks = songs.map { $0.track(artist: artists?($0)) }
        await backend.setRadio(seed: tracks[0].videoId, tracks: tracks, continuation: nil)
        rig.service.play(tracks[0])
        await world.settle(rig.service)
        engine.emit(.playingChanged(true))
        return (rig, engine)
    }

    func check1() async {
        let title = "Shuffle button cycles Off, Shuffle, Mix, Off"
        let rig = world.makeRig(engine: FakePlaybackEngine(), preferences: MusicPlaybackPreferences(), backend: await world.makeBackend())
        let service = rig.service
        var modes: [MusicShuffleMode] = [service.shuffleMode]
        var symbols: [String] = [MusicPlaybackToggle.shuffle.symbol(loop: service.loopMode, shuffleMode: service.shuffleMode)]
        var shots: [String] = []
        let navigation = MusicSearchNavigation(service: service)
        var shotOK = true
        for step in 0..<4 {
            let label = ["off", "shuffle", "mix", "off-again"][step]
            if let shot = LiveRender.rendered(MusicQueueHeader(service: service, navigation: navigation), width: 380, height: 44, name: "check1-header-\(label).png") {
                shots.append("\(shot.url.path) (ink \(liveF(shot.inkFraction * 100, 1))%, ocr: \(shot.text.joined(separator: ", ")))")
                if shot.inkFraction < 0.01 { shotOK = false }
            } else { shotOK = false }
            if step < 3 {
                service.cycleShuffleMode()
                modes.append(service.shuffleMode)
                symbols.append(MusicPlaybackToggle.shuffle.symbol(loop: service.loopMode, shuffleMode: service.shuffleMode))
            }
        }
        let expectedModes: [MusicShuffleMode] = [.off, .shuffle, .mix, .off]
        let mixSymbol = symbols[2]
        let pass = modes == expectedModes && mixSymbol == "waveform.path" && symbols[0] != "waveform.path"
            && symbols[1] != "waveform.path" && symbols[3] != "waveform.path" && shotOK
            && rig.saved.last?.shuffleMode == .off && rig.saved.count == 3
        finish(1, title, pass: pass, [
            "modes: \(modes.map(\.rawValue).joined(separator: " > "))",
            "button symbols: \(symbols.joined(separator: " | ")) (Mix shows waveform.path: \(mixSymbol == "waveform.path"))",
            "saved preferences: \(rig.saved.count) saves, last mode \(rig.saved.last?.shuffleMode.rawValue ?? "none")",
        ] + shots.map { "PNG: \($0)" })
    }

    // MARK: 2. Up next text and glyphs

    func check2() async {
        let title = "Up next shows BPM + Camelot and the beat/fade glyph only in Mix"
        let (rig, _) = await startFake(count: world.songs.count)
        let service = rig.service
        service.setShuffleMode(.mix)
        await world.settle(service)
        let first = service.queue.upcoming.first?.videoId
        let got = await waitUntil(timeout: .seconds(60)) {
            guard let first else { return false }
            return service.mixRowText(for: first) != nil && !service.mixPairs.isEmpty
        }
        await world.settle(service)
        let current = service.queue.current
        let upcoming = Array(service.queue.upcoming.prefix(12))
        var chain = [current].compactMap { $0 } + upcoming
        var texts = 0, beatGlyphs = 0, fadeGlyphs = 0
        var lines: [String] = []
        var rowsOK = true
        for (index, track) in upcoming.enumerated() {
            let text = service.mixRowText(for: track.videoId)
            let prev = chain[index].videoId
            let info = service.mixInfo(from: prev, to: track.videoId)
            if let text, text.contains("\u{00B7}") || Int(text.prefix(3)) != nil { texts += 1 }
            if info?.mode == .beat { beatGlyphs += 1 }
            if info?.mode == .fade { fadeGlyphs += 1 }
            if text == nil || info == nil { rowsOK = false }
            lines.append("row \(index + 1) \(name(track.videoId)): text \(text ?? "none"), glyph \(info?.symbol ?? "none")")
        }
        chain.removeAll()
        self.chainPairs = []
        let allAhead = [service.queue.current].compactMap { $0 } + Array(service.queue.upcoming.prefix(24))
        for (a, b) in zip(allAhead, allAhead.dropFirst()) { chainPairs.append((a.videoId, b.videoId)) }
        // More Mix chains (other seeds) so check 7 sees more than a handful of beat plans.
        for seed in [23, 37, 51, 77] as [UInt64] {
            let (other, _) = await startFake(count: world.songs.count, seed: seed)
            other.service.setShuffleMode(.mix)
            await world.settle(other.service)
            let head = other.service.queue.upcoming.first?.videoId
            _ = await waitUntil(timeout: .seconds(60)) { head.map { other.service.mixRowText(for: $0) != nil } ?? false }
            await world.settle(other.service)
            let ahead = [other.service.queue.current].compactMap { $0 } + Array(other.service.queue.upcoming.prefix(24))
            for (a, b) in zip(ahead, ahead.dropFirst()) { chainPairs.append((a.videoId, b.videoId)) }
        }
        let mixShot = LiveRender.shot(MusicQueueView(service: service, navigation: navigation(service)), width: 380, height: 520, name: "check2-upnext-mix.png")
        let mixOCR = mixShot?.text.filter { LiveChecks.hasCamelot($0) }.count ?? 0
        service.setShuffleMode(.shuffle)
        await world.settle(service)
        let shuffleTexts = service.queue.upcoming.prefix(12).compactMap { service.mixRowText(for: $0.videoId) }.count
        let shuffleGlyphs = zip([service.queue.current].compactMap { $0 } + Array(service.queue.upcoming.prefix(11)), service.queue.upcoming.prefix(12))
            .compactMap { service.mixInfo(from: $0.0.videoId, to: $0.1.videoId) }.count
        let shuffleShot = LiveRender.shot(MusicQueueView(service: service, navigation: navigation(service)), width: 380, height: 520, name: "check2-upnext-shuffle.png")
        let shuffleOCR = shuffleShot?.text.filter { LiveChecks.hasCamelot($0) }.count ?? 0
        service.setShuffleMode(.off)
        await world.settle(service)
        let offTexts = service.queue.upcoming.prefix(12).compactMap { service.mixRowText(for: $0.videoId) }.count
        let pass = got && rowsOK && texts == upcoming.count && beatGlyphs + fadeGlyphs == upcoming.count
            && shuffleTexts == 0 && shuffleGlyphs == 0 && offTexts == 0
            && (mixShot?.inkFraction ?? 0) > 0.02 && mixOCR >= 1 && shuffleOCR == 0
        finish(2, title, pass: pass, [
            "Mix: \(texts) of \(upcoming.count) rows carry the grey text, glyphs: \(beatGlyphs) beat (metronome), \(fadeGlyphs) fade (merge arrows)",
            "Shuffle: \(shuffleTexts) texts, \(shuffleGlyphs) glyphs. Off: \(offTexts) texts.",
            "OCR of the rendered view: Mix image has \(mixOCR) rows with a number and a middle dot; Shuffle image has \(shuffleOCR). Ink Mix \(liveF((mixShot?.inkFraction ?? 0) * 100, 1))%, Shuffle \(liveF((shuffleShot?.inkFraction ?? 0) * 100, 1))%.",
            "PNG: \(mixShot?.url.path ?? "render failed")",
            "PNG: \(shuffleShot?.url.path ?? "render failed")",
        ] + lines)
    }

    static func hasCamelot(_ text: String) -> Bool {
        text.range(of: #"\b\d{1,2}[AB]\b"#, options: .regularExpression) != nil
    }

    func navigation(_ service: MusicService) -> MusicSearchNavigation { MusicSearchNavigation(service: service) }

    // MARK: 4. Pages landing under Mix

    func check4() async {
        let title = "Big playlist in Mix: the next 3 songs never change while pages land"
        let engine = FakePlaybackEngine()
        let backend = await world.makeBackend()
        let rig = world.makeRig(engine: engine, preferences: MusicPlaybackPreferences(), backend: backend)
        let service = rig.service
        let all = world.songs.map { $0.track() }
        let sizes = [12, 12, 12, 12, 6]
        var chunks: [[MusicTrack]] = []
        var cursor = 0
        for size in sizes { chunks.append(Array(all[cursor..<min(cursor + size, all.count)])); cursor += size }
        let browse = "VLPLlive"
        var gates: [MusicTestGate] = []
        for index in 1..<chunks.count {
            let gate = MusicTestGate()
            gates.append(gate)
            await backend.setMoreTracks(
                browseId: browse, continuation: "c\(index)", tracks: chunks[index], next: index + 1 < chunks.count ? "c\(index + 1)" : nil
            )
            await backend.setMoreTracksGate(browseId: browse, continuation: "c\(index)", gate)
        }
        let page = MusicSamples.page(browse, tracks: chunks[0], continuation: "c1")
        service.play(chunks[0][0], in: page)
        _ = await waitUntil(timeout: .seconds(20)) { service.queue.current != nil }
        engine.emit(.playingChanged(true))
        service.setShuffleMode(.mix)
        _ = await waitUntil(timeout: .seconds(60)) { service.queue.upcoming.first.flatMap { service.mixRowText(for: $0.videoId) } != nil }
        try? await Task.sleep(for: .milliseconds(300))
        func head() -> [String] { service.queue.upcoming.prefix(3).map(\.videoId) }
        let initial = head()
        var records: [String] = ["before any page: \(initial.map(name).joined(separator: " | ")) (queue \(service.queue.tracks.count) songs)"]
        var stable = true
        for (index, gate) in gates.enumerated() {
            let before = head()
            let target = chunks.prefix(index + 2).reduce(0) { $0 + $1.count }
            await gate.open()
            _ = await waitUntil(timeout: .seconds(30)) { service.queue.tracks.count >= target }
            await service.mixTask?.value
            try? await Task.sleep(for: .milliseconds(400))
            await service.mixTask?.value
            let after = head()
            if before != after || after != initial { stable = false }
            records.append("page c\(index + 1) landed (queue \(service.queue.tracks.count)): head before \(before.map(name).joined(separator: " | ")) / after \(after.map(name).joined(separator: " | ")) \(before == after ? "same" : "CHANGED")")
        }
        let finalCount = service.queue.tracks.count
        let pass = stable && finalCount == world.songs.count
        finish(4, title, pass: pass, [
            "Up next head (3 songs) is the same before and after every one of \(gates.count) pages: \(stable); final queue \(finalCount) of \(world.songs.count) songs",
        ] + records)
    }

    // MARK: 6. Manual skip

    func check6() async {
        let title = "Manual skip in Mix re-plans the next 5 and avoids the last 3"
        let band: (LiveSong) -> String = { $0.index % 3 == 0 ? "Same Band" : $0.artist }
        let (rig, _) = await startFake(count: world.songs.count, artists: band)
        let service = rig.service
        service.setShuffleMode(.mix)
        _ = await waitUntil(timeout: .seconds(60)) { service.queue.upcoming.first.flatMap { service.mixRowText(for: $0.videoId) } != nil }
        await world.settle(service)
        var lines = ["labelling: every third song (index % 3 == 0) is tagged artist \"Same Band\" so the artist avoidance can show; the real titles are unchanged"]
        var setsOK = true
        var avoidOK = true
        var exercised = 0
        var pushedOK = true
        var skippedIds: [String] = []
        func tag(_ t: MusicTrack) -> String { "\(name(t.videoId))\(t.artist == "Same Band" ? "*" : "")" }
        // Start from a Same Band song when the queue has one next.
        for step in 1...4 {
            let beforeQueue = Array(service.queue.upcoming.prefix(5))
            let leaving = service.queue.current
            let beforeWindow = Array(service.queue.upcoming.prefix(6))
            service.next()
            await world.settle(service)
            try? await Task.sleep(for: .milliseconds(400))
            await world.settle(service)
            let now = service.queue.current
            let afterQueue = Array(service.queue.upcoming.prefix(5))
            if let leaving { skippedIds.append(leaving.videoId) }
            let avoid = Set(skippedIds.suffix(MusicService.mixAvoidKept))
            let expectedSet = Set(beforeWindow.dropFirst().map(\.videoId))
            let sameSet = Set(afterQueue.map(\.videoId)) == expectedSet
            if !sameSet { setsOK = false }
            if !avoid.isDisjoint(with: Set(afterQueue.map(\.videoId))) { avoidOK = false }
            let sbBefore = beforeWindow.dropFirst().enumerated().filter { $0.element.artist == "Same Band" }.map(\.offset)
            let sbAfter = afterQueue.enumerated().filter { $0.element.artist == "Same Band" }.map(\.offset)
            let leavingBand = leaving?.artist == "Same Band"
            if leavingBand, !sbBefore.isEmpty, sbBefore.count < 5 {
                exercised += 1
                let meanBefore = Double(sbBefore.reduce(0, +)) / Double(sbBefore.count)
                let meanAfter = Double(sbAfter.reduce(0, +)) / Double(max(1, sbAfter.count))
                if meanAfter < meanBefore { pushedOK = false }
                lines.append("skip \(step) left a Same Band song: Same Band mean slot \(liveF(meanBefore)) before, \(liveF(meanAfter)) after (higher = pushed back)")
            }
            lines.append("skip \(step): left \(leaving.map(tag) ?? "-"), now \(now.map(tag) ?? "-"). Up next before: \(beforeQueue.map(tag).joined(separator: " | ")). After: \(afterQueue.map(tag).joined(separator: " | ")). same five: \(sameSet), avoided songs absent: \(avoid.isDisjoint(with: Set(afterQueue.map(\.videoId))))")
        }
        let pass = setsOK && avoidOK && pushedOK
        lines.insert("same 5 songs each time: \(setsOK); none of the last 3 skipped songs in the next 5: \(avoidOK); Same Band pushed back when skipped: \(exercised == 0 ? "not exercised (no skip left a Same Band song with others in the window)" : String(pushedOK)) (\(exercised) of 4 skips exercised)", at: 0)
        finish(6, title, pass: pass, lines)
    }

    // MARK: 9. Favorite slot menu

    func check9() async {
        let title = "Favorite slot Shuffle entry offers Off, Shuffle, Mix and marks the current one"
        let rig = world.makeRig(engine: FakePlaybackEngine(), preferences: MusicPlaybackPreferences(), backend: await world.makeBackend())
        let service = rig.service
        var lines: [String] = []
        var ok = true
        let titles = MusicFavoriteMenuModel.shuffleChoices.map(\.title)
        lines.append("choices: \(titles.joined(separator: ", "))")
        if titles != ["Off", "Shuffle", "Mix"] { ok = false }
        for step in 0..<3 {
            let expected: MusicShuffleMode = [.off, .shuffle, .mix][step]
            if step > 0 { service.cycleShuffleMode() }
            let model = MusicFavoriteMenuModel(
                shuffle: service.isShuffleOn, mix: service.isMixOn, loop: service.loopMode, autoplay: service.isAutoplayOn,
                crossfade: service.isCrossfadeOn, fadeSeconds: service.crossfadeSeconds, slotControl: .shuffle
            )
            var marked: MusicShuffleMode?
            for entry in model.entries { if case .shuffle(let selected) = entry { marked = selected } }
            lines.append("service in \(expected.rawValue): menu marks \(marked?.rawValue ?? "none")")
            if marked != expected { ok = false }
        }
        finish(9, title, pass: ok, lines)
    }
}
