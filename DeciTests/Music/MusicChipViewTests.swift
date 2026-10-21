// DeciTests/Music/MusicChipViewTests.swift
// The Now playing chip's view and the layers of one song on it: it takes no clicks, the pill follows the title's width,
// a paused song is only the pill's colour with a play glyph at its middle, a cover that arrives late is brought in
// without rebuilding the title, and the marquee runs only for a title longer than the max while the song plays. Nothing
// is shown on screen: the layers are built and read without a window.

import AppKit
import Testing
@testable import Deci

@MainActor
@Suite("Music chip view")
struct MusicChipViewTests {
    private let shortTitle = "Night Drive"
    private let longTitle = "A Very Long Song Title That Keeps Going And Going"

    private func spec(_ title: String, isPlaying: Bool = true, reduceMotion: Bool = false) -> MusicChipSpec {
        MusicChipSpec(
            title: title,
            isPlaying: isPlaying,
            tint: MusicTint(hue: 0.55, saturation: 0.6, brightness: 0.7),
            hasThumbnail: false,
            coverURL: nil,
            reduceMotion: reduceMotion
        )
    }

    private func geometry(_ title: String) -> MusicChipGeometry {
        MusicChipLayout.geometry(title: title, measure: { Double($0.count) * 6 })
    }

    private func content(_ title: String, isPlaying: Bool = true, reduceMotion: Bool = false) -> MusicChipContent {
        MusicChipContent(
            spec: spec(title, isPlaying: isPlaying, reduceMotion: reduceMotion),
            geometry: geometry(title),
            thumbnail: nil,
            scale: 2
        )
    }

