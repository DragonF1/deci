// Deci/Views/MenuBar/MusicChipContent.swift
// The layers of one song on the Now playing chip: the round cover, the title in its window and, for a title longer than
// the window, the marquee that scrolls it. Everything moves by Core Animation animations, so the render server draws
// the frames and the main thread does nothing while a title scrolls; the marquee runs a few loops and then rests, so the
// menu bar is not redrawn every frame for a whole song. MusicChipView swaps one content for the next.

import AppKit
import QuartzCore

/// One song's cover and title, laid out for one pill width. The layer's frame is that pill, so it is added to the pill
/// layer at its origin and the pill's rounded bounds clip it while the pill grows or shrinks.
@MainActor
final class MusicChipContent {
    /// Holds the cover and the title and fades as one, so the two cross-fade with the next song's, and with the play glyph
    /// a pause brings in.
    let layer = CALayer()
    let spec: MusicChipSpec
    let geometry: MusicChipGeometry

    private(set) var isPlaying: Bool
    /// Whether the cover is held away, for the like animation's thumb that stands in its place.
    private(set) var isCoverHidden: Bool
    private var scale: CGFloat
    /// The cover on screen; nil while it is still loading, and the faint disc with the note shows instead.
    private(set) var thumbnail: CGImage?

    private let cover = CALayer()
    private let note = CALayer()
    private let window = CALayer()
    /// Carries the two copies of a scrolling title; the marquee moves this layer.
    private let scroller = CALayer()
    /// Fades the window's left and right edges while the title scrolls. It is opaque at rest, so a title that stands
    /// still has no faded edge.
    private let edgeMask = CAGradientLayer()
    private var textLayers: [CATextLayer] = []
    /// Whether the marquee is on: running its loops, or resting between runs. Off while paused.
    private(set) var isScrolling = false
    /// Starts the marquee again after its rest. One at a time, and cancelled when the marquee stops or the content goes.
    private var rearmTask: Task<Void, Never>?
    /// When the ease back to the start, after a pause, ends (media time), so a play that comes before it waits for it.
    private var returnEndsAt: CFTimeInterval = 0

    private static let marqueeKey = "chipMarquee"
    private static let edgeFadeKey = "chipEdgeFade"
    private static let returnKey = "chipMarqueeReturn"
    private static let opacityKey = "chipContentOpacity"
    private static let coverKey = "chipCoverFade"
    private static let coverHideKey = "chipCoverHide"

    /// How strong the cover is drawn (its model value): 1, or 0 while the like animation's thumb stands in its place. Read
    /// by the tests.
    var coverOpacity: Double { Double(cover.opacity) }

    /// `coverHidden` builds the cover away already: a song that arrives while the like animation shows has no picture
    /// for the thumb to be drawn over.
    init(spec: MusicChipSpec, geometry: MusicChipGeometry, thumbnail: CGImage?, scale: CGFloat, coverHidden: Bool = false) {
        self.spec = spec
        self.geometry = geometry
        self.thumbnail = thumbnail
        self.scale = scale
        self.isPlaying = spec.isPlaying
        self.isCoverHidden = coverHidden

        layer.bounds = CGRect(x: 0, y: 0, width: geometry.pillWidth, height: MusicChipLayout.height)
        layer.anchorPoint = .zero
        layer.position = .zero
        layer.opacity = Float(MusicChipLayout.contentAlpha(isPlaying: spec.isPlaying))
        buildCover()
        buildTitle()
        applyScale()
    }

    // MARK: - Build

    private func buildCover() {
        let side = MusicChipLayout.thumbnailSize
        cover.frame = CGRect(
            x: MusicChipLayout.leadingInset,
            y: ((MusicChipLayout.height - side) / 2),
            width: side,
            height: side
        )
        cover.cornerRadius = side / 2
        cover.masksToBounds = true
        cover.opacity = isCoverHidden ? 0 : 1
        cover.contentsGravity = .resizeAspectFill
        cover.minificationFilter = .trilinear
        if let thumbnail {
            cover.contents = thumbnail
        } else {
            // No cover yet: a faint disc with a white note on it.
            cover.backgroundColor = CGColor(gray: 1, alpha: 0.25)
            note.frame = cover.bounds
            note.contentsGravity = .resizeAspectFill
            cover.addSublayer(note)
        }
        layer.addSublayer(cover)
    }

