// DeciTests/Music/MusicChipViewTests.swift
// The Now playing chip's view and the layers of one song on it: it takes no clicks, the pill follows the title's width,
// a cover that arrives late is brought in without rebuilding the title, and the marquee runs only for a title longer
// than the max while the song plays. Nothing is shown on screen: the layers are built and read without a window.

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

    @Test("a play or pause leaves the pill's width alone")
    func playbackKeepsTheWidth() {
        let view = makeView()
        view.show(spec: spec(longTitle), geometry: geometry(longTitle), thumbnail: nil, change: .content, widthDuration: 0)
        let width = view.pillWidth
        view.show(spec: spec(longTitle, isPlaying: false), geometry: geometry(longTitle), thumbnail: nil, change: .playback, widthDuration: 0.35)
        #expect(view.pillWidth == width)
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
