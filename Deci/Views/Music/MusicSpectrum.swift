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

    /// The box stretches to fill the column; `boxHeight` is the design's height and the least it gets. A taller box
    /// spreads the same 28 bars and thickens them a little, up to 4 pt, in half points.
    static func barThickness(height: Double) -> Double {
        guard height.isFinite, height > boxHeight else { return barThickness }
        return min(4, (2 * barThickness * height / boxHeight).rounded() / 2)
    }

    /// `pitch` for a box `height` tall.
    static func pitch(height: Double) -> Double {
        guard height.isFinite, height > boxHeight else { return pitch }
        return (height - barThickness(height: height)) / Double(barCount - 1)
    }

    /// The shortest a bar gets, as a level. Levels run from here to 1.
    static let minLevel: Double = 0.08

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
    static func barY(_ index: Int, height: Double = boxHeight) -> Double {
        Double(index) * pitch(height: height)
    }

    // MARK: - The fill

    /// The soft edge between the played colour above and the unplayed white below: two bars deep, so the bar the song
    /// is on takes the colour gradually from its top down while the next one starts to.
    static func fillEdge(height: Double = boxHeight) -> Double {
        2 * pitch(height: height)
    }

    /// The middle of the soft edge, from the top of the box. It slides from just above the box at the start to just
    /// below it at the end, so no bar has colour before the song starts and none is left white once it ends.
    static func fillEdgeY(progress: Double, height: Double = boxHeight) -> Double {
        let progress = progress.isFinite ? min(max(progress, 0), 1) : 0
        let height = max(height, boxHeight)
        let edge = fillEdge(height: height)
        return -edge / 2 + progress * (height + edge)
    }

    // MARK: - Colour

    /// The sRGB of a hue, saturation and brightness, each 0...1: the colour SwiftUI's `Color(hue:saturation:brightness:)`
    /// makes, for drawing with Core Graphics. A hue of 1 is the same as 0 (red); a value out of range is held to it, and
    /// one that is not a number counts as 0.
    static func rgb(hue: Double, saturation: Double, brightness: Double) -> (red: Double, green: Double, blue: Double) {
        func unit(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0 }
        let saturation = unit(saturation)
        let brightness = unit(brightness)
        let hue = hue.isFinite ? hue - hue.rounded(.down) : 0
        let sector = hue * 6
        let whole = sector.rounded(.down)
        let fraction = sector - whole
        let low = brightness * (1 - saturation)
        let falling = brightness * (1 - saturation * fraction)
        let rising = brightness * (1 - saturation * (1 - fraction))
        switch Int(whole) % 6 {
        case 0: return (brightness, rising, low)
        case 1: return (falling, brightness, low)
        case 2: return (low, brightness, rising)
        case 3: return (low, falling, brightness)
        case 4: return (rising, low, brightness)
        default: return (brightness, low, falling)
        }
    }

    // MARK: - The glide

    /// The share of the way left that one poll covers: a seek settles in about a third of a second at 30 polls a
    /// second, and while the song plays the fill trails it by a few polls, too little to see.
    static let glideRate = 0.25
    /// Closer than this, as a fraction of the song, the shown position lands on the real one.
    static let glideSnap = 1e-4

    /// One poll of the shown position toward the song's real one, so a seek slides the fill there instead of jumping.
    static func glided(shown: Double, target: Double) -> Double {
        guard shown.isFinite, target.isFinite else { return target }
        let gap = target - shown
        guard abs(gap) > glideSnap else { return target }
        return shown + gap * glideRate
    }

    /// How long a seek while paused slides the fill. Playing, the driver's polls glide it instead.
    static let pausedSeekGlide: TimeInterval = 0.35

    /// A move of the fill's edge of this many points or less is not slid: it is too small to see.
    static let glideMinimumDistance = 1.0

    /// Whether moving the fill from `from` to `to` in a box `height` high is worth a slide.
    static func glideIsVisible(from: Double, to: Double, height: Double = boxHeight) -> Bool {
        abs(fillEdgeY(progress: to, height: height) - fillEdgeY(progress: from, height: height)) > glideMinimumDistance
    }

    /// The ease-out curve of the paused seek's slide (the cubic Bezier through (0, 0), (0.58, 1) that SwiftUI's
    /// `.easeOut` and Core Animation's ease-out share): how much of the way is done `t` of the way through the time,
    /// both 0...1. Quick at first, slowing into the end.
    static func easedOut(_ t: Double) -> Double {
        guard t.isFinite else { return 1 }
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        // x(s) = 3(1 - s)^2 s x1 + 3(1 - s) s^2 x2 + s^3 with x1 = 0, x2 = 0.58; solved for s by bisection.
        func x(_ s: Double) -> Double { 3 * (1 - s) * s * s * 0.58 + s * s * s }
        func y(_ s: Double) -> Double { 3 * (1 - s) * s * s + s * s * s }
        var low = 0.0
        var high = 1.0
        for _ in 0..<32 {
            let middle = (low + high) / 2
            if x(middle) < t { low = middle } else { high = middle }
        }
        return y((low + high) / 2)
    }

    // MARK: - Seeking

    /// Where a click at `y` points along the song, 0...1: the top of the box is the start, the bottom the end.
    static func progress(atY y: Double, height: Double = boxHeight) -> Double {
        guard y.isFinite else { return 0 }
        return min(max(y / max(height, boxHeight), 0), 1)
    }

    /// The position in seconds a click at `y` seeks to.
    static func seekTime(atY y: Double, duration: TimeInterval, height: Double = boxHeight) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return progress(atY: y, height: height) * duration
    }

    /// Where the preview line is drawn for a pointer at `y`: under the pointer, inside the box.
    static func previewLineY(atY y: Double, height: Double = boxHeight) -> Double {
        guard y.isFinite else { return 0 }
        return min(max(y, 0), max(height, boxHeight) - 1)
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

/// What the bars look like, as far as the eye can tell: each bar's width in half points (the step the drawing rounds
/// to) and the middle of the soft edge in quarter points. Two frames that are equal draw the same picture to within a
/// quarter point, so the layer redraws only when the frame changes, not on every poll.
nonisolated struct MusicSpectrumFrame: Equatable, Sendable {
    let widths: [Int]
    let edge: Int

    init(levels: [Double], progress: Double, height: Double, fixedWidth: Double?) {
        widths = levels.map { Int(((fixedWidth ?? MusicSpectrum.width(forLevel: $0)) * 2).rounded()) }
        edge = Int((MusicSpectrum.fillEdgeY(progress: progress, height: height) * 4).rounded())
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
///
/// The numbers a poll changes (the bars, the pulse, the fill) are 30 a second and are not observed: a view that read
/// them would run the popup's whole SwiftUI update, and a layout of its window, 30 times a second. The layer that draws
/// the spectrum listens instead (`addFrameListener`), and a poll tells it only when something that shows has changed.
/// SwiftUI still hears the rare things: `isActive` and `isLive`.
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
        /// Whether Reduce Motion is on: a seek then jumps.
        var reduceMotion: @MainActor () -> Bool = { false }

        static let none = Sources(level: { 0 }, position: { 0 }, duration: { 0 }, videoId: { nil })
    }

    /// About 30 polls a second.
    static let interval: TimeInterval = 1.0 / 30.0

    @ObservationIgnored var sources: Sources
    @ObservationIgnored private(set) var memory: MusicSpectrumMemory
    /// The level of the bar under the playhead, smoothed; nil while the bars rest.
    @ObservationIgnored private(set) var pulse: Double?
    @ObservationIgnored private(set) var pulseIndex = 0
    /// How far along the song the fill shows, as of the last poll: the live position, reached by a glide after a seek.
    /// nil while the bars rest.
    @ObservationIgnored private(set) var progress: Double?
    private(set) var isActive = false
    /// Whether `progress` has a value. Observed, and written only when it flips, so a view that needs to know when the
    /// polls start and stop deciding the fill hears that and nothing else.
    private(set) var isLive = false
    /// How far along the song is in whole percent, for what VoiceOver says. Observed, and written only when the percent
    /// changes: about once in 1.8 s of a three minute song, not 30 times a second.
    private(set) var spokenPercent = 0

    @ObservationIgnored private var pulseVideoId: String?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var frameListeners: [Int: @MainActor () -> Void] = [:]
    @ObservationIgnored private var nextListenerToken = 0

    init(sources: Sources = .none, memory: MusicSpectrumMemory = MusicSpectrumMemory()) {
        self.sources = sources
        self.memory = memory
    }

    /// How many layers are listening.
    var frameListenerCount: Int { frameListeners.count }

    /// Calls `listener` after every poll that changed what shows, and when the bars go to rest. Returns the token that
    /// takes it off again.
    func addFrameListener(_ listener: @escaping @MainActor () -> Void) -> Int {
        nextListenerToken += 1
        frameListeners[nextListenerToken] = listener
        return nextListenerToken
    }

    func removeFrameListener(_ token: Int) {
        frameListeners[token] = nil
    }

    private func notifyFrame() {
        for listener in Array(frameListeners.values) { listener() }
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
            // Common modes, so the bars keep moving while a menu is open.
            let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            rest()
        }
    }

    /// The bars rest: no pulse, no live position.
    func rest() {
        let changed = pulse != nil || progress != nil
        pulse = nil
        progress = nil
        pulseVideoId = nil
        if isLive { isLive = false }
        if changed { notifyFrame() }
    }

    /// One poll.
    func tick() {
        let before = (progress: progress, pulse: pulse, index: pulseIndex)
        let heard = sources.level()
        let duration = sources.duration()
        guard let videoId = sources.videoId(), duration.isFinite, duration > 0 else {
            rest()
            return
        }
        let position = sources.position()
        let fraction = MusicTimeFormat.progress(current: position, duration: duration)
        // The first poll, a new song and Reduce Motion land on the position; otherwise the fill glides to it.
        if let shown = progress, pulseVideoId == videoId, !sources.reduceMotion() {
            progress = MusicSpectrum.glided(shown: shown, target: fraction)
        } else {
            progress = fraction
        }
        if !isLive { isLive = true }
        let percent = Int((fraction * 100).rounded())
        if spokenPercent != percent { spokenPercent = percent }
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
        // What shows is the fill, the pulse and the bar the pulse is on; a capture moves nothing else the eye can see.
        if progress != before.progress || pulse != before.pulse || pulseIndex != before.index {
            notifyFrame()
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