    private func buildTitle() {
        window.frame = CGRect(
            x: MusicChipLayout.titleOriginX,
            y: 0,
            width: geometry.windowWidth,
            height: MusicChipLayout.height
        )
        window.masksToBounds = true
        layer.addSublayer(window)
        guard geometry.windowWidth > 0, !spec.title.isEmpty else { return }

        if geometry.scrolls && !spec.reduceMotion {
            // Two copies a gap apart: when the first has scrolled off, the second stands where the first began.
            let width = geometry.textWidth
            scroller.anchorPoint = .zero
            scroller.bounds = CGRect(x: 0, y: 0, width: width * 2 + MusicChipMotion.marqueeGap, height: MusicChipLayout.height)
            scroller.position = .zero
            scroller.addSublayer(makeText(x: 0, width: width + 1, truncates: false))
            scroller.addSublayer(makeText(x: MusicChipMotion.marqueeDistance(textWidth: width), width: width + 1, truncates: false))
            window.addSublayer(scroller)

            edgeMask.frame = window.bounds
            edgeMask.startPoint = CGPoint(x: 0, y: 0.5)
            edgeMask.endPoint = CGPoint(x: 1, y: 0.5)
            edgeMask.locations = MusicChipMotion.edgeFadeLocations(windowWidth: geometry.windowWidth).map { NSNumber(value: $0) }
            edgeMask.colors = Self.edgeColors(faded: false)
            window.mask = edgeMask
        } else if geometry.scrolls {
            // Reduce Motion: the window shows the start of the title and ends in an ellipsis.
            window.addSublayer(makeText(x: 0, width: geometry.windowWidth, truncates: true))
        } else {
            // One pt of slack, so a width that rounds the wrong way never turns the last letter into an ellipsis.
            window.addSublayer(makeText(x: 0, width: geometry.windowWidth + 1, truncates: false))
        }
    }

    /// One line of the title. A text layer draws from the top of its box, so the box sits with its top where the line's
    /// top belongs to centre the line in the pill.
    private func makeText(x: Double, width: Double, truncates: Bool) -> CATextLayer {
        let lineHeight = MusicChipRenderer.titleLineHeight
        let boxHeight = lineHeight + 2
        let top = (MusicChipLayout.height + lineHeight) / 2
        let text = CATextLayer()
        // A plain string, with the font and colour set on the layer: a text layer that truncates with an ellipsis draws
        // an attributed string as nothing at all.
        text.string = spec.title
        text.font = MusicChipRenderer.titleFont
        text.fontSize = CGFloat(MusicChipLayout.titleFontSize)
        text.foregroundColor = CGColor(gray: 1, alpha: 1)
        text.isWrapped = false
        text.alignmentMode = .left
        text.truncationMode = truncates ? .end : .none
        text.frame = CGRect(x: x, y: top - boxHeight, width: width, height: boxHeight)
        textLayers.append(text)
        return text
    }

    /// The mask's colours: only their strength counts. Opaque everywhere at rest, clear at both ends while the title
    /// scrolls.
    private static func edgeColors(faded: Bool) -> [CGColor] {
        let solid = CGColor(gray: 0, alpha: 1)
        let clear = CGColor(gray: 0, alpha: faded ? 0 : 1)
        return [clear, solid, solid, clear]
    }

    // MARK: - Scale

    /// Sets the pixels a point has on every layer that draws, so text and the note stay sharp on the screen the item is on.
    func setScale(_ newScale: CGFloat) {
        guard newScale != scale else { return }
        scale = newScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyScale()
        CATransaction.commit()
    }

