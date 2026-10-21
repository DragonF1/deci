// Deci/Music/MusicRateBurst.swift
// The like animation, as numbers: for a time since the tap, how big the thumb is, how filled, how far it is tilted and
// where its ring of sparks is. YouTube's own like button is the model: the outline thumb collapses to a small filled
// blob, pops back filled and a little too big with a ring of red dashes and pink dots around it, the sparks move out and
// shrink to dots as the thumb settles, the dots fade, and the thumb tilts once and rights itself. A dislike shares the
// collapse and the pop and has no sparks and no tilt. With Reduce Motion nothing moves: the icon only fades to filled.
// Taking a like or a dislike back has a plain animation of its own, shown in the menu bar pill only: the outline thumb
// fades in as the cover goes and settles from a little too big, with no sparks and no tilt.
// Pure values, so the timeline is unit tested; MusicRateBurstView draws it, on the popup's strip and in the menu bar pill.

import Foundation

nonisolated enum MusicRateBurst {
    /// Which button turned on.
    typealias Kind = MusicRateButtonLook.Kind

    /// Where the animation plays.
    enum Surface: Equatable, Sendable {
        /// On the Like or Dislike button of the popup's player column.
        case strip
        /// In the menu bar pill, in the cover's place.
        case pill
    }

    /// One instant of the animation. Lengths are in glyph sizes (the side of the thumb's box), so one timeline serves a
    /// 12 pt button and an 11 pt pill thumb alike.
    struct Frame: Equatable, Sendable {
        /// The thumb's size against its resting one.
        var scale: Double
        /// 0 draws the outline thumb, 1 the filled one; in between the two cross-fade.
        var fill: Double
        /// The tilt, in degrees; negative leans the thumb to the left.
        var rotation: Double
        /// The ring of sparks; nil while there is none.
        var sparks: Sparks?
        /// How strongly the thumb is drawn, 0 to 1. A burst is whole from its first frame; a removal fades in.
        var opacity: Double = 1
    }

    /// The ring: eight dashes on the compass points and eight dots between them.
    struct Sparks: Equatable, Sendable {
        /// The distance of the dashes and the dots from the thumb's middle.
        var radius: Double
        /// How long each dash is; it shrinks as the ring moves out, ending as a dot.
        var dashLength: Double
        /// The width of a dot, and of a dash.
        var dotDiameter: Double
        /// How strongly the ring is drawn, 0 to 1.
        var opacity: Double
    }

    /// The times and sizes of the timeline. Seconds and glyph sizes, read off YouTube's like button at 30 frames a
    /// second.
    enum Metrics {
        /// The outline is swapped for the filled thumb while the blob is at its smallest.
        static let fillAt = 0.03
        /// The thumb's size: full, collapsed to a blob, held there, popped back a little too big, then settled.
        static let scaleKeys: [(time: Double, value: Double)] = [
            (0, 1), (0.04, 0.3), (0.10, 0.3), (0.133, 1.12), (0.33, 1),
        ]
        /// The tilt of a like: upright, to the left, upright again.
        static let rotationKeys: [(time: Double, value: Double)] = [(0.45, 0), (0.60, -12), (0.85, 0)]
        /// The sparks exist from the pop until they have faded.
        static let sparksStart = 0.133
        static let sparksEnd = 0.57
        static let radiusKeys: [(time: Double, value: Double)] = [(0.133, 0.62), (0.33, 1.0), (0.57, 1.08)]
        static let dashLengthKeys: [(time: Double, value: Double)] = [(0.133, 0.24), (0.33, 0.07)]
        static let dotDiameter = 0.1
        /// The ring is at full strength until then, and fades to nothing by `sparksEnd`.
        static let opacityKeys: [(time: Double, value: Double)] = [(0.37, 1), (0.57, 0)]

        /// When a like, a dislike and a Reduce Motion burst are over.
        static let likeDuration = 0.85
        static let dislikeDuration = 0.33
        /// The Reduce Motion fade to the filled thumb, and to the outline thumb of a removal.
        static let reducedDuration = 0.15

        /// A removal's outline thumb settles from `removalScaleFrom` to its own size over this long, with a quick ease.
        static let removalSettle = 0.2
        static let removalScaleFrom = 1.15

        /// The pill keeps the filled thumb this long after the animation, then gives the cover back.
        static let pillHold = 0.7
        /// The cover gives way to the thumb over this long, within the thumb's collapse, so the pop is not drawn over a
        /// picture.
        static let pillCoverOut = 0.1
        /// The thumb gives the cover back over this long, when the hold is over.
        static let pillFade = 0.18
        /// How long the strip keeps a finished burst before it goes back to the plain icon, so a thumb that does not
        /// match the next song's state (a dislike skips the song) fades out and does not snap.
        static let stripTail = 0.25
    }

    /// The farthest a spark's outer end gets from the thumb's middle, in glyph sizes. A dash's centre sits at its radius
    /// and the dash reaches half its length past that.
    static let sparkExtent = 1.15

    // MARK: - What plays, and where

    /// The burst a change of a song's rating plays: Like or Dislike turning on. Taking a rating back plays no burst (the
    /// pill shows a removal for it, see `kindTakenBack`), and neither does sending the one the song already has.
    static func kind(from previous: MusicLikeStatus?, to status: MusicLikeStatus) -> Kind? {
        guard status != previous else { return nil }
        switch status {
        case .like: return .like
        case .dislike: return .dislike
        case .indifferent: return nil
        }
    }

    /// The Like or Dislike a change of a song's rating takes away: the pill shows its removal, and the burst of that kind
    /// still playing is replaced by it, so the thumb does not stay filled for a rating the song no longer has. Nil when
    /// nothing was taken away, and when the other button turned on in its place: that burst replaces this one.
    static func kindTakenBack(from previous: MusicLikeStatus?, to status: MusicLikeStatus) -> Kind? {
        guard status == .indifferent else { return nil }
        switch previous {
        case .like: return .like
        case .dislike: return .dislike
        case .indifferent, nil: return nil
        }
    }

    /// The popup's strip while the popup is open (on screen and key, the rule the outcome reporter uses); the menu bar
    /// pill otherwise.
    static func surface(popupIsOpen: Bool) -> Surface {
        popupIsOpen ? .strip : .pill
    }

    /// Only a like throws sparks.
    static func hasSparks(_ kind: Kind) -> Bool {
        kind == .like
    }

    /// How long the animation runs; after that its last frame is the settled thumb: filled for a burst, the outline for a
    /// removal, which is the same length for a like and a dislike.
    static func duration(of kind: Kind, reduceMotion: Bool, isRemoval: Bool = false) -> TimeInterval {
        if reduceMotion { return Metrics.reducedDuration }
        if isRemoval { return Metrics.removalSettle }
        return kind == .like ? Metrics.likeDuration : Metrics.dislikeDuration
    }

    /// How long the pill shows the thumb: the animation and the hold after it.
    static func pillShownDuration(of kind: Kind, reduceMotion: Bool, isRemoval: Bool = false) -> TimeInterval {
        duration(of: kind, reduceMotion: reduceMotion, isRemoval: isRemoval) + Metrics.pillHold
    }

    /// How much the sparks are scaled so that the whole burst fits `reach` points from the thumb's middle: the menu bar
    /// item is only so high. Never above 1: a roomy surface gets the sparks at their own size.
    static func sparkScale(glyphSize: Double, reach: Double) -> Double {
        guard glyphSize > 0, reach.isFinite else { return 1 }
        return min(1, max(0, reach) / (glyphSize * sparkExtent))
    }

    // MARK: - The timeline

    /// The thumb and its sparks `elapsed` seconds after the tap. A time before the start, or one that is not a number,
    /// is the start; a time after the end is the settled thumb. A removal is the same for a like and a dislike.
    static func frame(at elapsed: TimeInterval, kind: Kind, reduceMotion: Bool, isRemoval: Bool = false) -> Frame {
        let time = elapsed.isNaN ? 0 : max(0, elapsed)
        if isRemoval { return removalFrame(at: time, reduceMotion: reduceMotion) }
        if reduceMotion {
            return Frame(scale: 1, fill: ramp(time, over: Metrics.reducedDuration), rotation: 0, sparks: nil)
        }
        let scale = sample(Metrics.scaleKeys, at: time)
        let fill = time >= Metrics.fillAt ? 1.0 : 0.0
        guard hasSparks(kind) else {
            return Frame(scale: scale, fill: fill, rotation: 0, sparks: nil)
        }
        let rotation = sample(Metrics.rotationKeys, at: time)
        var sparks: Sparks?
        if time >= Metrics.sparksStart, time < Metrics.sparksEnd {
            sparks = Sparks(
                radius: sample(Metrics.radiusKeys, at: time),
                dashLength: sample(Metrics.dashLengthKeys, at: time),
                dotDiameter: Metrics.dotDiameter,
                opacity: sample(Metrics.opacityKeys, at: time)
            )
        }
        return Frame(scale: scale, fill: fill, rotation: rotation, sparks: sparks)
    }

    /// A like or a dislike taken back: the outline thumb fades in over the time the cover takes to go, so it is never
    /// drawn over a picture, and settles from a little too big to its own size with a quick ease. With Reduce Motion it
    /// only fades in.
    private static func removalFrame(at time: Double, reduceMotion: Bool) -> Frame {
        if reduceMotion {
            return Frame(scale: 1, fill: 0, rotation: 0, sparks: nil, opacity: ramp(time, over: Metrics.reducedDuration))
        }
        let opacity = smoothstep(ramp(time, over: Metrics.pillCoverOut))
        let scale: Double
        if time >= Metrics.removalSettle {
            scale = 1
        } else {
            let remaining = 1 - time / Metrics.removalSettle
            // Ease out: most of the way is made at first.
            let progress = 1 - remaining * remaining
            scale = Metrics.removalScaleFrom + (1 - Metrics.removalScaleFrom) * progress
        }
        return Frame(scale: scale, fill: 0, rotation: 0, sparks: nil, opacity: opacity)
    }

    /// 0 at the start, 1 from `length` seconds on, in a straight line between.
    private static func ramp(_ time: Double, over length: Double) -> Double {
        min(1, time / length)
    }

    /// The value of a keyframe track at `time`: the first value before the first key, the last after the last, and a
    /// smooth ease between two keys.
    private static func sample(_ keys: [(time: Double, value: Double)], at time: Double) -> Double {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        for index in 1..<keys.count where time <= keys[index].time {
            let from = keys[index - 1], to = keys[index]
            let progress = (time - from.time) / (to.time - from.time)
            return from.value + (to.value - from.value) * smoothstep(progress)
        }
        return last.value
    }

    /// 0 to 1 along a gentle S: slow at both ends.
    private static func smoothstep(_ progress: Double) -> Double {
        progress * progress * (3 - 2 * progress)
    }
}
