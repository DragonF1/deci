// Deci/Views/Music/MusicSpectrum.swift
import Foundation
import Observation

// The player column's vertical spectrum, which is also the song's progress bar: 28 bars from the start of the song at
// the top to the end at the bottom. The model is kept apart from the views, so it is tested without drawing anything.
// Unplayed bars follow a seeded curve (the design's), the same for a song every time. As the song plays, each bar that
// gets played takes the real loudness heard for its slice, so the waveform writes itself, and the bar under the
// playhead pulses calmly with the live level.

/// The measures and rules of the spectrum.
nonisolated enum MusicSpectrum {
    static let barCount = 28
    static let boxWidth: Double = 142
    static let boxHeight: Double = 104
    static let barThickness: Double = 2

    /// The distance between two bars' tops: the box less one bar, over the 27 gaps.
    static let pitch: Double = (boxHeight - barThickness) / Double(barCount - 1)

    /// The shortest a bar gets, as a level. Levels run from here to 1.
    static let minLevel: Double = 0.08

    /// The playhead's step per bar in the design, which differs a hair from `pitch`.
    private static let playheadStep: Double = 3.78

    // MARK: - The seeded curve

    static let lcgModulus = 233_280

    /// One step of the design's generator: s = (s x 9301 + 49297) mod 233280.
    static func lcgNext(_ state: Int) -> Int {
        (state * 9301 + 49297) % lcgModulus
    }

    /// A song's seed: the FNV-1a of its id (the same on every run), inside the generator's modulus.
    static func seed(forVideoId videoId: String) -> Int {
        Int(MusicHash.fnv1a(videoId) % UInt64(lcgModulus))
    }

    /// The design's curve for `count` bars: a slow wave with a little noise from the generator, tapered at both ends and
    /// held to 0.08...1.
    static func seededLevels(seed: Int, count: Int = barCount) -> [Double] {
        var state = seed % lcgModulus
        var levels: [Double] = []
        levels.reserveCapacity(max(0, count))
        for i in 0..<max(0, count) {
            state = lcgNext(state)
            let noise = Double(state) / Double(lcgModulus)
            let q = Double(i) * 60 / Double(count)
            var value = 0.42 + 0.22 * sin(0.37 * q) + 0.18 * sin(0.13 * q + 1.1) + 0.3 * (noise - 0.5)
            value *= min(1, Double(i + 3) / 8, Double(count - i + 2) / 8)
            levels.append(min(max(value, minLevel), 1))
        }
        return levels
    }

    // MARK: - Drawing

    /// A bar's width for its level: 8 + 120 x level, rounded to a half point, so 8 to 128 across the box.
    static func width(forLevel level: Double) -> Double {
        guard level.isFinite else { return 8 }
        let clamped = min(max(level, 0), 1)
        return (2 * (8 + 120 * clamped)).rounded() / 2
    }

    /// The top of bar `index` in the box.
    static func barY(_ index: Int) -> Double {
        Double(index) * pitch
    }

    /// How many bars are played: the floor of progress x 28. The tiny nudge keeps a position that sits exactly on a bar
    /// edge, such as 12/28, from rounding down to the bar before.
    static func playedCount(progress: Double) -> Int {
        guard progress.isFinite else { return 0 }
        let count = (min(max(progress, 0), 1) * Double(barCount) + 1e-9).rounded(.down)
        return min(max(Int(count), 0), barCount)
    }

    /// The playhead line's top: round(played x 3.78) - 1.5, kept inside the box.
    static func playheadY(playedCount: Int) -> Double {
        let y = (Double(playedCount) * playheadStep).rounded() - 1.5
        return min(max(y, 0), boxHeight - 1)
    }

    // MARK: - Seeking

    /// Where a click at `y` points along the song, 0...1: the top of the box is the start, the bottom the end.
    static func progress(atY y: Double) -> Double {
        guard y.isFinite else { return 0 }
        return min(max(y / boxHeight, 0), 1)
    }

    /// The position in seconds a click at `y` seeks to.
    static func seekTime(atY y: Double, duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return progress(atY: y) * duration
    }

    /// Where the preview line is drawn for a pointer at `y`: under the pointer, inside the box.
    static func previewLineY(atY y: Double) -> Double {
        guard y.isFinite else { return 0 }
        return min(max(y, 0), boxHeight - 1)
    }

    // MARK: - Real levels

    /// The quietest and loudest buffer RMS that map to a bar, in dB. Music sits mid-range, so the bars have room to
    /// move both ways.
    private static let floorDecibels = -36.0
    private static let ceilingDecibels = -6.0

    /// A buffer's RMS as a bar level in 0.08...1, or nil when there is no sound to measure (silence, or a reading that
    /// is not a number), which never becomes a bar.
    static func level(forRMS rms: Float) -> Double? {
        guard rms.isFinite, rms > 0 else { return nil }
        let decibels = 20 * log10(Double(rms))
        let t = (decibels - floorDecibels) / (ceilingDecibels - floorDecibels)
        return min(max(minLevel + (1 - minLevel) * t, minLevel), 1)
    }

    // MARK: - The pulse

    /// How fast the playhead bar chases a louder level, and how slowly it lets go of it, per poll.
    static let attack = 0.3
    static let release = 0.1

    /// One poll of the pulse: a step toward `target`, quick on the way up and slow on the way down.
    static func smoothed(current: Double, target: Double) -> Double {
        current + (target - current) * (target > current ? attack : release)
    }
}