    private func applyScale() {
        layer.contentsScale = scale
        cover.contentsScale = scale
        note.contentsScale = scale
        for text in textLayers { text.contentsScale = scale }
        if thumbnail == nil {
            note.contents = MusicChipRenderer.noteImage(side: MusicChipLayout.thumbnailSize, scale: scale)
        }
    }

    // MARK: - Fades

    /// Fades this content in from nothing to its play strength, as the song before it fades out. Content of a paused song
    /// stays hidden: the pill shows the play glyph instead.
    func fadeIn() {
        let alpha = Float(MusicChipLayout.contentAlpha(isPlaying: isPlaying))
        animateOpacity(from: 0, to: alpha, duration: MusicChipMotion.fadeDuration)
    }

    /// Fades out, then takes the layer off the pill. The marquee's loops in flight run out with the fade; it is not
    /// started again.
    func fadeOutAndRemove() {
        cancelRearm()
        let from = layer.presentation()?.opacity ?? layer.opacity
        // The completion block runs when the fade ends, on the main thread that committed it.
        nonisolated(unsafe) let faded = layer
        CATransaction.begin()
        CATransaction.setCompletionBlock { faded.removeFromSuperlayer() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        CATransaction.commit()
        addOpacityAnimation(from: from, to: 0, duration: MusicChipMotion.fadeDuration)
        CATransaction.commit()
    }

    /// Stops the marquee from starting again, for a content that is going away.
    func cancelRearm() {
        rearmTask?.cancel()
        rearmTask = nil
    }

    // MARK: - Cover

    /// Brings in a cover that was still loading: the disc and note fade into the picture. Only a missing cover is
    /// replaced; the title and the marquee are not touched.
    func setCover(_ image: CGImage?) {
        guard thumbnail == nil, let image else { return }
        thumbnail = image
        let fade = CATransition()
        fade.type = .fade
        fade.duration = MusicChipMotion.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.add(fade, forKey: Self.coverKey)
        cover.contents = image
        cover.backgroundColor = nil
        note.contents = nil
        note.removeFromSuperlayer()
        CATransaction.commit()
    }

    /// Fades the cover out for the like animation's thumb, and back in after it, over `duration` seconds (no time: at once).
    /// The title stays.
    func setCoverHidden(_ hidden: Bool, duration: Double) {
        guard hidden != isCoverHidden else { return }
        isCoverHidden = hidden
        let alpha: Float = hidden ? 0 : 1
        let from = cover.presentation()?.opacity ?? cover.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.opacity = alpha
        CATransaction.commit()
        guard duration > 0 else {
            cover.removeAnimation(forKey: Self.coverHideKey)
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = alpha
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cover.add(fade, forKey: Self.coverHideKey)
    }

    // MARK: - Playing

    /// Starts the marquee, if the title scrolls and the song plays. Called once the layer is on the pill.
    func begin() {
        if MusicChipMotion.runsMarquee(scrolls: geometry.scrolls, isPlaying: isPlaying, reduceMotion: spec.reduceMotion) {
            startMarquee()
        }
    }

    /// The song started or paused: the content fades in or out over `fadeDuration` seconds (no time: at once), and the
    /// marquee runs or eases back to the start.
    func setPlaying(_ playing: Bool, fadeDuration: Double = MusicChipMotion.fadeDuration) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        animateOpacity(
            from: layer.presentation()?.opacity ?? layer.opacity,
            to: Float(MusicChipLayout.contentAlpha(isPlaying: playing)),
            duration: fadeDuration
        )
        if MusicChipMotion.runsMarquee(scrolls: geometry.scrolls, isPlaying: playing, reduceMotion: spec.reduceMotion) {
            startMarquee()
        } else {
            stopMarquee()
        }
    }

    /// Sets the opacity and eases to it from `from`; no duration sets it at once, and a fade still running is dropped.
    private func animateOpacity(from: Float, to: Float, duration: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = to
        CATransaction.commit()
        if duration > 0 {
            addOpacityAnimation(from: from, to: to, duration: duration)
        } else {
            layer.removeAnimation(forKey: Self.opacityKey)
        }
    }

    private func addOpacityAnimation(from: Float, to: Float, duration: Double) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: Self.opacityKey)
    }

    // MARK: - Marquee

    /// Holds at the start, scrolls left until the title and its gap have passed, and loops a few times; then it rests at
    /// the start and a stored task starts it again. The edge fade follows the same clock: clear during the hold, in as
    /// the scroll starts, out before the loop ends. Both animations begin in one transaction, so they share a start. A
    /// play that comes while the text is still easing back from a pause waits for that to end, so the text never jumps.
    private func startMarquee() {
        guard !isScrolling else { return }
        isScrolling = true

        let now = CACurrentMediaTime()
        let wait = max(0, returnEndsAt - now)
        let keyframes = MusicChipMotion.marqueeKeyframes(textWidth: geometry.textWidth)

        let scroll = CAKeyframeAnimation(keyPath: "transform.translation.x")
        scroll.values = keyframes.offsets
        scroll.keyTimes = keyframes.keyTimes.map { NSNumber(value: $0) }
        scroll.duration = keyframes.duration
        scroll.calculationMode = .linear
        scroll.repeatCount = Float(MusicChipMotion.marqueeLoops)

        let solid = Self.edgeColors(faded: false)
        let faded = Self.edgeColors(faded: true)
        let fade = CAKeyframeAnimation(keyPath: "colors")
        fade.values = [solid, solid, faded, faded, solid]
        fade.keyTimes = MusicChipMotion.edgeFadeKeyTimes(textWidth: geometry.textWidth).map { NSNumber(value: $0) }
        fade.duration = keyframes.duration
        fade.calculationMode = .linear
        fade.repeatCount = Float(MusicChipMotion.marqueeLoops)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if wait > 0 {
            // The return animation keeps running; the loops begin when it ends, where the text already stands.
            scroll.beginTime = scroller.convertTime(now, from: nil) + wait
            fade.beginTime = edgeMask.convertTime(now, from: nil) + wait
        } else {
            scroller.removeAnimation(forKey: Self.returnKey)
            edgeMask.removeAnimation(forKey: Self.returnKey)
        }
        scroller.add(scroll, forKey: Self.marqueeKey)
        edgeMask.add(fade, forKey: Self.edgeFadeKey)
        CATransaction.commit()

        scheduleRearm(after: wait + MusicChipMotion.marqueeRearmDelay(textWidth: geometry.textWidth))
    }

    /// Starts the marquee again once its loops and its rest are over, if it is still on.
    private func scheduleRearm(after delay: Double) {
        cancelRearm()
        rearmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.isScrolling else { return }
            self.isScrolling = false
            self.startMarquee()
        }
    }

    /// Takes the loop away and eases the text from where it stands back to its start, the edges back to opaque.
    private func stopMarquee() {
        guard isScrolling else { return }
        isScrolling = false
        cancelRearm()
        let offset = (scroller.presentation()?.value(forKeyPath: "transform.translation.x") as? NSNumber)?.doubleValue ?? 0
        let colors = edgeMask.presentation()?.colors
        let duration = MusicChipMotion.marqueeReturnDuration(offset: offset)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scroller.removeAnimation(forKey: Self.marqueeKey)
        edgeMask.removeAnimation(forKey: Self.edgeFadeKey)
        returnEndsAt = 0
        if abs(offset) > 0.5 {
            let back = CABasicAnimation(keyPath: "transform.translation.x")
            back.fromValue = offset
            back.toValue = 0
            back.duration = duration
            back.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scroller.add(back, forKey: Self.returnKey)
            if let colors {
                let opaque = CABasicAnimation(keyPath: "colors")
                opaque.fromValue = colors
                opaque.toValue = Self.edgeColors(faded: false)
                opaque.duration = duration
                opaque.timingFunction = CAMediaTimingFunction(name: .easeOut)
                edgeMask.add(opaque, forKey: Self.returnKey)
            }
            returnEndsAt = CACurrentMediaTime() + duration
        }
        CATransaction.commit()
    }
}