    private func makeImage() -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return context.makeImage()
    }

    private func makeView() -> MusicChipView {
        MusicChipView(frame: NSRect(x: 0, y: 0, width: 160, height: 24), scale: 2)
    }

    // MARK: - The view

    @Test("the chip takes no mouse events, so the button's click and hover keep working under it")
    func takesNoMouseEvents() {
        let view = makeView()
        view.show(spec: spec(shortTitle), geometry: geometry(shortTitle), thumbnail: nil, change: .content, widthDuration: 0)
        #expect(view.hitTest(NSPoint(x: 20, y: 12)) == nil)
        #expect(view.hitTest(NSPoint(x: -5, y: -5)) == nil)
    }

    @Test("the pill is as wide as the title's geometry says")
    func pillFollowsTheTitle() {
        let view = makeView()
        view.show(spec: spec(shortTitle), geometry: geometry(shortTitle), thumbnail: nil, change: .content, widthDuration: 0)
        #expect(view.pillWidth == geometry(shortTitle).pillWidth)
        view.show(spec: spec(longTitle), geometry: geometry(longTitle), thumbnail: nil, change: .content, widthDuration: 0.35)
        #expect(view.pillWidth == geometry(longTitle).pillWidth)
        view.show(spec: spec("Hi"), geometry: geometry("Hi"), thumbnail: nil, change: .content, widthDuration: 0.35)
        #expect(view.pillWidth == geometry("Hi").pillWidth)
    }

    @Test("a pause narrows the pill to the paused width and a play brings the title's width back")
    func pauseNarrowsThePill() {
        let view = makeView()
        view.show(spec: spec(longTitle), geometry: geometry(longTitle), thumbnail: nil, change: .content, widthDuration: 0)
        let width = view.pillWidth
        #expect(width == geometry(longTitle).pillWidth)
        view.show(spec: spec(longTitle, isPlaying: false), geometry: geometry(longTitle), thumbnail: nil, change: .playback, widthDuration: 0.35)
        #expect(view.pillWidth == MusicChipLayout.pausedPillWidth)
        view.show(spec: spec(longTitle), geometry: geometry(longTitle), thumbnail: nil, change: .playback, widthDuration: 0.35)
        #expect(view.pillWidth == width)
    }

    @Test("the paused width is the same for every title")
    func pausedWidthIgnoresTheTitle() {
        let view = makeView()
        for title in [shortTitle, longTitle, "Hi", ""] {
            view.show(spec: spec(title, isPlaying: false), geometry: geometry(title), thumbnail: nil, change: .content, widthDuration: 0)
            #expect(view.pillWidth == MusicChipLayout.pausedPillWidth)
        }
    }

    @Test("the play glyph shows only while paused, and the cover and title only while playing")
    func glyphAndContentTradePlaces() {
        let view = makeView()
        view.show(spec: spec(shortTitle), geometry: geometry(shortTitle), thumbnail: nil, change: .content, widthDuration: 0)
        #expect(view.playGlyphOpacity == 0)
        #expect(view.contentOpacity == 1)
        view.show(spec: spec(shortTitle, isPlaying: false), geometry: geometry(shortTitle), thumbnail: nil, change: .playback, widthDuration: 0.35)
        #expect(view.playGlyphOpacity == 1)
        #expect(view.contentOpacity == 0)
        view.show(spec: spec(shortTitle), geometry: geometry(shortTitle), thumbnail: nil, change: .playback, widthDuration: 0.35)
        #expect(view.playGlyphOpacity == 0)
        #expect(view.contentOpacity == 1)
    }

    @Test("the first appearance of a paused song shows the paused look at once")
    func firstAppearanceWhilePaused() {
        let view = makeView()
        view.show(spec: spec(longTitle, isPlaying: false), geometry: geometry(longTitle), thumbnail: nil, change: .content, widthDuration: 0.35)
        #expect(view.pillWidth == MusicChipLayout.pausedPillWidth)
        #expect(view.playGlyphOpacity == 1)
        #expect(view.contentOpacity == 0)
    }

    @Test("a new song while paused keeps the paused look, and a play then brings in the new title's width")
    func songChangeWhilePaused() {
        let view = makeView()
        view.show(spec: spec(shortTitle, isPlaying: false), geometry: geometry(shortTitle), thumbnail: nil, change: .content, widthDuration: 0)
        view.show(spec: spec(longTitle, isPlaying: false), geometry: geometry(longTitle), thumbnail: nil, change: .content, widthDuration: 0.35)
        #expect(view.pillWidth == MusicChipLayout.pausedPillWidth)
        #expect(view.playGlyphOpacity == 1)
        #expect(view.contentOpacity == 0)
        view.show(spec: spec(longTitle), geometry: geometry(longTitle), thumbnail: nil, change: .playback, widthDuration: 0.35)
        #expect(view.pillWidth == geometry(longTitle).pillWidth)
        #expect(view.playGlyphOpacity == 0)
        #expect(view.contentOpacity == 1)
    }

    @Test("a new song while playing keeps the glyph away")
    func songChangeWhilePlaying() {
        let view = makeView()
        view.show(spec: spec(shortTitle), geometry: geometry(shortTitle), thumbnail: nil, change: .content, widthDuration: 0)
        view.show(spec: spec(longTitle), geometry: geometry(longTitle), thumbnail: nil, change: .content, widthDuration: 0.35)
        #expect(view.playGlyphOpacity == 0)
        #expect(view.contentOpacity == 1)
    }

    @Test("a song that changes while it pauses lands on the paused look")
    func songChangeWithPause() {
        let view = makeView()
        view.show(spec: spec(shortTitle), geometry: geometry(shortTitle), thumbnail: nil, change: .content, widthDuration: 0)
        view.show(spec: spec(longTitle, isPlaying: false), geometry: geometry(longTitle), thumbnail: nil, change: .content, widthDuration: 0.35)
        #expect(view.pillWidth == MusicChipLayout.pausedPillWidth)
        #expect(view.playGlyphOpacity == 1)
        #expect(view.contentOpacity == 0)
    }

    @Test("a cover that arrives with a pause still narrows the pill")
    func coverWithPause() {
        let view = makeView()
        view.show(spec: spec(shortTitle), geometry: geometry(shortTitle), thumbnail: nil, change: .content, widthDuration: 0)
        view.show(spec: spec(shortTitle, isPlaying: false), geometry: geometry(shortTitle), thumbnail: makeImage(), change: .cover, widthDuration: 0.35)
        #expect(view.pillWidth == MusicChipLayout.pausedPillWidth)
        #expect(view.playGlyphOpacity == 1)
    }

    @Test("a play that changes nothing leaves the paused look alone")
    func repeatedPauseIsHarmless() {
        let view = makeView()
        view.show(spec: spec(shortTitle, isPlaying: false), geometry: geometry(shortTitle), thumbnail: nil, change: .content, widthDuration: 0)
        view.show(spec: spec(shortTitle, isPlaying: false), geometry: geometry(shortTitle), thumbnail: nil, change: .playback, widthDuration: 0.35)
        #expect(view.pillWidth == MusicChipLayout.pausedPillWidth)
        #expect(view.playGlyphOpacity == 1)
        #expect(view.contentOpacity == 0)
    }

    @Test("a cover that arrives later keeps the pill and the title on screen")
    func coverKeepsTheWidth() {
        let view = makeView()
        view.show(spec: spec(longTitle), geometry: geometry(longTitle), thumbnail: nil, change: .content, widthDuration: 0)
        let width = view.pillWidth
        view.show(spec: spec(longTitle), geometry: geometry(longTitle), thumbnail: makeImage(), change: .cover, widthDuration: 0.35)
        #expect(view.pillWidth == width)
    }

    @Test("a cover change before any content is shown does nothing")
    func coverBeforeContent() {
        let view = makeView()
        view.show(spec: spec(shortTitle), geometry: geometry(shortTitle), thumbnail: makeImage(), change: .cover, widthDuration: 0)
        #expect(view.pillWidth == 0)
    }

    @Test("no change shows nothing and keeps the pill")
    func noChange() {
        let view = makeView()
        view.show(spec: spec(shortTitle), geometry: geometry(shortTitle), thumbnail: nil, change: .none, widthDuration: 0)
        #expect(view.pillWidth == 0)
    }

    @Test("an empty title still makes a pill with a cover")
    func emptyTitle() {
        let view = makeView()
        view.show(spec: spec(""), geometry: geometry(""), thumbnail: nil, change: .content, widthDuration: 0)
        #expect(view.pillWidth == 28)
    }

    @Test("the pill lights itself while the popover is open and goes dark again when it closes")
    func pillHighlight() {
        let view = makeView()
        view.show(spec: spec(shortTitle), geometry: geometry(shortTitle), thumbnail: nil, change: .content, widthDuration: 0)
        #expect(view.highlightOpacity == 0)
        view.setHighlighted(true)
        #expect(view.highlightOpacity == 1)
        #expect(view.contentOpacity == 1)
        view.setHighlighted(false)
        #expect(view.highlightOpacity == 0)
    }

    // MARK: - The cover

    @Test("a cover that was missing is taken in once it arrives")
    func coverArrivesLate() throws {
        let chip = content(shortTitle)
        #expect(chip.thumbnail == nil)
        chip.setCover(makeImage())
        #expect(chip.thumbnail != nil)
    }

    @Test("a cover that is already shown is not swapped, and a missing one takes nothing away")
    func coverIsOnlyBroughtIn() throws {
        let chip = content(shortTitle)
        chip.setCover(nil)
        #expect(chip.thumbnail == nil)
        let first = try #require(makeImage())
        chip.setCover(first)
        chip.setCover(makeImage())
        chip.setCover(nil)
        #expect(chip.thumbnail === first)
    }

    @Test("a late cover does not touch a scrolling title")
    func coverLeavesTheMarquee() {
        let chip = content(longTitle)
        chip.begin()
        chip.setCover(makeImage())
        #expect(chip.isScrolling)
    }

    // MARK: - Paused content

    @Test("the cover and title of a paused song are hidden, a playing one's are shown")
    func contentIsHiddenWhilePaused() {
        #expect(content(shortTitle, isPlaying: false).layer.opacity == 0)
        #expect(content(shortTitle, isPlaying: true).layer.opacity == 1)
    }

    @Test("a pause hides the content, a play shows it again")
    func playbackTradesTheContentsOpacity() {
        let chip = content(shortTitle)
        chip.setPlaying(false)
        #expect(chip.layer.opacity == 0)
        chip.setPlaying(true)
        #expect(chip.layer.opacity == 1)
    }

    @Test("a pause with no fade time hides the content at once, with no animation left running")
    func instantPause() {
        let chip = content(shortTitle)
        chip.setPlaying(false, fadeDuration: 0)
        #expect(chip.layer.opacity == 0)
        #expect(chip.layer.animationKeys()?.isEmpty ?? true)
    }

    @Test("a pause with a fade time animates the content out")
    func fadedPause() {
        let chip = content(shortTitle)
        chip.setPlaying(false)
        #expect(chip.layer.animationKeys()?.isEmpty == false)
    }

    // MARK: - The play glyph

    /// The pixels of `image` as RGBA bytes, rows from the top.
    private func pixels(of image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    @Test("the play glyph is a white triangle in a square of its own size, centred in it")
    func playGlyphImage() throws {
        let scale = 2.0
        let image = try #require(MusicChipRenderer.playGlyphImage(scale: scale))
        let side = Int(MusicChipLayout.playGlyphSide * scale)
        #expect(image.width == side)
        #expect(image.height == side)

        let bytes = pixels(of: image)
        var minX = side
        var maxX = -1
        var minY = side
        var maxY = -1
        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * 4
                let alpha = bytes[offset + 3]
                guard alpha > 128 else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                // Premultiplied white: every colour byte equals the alpha.
                #expect(abs(Int(bytes[offset]) - Int(alpha)) <= 2)
                #expect(abs(Int(bytes[offset + 1]) - Int(alpha)) <= 2)
                #expect(abs(Int(bytes[offset + 2]) - Int(alpha)) <= 2)
            }
        }
        try #require(maxX >= minX && maxY >= minY, "the glyph drew nothing")
        // Centred in its square to within a point's worth of pixels; the layer is what nudges it right.
        let centreX = Double(minX + maxX + 1) / 2
        let centreY = Double(minY + maxY + 1) / 2
        #expect(abs(centreX - Double(side) / 2) <= scale / 2, "x centre \(centreX) of \(side)")
        #expect(abs(centreY - Double(side) / 2) <= scale / 2, "y centre \(centreY) of \(side)")
        // Small beside the 18 pt pill: more than 5 pt and less than 12 pt tall.
        let height = Double(maxY - minY + 1) / scale
        #expect(height > 5 && height < 12, "glyph is \(height) pt tall")
    }

    // MARK: - The marquee

    @Test("a title longer than the max scrolls while the song plays")
    func longTitleScrollsWhilePlaying() {
        let chip = content(longTitle)
        #expect(chip.geometry.scrolls)
        chip.begin()
        #expect(chip.isScrolling)
    }

    @Test("a long title of a paused song stands still until it plays, and the marquee follows the song")
    func marqueeFollowsPlayback() {
        let chip = content(longTitle, isPlaying: false)
        chip.begin()
        #expect(!chip.isScrolling)
        chip.setPlaying(true)
        #expect(chip.isScrolling)
        chip.setPlaying(false)
        #expect(!chip.isScrolling)
        chip.setPlaying(true)
        #expect(chip.isScrolling)
    }

    @Test("a title that fits never scrolls")
    func shortTitleNeverScrolls() {
        let chip = content(shortTitle)
        chip.begin()
        chip.setPlaying(false)
        chip.setPlaying(true)
        #expect(!chip.geometry.scrolls)
        #expect(!chip.isScrolling)
    }

    @Test("a title of exactly the max never scrolls")
    func titleAtTheMaxNeverScrolls() {
        let title = String(repeating: "a", count: MusicChipLayout.maxCharacters)
        let chip = content(title)
        chip.begin()
        #expect(!chip.isScrolling)
    }

    @Test("with Reduce Motion a long title does not scroll")
    func reduceMotionHasNoMarquee() {
        let chip = content(longTitle, reduceMotion: true)
        chip.begin()
        chip.setPlaying(false)
        chip.setPlaying(true)
        #expect(!chip.isScrolling)
    }

    @Test("a play that changes nothing starts nothing twice")
    func repeatedPlayIsHarmless() {
        let chip = content(longTitle)
        chip.begin()
        chip.setPlaying(true)
        chip.begin()
        #expect(chip.isScrolling)
    }
}
