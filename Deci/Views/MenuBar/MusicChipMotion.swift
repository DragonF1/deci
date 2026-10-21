// Deci/Views/MenuBar/MusicChipMotion.swift
// How the Now playing chip moves: the width easing, the marquee's path, timing and rests, the fade at the title's edges,
// and which change of the chip is a cross-fade, which one only brings in the cover and which one only pauses or resumes it.
// Pure numbers, so the rules are unit tested; MusicChipView, MusicChipContent and MusicChipLengthAnimator run them.

import Foundation

/// One loop of the marquee as keyframes: the text sits at the start for the hold, then scrolls left by the loop's
/// distance. Played again and again, the second copy of the title lands where the first began.
nonisolated struct MusicChipMarqueeKeyframes: Equatable, Sendable {
    /// Where each keyframe falls in the loop, 0 to 1.
    var keyTimes: [Double]
    /// The text's horizontal offset at each keyframe, in points (zero or negative: it moves left).
    var offsets: [Double]
    /// The whole loop, hold included, in seconds.
    var duration: Double
}

nonisolated enum MusicChipMotion {
    /// The pill growing or shrinking to the new title's width.
    static let widthDuration: Double = 0.35
    /// The old title and cover fading out as the new ones fade in, and the content and the play glyph trading places on a
    /// pause or a play.
    static let fadeDuration: Double = 0.25

    /// How long a title waits at its start before it scrolls, at the start of every loop.
    static let marqueeHold: Double = 1.5
    /// How fast it scrolls, in points a second.
    static let marqueeSpeed: Double = 25
    /// The space between the two copies of the title.
    static let marqueeGap: Double = 24
    /// How many loops it runs before it rests, so a long song does not keep the menu bar drawing every frame.
    static let marqueeLoops = 3
    /// How long the title rests at its start after those loops, before the marquee runs again.
    static let marqueeRest: Double = 25

    /// How wide the fade at each edge of the window is while the title scrolls.
    static let edgeFadeWidth: Double = 10
    /// How long the fade takes to come in after the hold and to go out before the loop ends.
    static let edgeFadeRamp: Double = 0.3

    /// Slowest and quickest a pause takes to ease the text back to its start.
    private static let returnDurationRange: ClosedRange<Double> = 0.3...0.9
    /// How far the text eases back in a second, which scales a pause's duration to how far it has scrolled.
    private static let returnSpeed: Double = 150

    // MARK: - Which change

    /// What a new look of the chip is to the one on screen.
    enum Change: Equatable, Sendable {
        /// Nothing differs.
        case none
        /// Only whether it plays: the pill narrows to the play glyph or widens back to the title, the content and the glyph
        /// cross-fade, and the marquee runs or rests.
        case playback
        /// The same song, whose cover or colour arrived late (and maybe whether it plays too): the cover fades in and the
        /// pill's colour follows, while the title stays as it is.
        case cover
        /// The title, cover or motion setting differs: the old content fades out as the new content fades in.
        case content
    }

    /// Whether `new` needs the content swapped, only the cover brought in, only the play look changed, or nothing done. A
    /// chip that was not showing (`old` nil) gets its content.
    static func change(from old: MusicChipSpec?, to new: MusicChipSpec) -> Change {
        guard let old else { return .content }
        if old == new { return .none }
        var sameLook = old
        sameLook.isPlaying = new.isPlaying
        if sameLook == new { return .playback }
        // The same song that only gained its cover or its colour. A cover that goes away is not that: the picture on
        // screen has to be swapped out.
        guard !(old.hasThumbnail && !new.hasThumbnail) else { return .content }
        var sameSong = sameLook
        sameSong.tint = new.tint
        sameSong.hasThumbnail = new.hasThumbnail
        return sameSong == new ? .cover : .content
    }

    // MARK: - Fade

    /// How long the content and the play glyph take to trade places: no time with Reduce Motion, so they swap at once.
    static func playbackFadeDuration(reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : fadeDuration
    }

    // MARK: - Width

    /// How long the width takes to follow a new title: no time with Reduce Motion, so it applies at once.
    static func widthChangeDuration(reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : widthDuration
    }

    /// The ease-in-out curve both the status item's length and the pill's bounds follow (the control points of
    /// `CAMediaTimingFunction(name: .easeInEaseOut)`): `progress` is the share of the time gone, the result the share of
    /// the way done. Held at the ends outside 0...1; a progress that is not a number is the end.
    static func easedProgress(_ progress: Double) -> Double {
        guard !progress.isNaN else { return 1 }
        if progress <= 0 { return 0 }
        if progress >= 1 { return 1 }
        // Find the curve's parameter whose x is `progress`, then read the y there. x grows with the parameter.
        var low = 0.0
        var high = 1.0
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if bezier(middle, 0.42, 0.58) < progress {
                low = middle
            } else {
                high = middle
            }
        }
        return bezier((low + high) / 2, 0, 1)
    }

    /// The width `elapsed` seconds into a change of `duration` seconds from `from` to `to`. No duration, or one that is
    /// not a number, is the new width at once.
    static func easedWidth(from: Double, to: Double, elapsed: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0, elapsed.isFinite else { return to }
        let eased = easedProgress(elapsed / duration)
        if eased >= 1 { return to }
        return from + (to - from) * eased
    }

    /// One coordinate of a cubic Bezier from 0 to 1 with control values `p1` and `p2`.
    private static func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }

    // MARK: - Marquee

    /// The marquee runs only for a title that is longer than its window, while the song plays, with motion allowed.
    static func runsMarquee(scrolls: Bool, isPlaying: Bool, reduceMotion: Bool) -> Bool {
        scrolls && isPlaying && !reduceMotion
    }

    /// How far one loop moves the text: its own width and the gap, so the second copy ends where the first began.
    static func marqueeDistance(textWidth: Double) -> Double {
        (textWidth.isFinite ? max(textWidth, 0) : 0) + marqueeGap
    }

    /// How long the scroll of one loop takes, without the hold. A speed that is not above zero reads as the usual one.
    static func marqueeScrollDuration(textWidth: Double, speed: Double = marqueeSpeed) -> Double {
        let usableSpeed = speed.isFinite && speed > 0 ? speed : marqueeSpeed
        return marqueeDistance(textWidth: textWidth) / usableSpeed
    }

    /// One loop as keyframes: the hold, then the scroll.
    static func marqueeKeyframes(textWidth: Double) -> MusicChipMarqueeKeyframes {
        let cycle = marqueeHold + marqueeScrollDuration(textWidth: textWidth)
        return MusicChipMarqueeKeyframes(
            keyTimes: [0, marqueeHold / cycle, 1],
            offsets: [0, 0, -marqueeDistance(textWidth: textWidth)],
            duration: cycle
        )
    }

    /// How long the marquee runs before it rests: its loops, hold included.
    static func marqueeRunDuration(textWidth: Double) -> Double {
        Double(marqueeLoops) * (marqueeHold + marqueeScrollDuration(textWidth: textWidth))
    }

    /// How long after it starts the marquee is started again: the run and then the rest.
    static func marqueeRearmDelay(textWidth: Double) -> Double {
        marqueeRunDuration(textWidth: textWidth) + marqueeRest
    }

    /// Where the text stands `elapsed` seconds into a run, for a marquee drawn frame by frame: at the start for each
    /// loop's hold, then scrolling left by the loop's distance; at the start again once the run is over.
    static func marqueeOffset(elapsed: Double, textWidth: Double) -> Double {
        let loop = marqueeHold + marqueeScrollDuration(textWidth: textWidth)
        guard elapsed.isFinite, elapsed > 0, elapsed < Double(marqueeLoops) * loop else { return 0 }
        let scrolled = elapsed.truncatingRemainder(dividingBy: loop) - marqueeHold
        return scrolled <= 0 ? 0 : -scrolled * marqueeSpeed
    }

    /// How long a pause takes to ease the text from where it stands back to the start: longer the further it has
    /// scrolled, always between 0.3 and 0.9 s.
    static func marqueeReturnDuration(offset: Double) -> Double {
        guard offset.isFinite else { return returnDurationRange.lowerBound }
        let wanted = abs(offset) / returnSpeed
        return min(max(wanted, returnDurationRange.lowerBound), returnDurationRange.upperBound)
    }

    // MARK: - Edge fade

    /// Where the edge fade's keyframes fall in the loop: clear through the hold, in over the first moments of the
    /// scroll, out over the last ones. In order, and strictly increasing, whatever the width.
    static func edgeFadeKeyTimes(textWidth: Double) -> [Double] {
        let scroll = marqueeScrollDuration(textWidth: textWidth)
        let cycle = marqueeHold + scroll
        let ramp = min(edgeFadeRamp, scroll / 3)
        return [0, marqueeHold / cycle, (marqueeHold + ramp) / cycle, (cycle - ramp) / cycle, 1]
    }

    /// The stops of the gradient mask over the window: clear at the left edge, opaque after 10 pt, opaque until 10 pt
    /// before the right edge, clear at the right. In a window narrower than both fades they meet in the middle.
    static func edgeFadeLocations(windowWidth: Double) -> [Double] {
        let width = windowWidth.isFinite ? max(windowWidth, 0) : 0
        let fraction = width > 0 ? min(edgeFadeWidth / width, 0.5) : 0
        return [0, fraction, 1 - fraction, 1]
    }
}