/// One song's bars: the seeded curve, with each slice replaced by the average loudness heard in it once it has been.
nonisolated struct MusicSpectrumTrack: Equatable, Sendable {
    private let seeded: [Double]
    private var sums: [Double]
    private var counts: [Int]

    init(videoId: String) {
        seeded = MusicSpectrum.seededLevels(seed: MusicSpectrum.seed(forVideoId: videoId))
        sums = Array(repeating: 0, count: MusicSpectrum.barCount)
        counts = Array(repeating: 0, count: MusicSpectrum.barCount)
    }

    /// The slice of the song at `progress`: the bar it belongs to.
    static func slice(atProgress progress: Double) -> Int {
        guard progress.isFinite else { return 0 }
        let index = Int((min(max(progress, 0), 1) * Double(MusicSpectrum.barCount)).rounded(.down))
        return min(max(index, 0), MusicSpectrum.barCount - 1)
    }

    /// How many slices have a heard level.
    var capturedSlices: Int { counts.filter { $0 > 0 }.count }

    /// The level of each bar: what was heard where something was, the seeded curve elsewhere.
    var levels: [Double] {
        (0..<MusicSpectrum.barCount).map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : seeded[$0] }
    }

    /// Notes the level heard at `progress`. Silence and readings that are not numbers are ignored.
    mutating func capture(level: Double, progress: Double) {
        guard level.isFinite, level > 0, progress.isFinite else { return }
        let slice = Self.slice(atProgress: progress)
        sums[slice] += min(max(level, MusicSpectrum.minLevel), 1)
        counts[slice] += 1
    }
}

/// The songs heard lately and what their bars captured, least recently used out first. Small: a song is 28 numbers.
nonisolated struct MusicSpectrumMemory: Equatable, Sendable {
    static let defaultCapacity = 32

    private let capacity: Int
    private var tracks: [String: MusicSpectrumTrack] = [:]
    /// Oldest first.
    private var order: [String] = []

    init(capacity: Int = Self.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    var count: Int { tracks.count }

    func contains(_ videoId: String) -> Bool { tracks[videoId] != nil }

    /// The bars of a song: what was captured, or its seeded curve. Reading stores nothing.
    func levels(for videoId: String) -> [Double] {
        (tracks[videoId] ?? MusicSpectrumTrack(videoId: videoId)).levels
    }

    /// Notes the level heard at `progress` of a song, and counts the song as the one most recently used.
    mutating func capture(videoId: String, level: Double, progress: Double) {
        var track = tracks[videoId] ?? MusicSpectrumTrack(videoId: videoId)
        track.capture(level: level, progress: progress)
        tracks[videoId] = track
        order.removeAll { $0 == videoId }
        order.append(videoId)
        while order.count > capacity {
            tracks[order.removeFirst()] = nil
        }
    }
}

/// Polls the live level while the Music popup is on screen and a song plays, writes it into the song's bars and pulses
/// the bar under the playhead. Where the numbers come from is injected, so a poll is tested without audio.
@MainActor
@Observable
final class MusicSpectrumDriver {
    struct Sources {
        /// The loudest buffer RMS since the last call (reading resets it).
        var level: @MainActor () -> Float
        /// The song's live position, in seconds.
        var position: @MainActor () -> TimeInterval
        var duration: @MainActor () -> TimeInterval
        var videoId: @MainActor () -> String?

        static let none = Sources(level: { 0 }, position: { 0 }, duration: { 0 }, videoId: { nil })
    }

    /// About 30 polls a second.
    static let interval: TimeInterval = 1.0 / 30.0

    @ObservationIgnored var sources: Sources
    private(set) var memory: MusicSpectrumMemory
    /// The level of the bar under the playhead, smoothed; nil while the bars rest.
    private(set) var pulse: Double?
    private(set) var pulseIndex = 0
    /// How far along the song is as of the last poll; nil while the bars rest.
    private(set) var progress: Double?
    private(set) var isActive = false

    @ObservationIgnored private var pulseVideoId: String?
    @ObservationIgnored private var timer: Timer?

    init(sources: Sources = .none, memory: MusicSpectrumMemory = MusicSpectrumMemory()) {
        self.sources = sources
        self.memory = memory
    }

    /// Starts or stops polling. Stopping leaves the bars at rest.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        timer?.invalidate()
        timer = nil
        if active {
            // The level kept while the popup was closed is old news: drop it, so the first poll hears now.
            _ = sources.level()
            timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } else {
            rest()
        }
    }

    /// The bars rest: no pulse, no live position.
    func rest() {
        pulse = nil
        progress = nil
        pulseVideoId = nil
    }

    /// One poll.
    func tick() {
        let heard = sources.level()
        let duration = sources.duration()
        guard let videoId = sources.videoId(), duration.isFinite, duration > 0 else {
            rest()
            return
        }
        let position = sources.position()
        let fraction = MusicTimeFormat.progress(current: position, duration: duration)
        progress = fraction
        let index = MusicSpectrumTrack.slice(atProgress: fraction)
        let mapped = MusicSpectrum.level(forRMS: heard)

        if let mapped {
            memory.capture(videoId: videoId, level: mapped, progress: fraction)
        }
        if pulseVideoId != videoId {
            pulse = nil
            pulseVideoId = videoId
        }
        pulseIndex = index
        if let current = pulse {
            // With no sound the pulse eases back to the bar's own level.
            let target = mapped ?? memory.levels(for: videoId)[index]
            pulse = MusicSpectrum.smoothed(current: current, target: target)
        } else {
            pulse = mapped
        }
    }

    /// The bars to draw for a song: its levels, with the pulse on the bar under the playhead.
    func bars(for videoId: String) -> [Double] {
        var levels = memory.levels(for: videoId)
        if let pulse, pulseVideoId == videoId, levels.indices.contains(pulseIndex) {
            levels[pulseIndex] = pulse
        }
        return levels
    }
}
