// DeciTests/Music/MusicChipBurstTests.swift
// The like animation inside the menu bar pill: where the thumb stands (the cover's slot while a song plays, the middle
// while it is paused), how much room the sparks get, the cover and the play glyph giving way to it and coming back, and
// the sequence that shows it, holds it and takes it away, or cuts it short. Layers and views are built and read without a window.

import AppKit
import Testing
@testable import Deci

@MainActor
@Suite("Music chip burst")
struct MusicChipBurstTests {
    private let title = "Night Drive"

    private func spec(isPlaying: Bool = true, title: String = "Night Drive") -> MusicChipSpec {
        MusicChipSpec(
            title: title,
            isPlaying: isPlaying,
            tint: MusicTint(hue: 0.55, saturation: 0.6, brightness: 0.7),
            hasThumbnail: false,
            coverURL: nil,
            reduceMotion: false
        )
    }

    private func geometry(_ title: String = "Night Drive") -> MusicChipGeometry {
        MusicChipLayout.geometry(title: title, measure: { Double($0.count) * 6 })
    }

    private func makeView(isPlaying: Bool = true) -> MusicChipView {
        let view = MusicChipView(frame: NSRect(x: 0, y: 0, width: 160, height: 24), scale: 2)
        view.show(
            spec: spec(isPlaying: isPlaying),
            geometry: geometry(),
            thumbnail: nil,
            change: .content,
            widthDuration: 0
        )
        return view
    }

    private func event(
        _ kind: MusicRateBurst.Kind = .like,
        reduceMotion: Bool = false,
        isRemoval: Bool = false,
        id: Int = 1
    ) -> MusicRateBurstCenter.Event {
        MusicRateBurstCenter.Event(
            id: id,
            kind: kind,
            surface: .pill,
            reduceMotion: reduceMotion,
            startedAt: Date(timeIntervalSince1970: 1_000),
            isRemoval: isRemoval
        )
    }

    // MARK: - Measures

    @Test("The thumb is 11 pt, a point under the cover's 12, and the sparks get half of a 22 pt item to each side")
    func measures() {
        #expect(MusicChipLayout.burstGlyphSize == 11)
        #expect(MusicChipLayout.burstGlyphSize < MusicChipLayout.thumbnailSize)
        #expect(MusicChipLayout.statusItemHeight == 22)
        #expect(MusicChipLayout.burstReach == 11)
        #expect(MusicChipLayout.burstReach * 2 <= MusicChipLayout.statusItemHeight)
        // Scaled to that reach, the whole burst fits the item's height.
        let fit = MusicRateBurst.sparkScale(glyphSize: MusicChipLayout.burstGlyphSize, reach: MusicChipLayout.burstReach)
        #expect(fit * MusicChipLayout.burstGlyphSize * MusicRateBurst.sparkExtent * 2 <= MusicChipLayout.statusItemHeight + 0.0001)
    }

    @Test("The thumb's ink nudge is a small correction, up and to the left, that the overlay passes on to the view")
    func inkNudge() {
        // The symbol is drawn low and to the right of its box in the overlay; the nudge moves it back, by points.
        #expect(MusicChipLayout.burstInkNudgeY < 0)
        #expect(MusicChipLayout.burstInkNudgeX < 0)
        #expect(abs(MusicChipLayout.burstInkNudgeY) < 2)
        #expect(abs(MusicChipLayout.burstInkNudgeX) < 1)
        #expect(MusicChipLayout.burstInkNudge == CGSize(width: MusicChipLayout.burstInkNudgeX, height: MusicChipLayout.burstInkNudgeY))
    }

    @Test("The like and the dislike thumb both stand 2 pt right of the cover's middle, on its line")
    func shiftByKind() {
        #expect(MusicChipLayout.burstShift(of: .like) == CGSize(width: 2, height: 0))
        #expect(MusicChipLayout.burstShift(of: .dislike) == CGSize(width: 2, height: 0))
    }

    @Test("While a song plays the thumb stands where the cover stands: the cover's middle, measured from the pill's middle")
    func slotOfAPlayingSong() {
        // 3 pt inset and half of the 12 pt cover: 9 pt from the pill's left edge.
        #expect(MusicChipLayout.burstSlotOffset(pillWidth: 100, isPlaying: true) == 9 - 50)
        #expect(MusicChipLayout.burstSlotOffset(pillWidth: 60, isPlaying: true) == 9 - 30)
        #expect(MusicChipLayout.burstSlotOffset(pillWidth: 100.5, isPlaying: true) == 9 - 50.25)
    }

    @Test("While the song is paused the thumb stands in the pill's middle, where the play glyph is")
    func slotOfAPausedSong() {
        #expect(MusicChipLayout.burstSlotOffset(pillWidth: MusicChipLayout.pausedPillWidth, isPlaying: false) == 0)
        #expect(MusicChipLayout.burstSlotOffset(pillWidth: 200, isPlaying: false) == 0)
    }

    @Test("A width that cannot be used puts the thumb at the cover's slot of no pill, never off in space")
    func slotOfAnOddWidth() {
        #expect(MusicChipLayout.burstSlotOffset(pillWidth: .nan, isPlaying: true) == 9)
        #expect(MusicChipLayout.burstSlotOffset(pillWidth: -40, isPlaying: true) == 9)
    }

    // MARK: - The cover and the glyph give way

    @Test("The cover gives way to the thumb and comes back, and the title stays")
    func coverGivesWay() {
        let view = makeView()
        #expect(view.coverOpacity == 1)

        view.setBurstShown(true, duration: 0)
        #expect(view.coverOpacity == 0)
        #expect(view.contentOpacity == 1)
        #expect(view.playGlyphOpacity == 0)

        view.setBurstShown(false, duration: 0)
        #expect(view.coverOpacity == 1)
        #expect(view.contentOpacity == 1)
    }

    @Test("A fade time animates the cover and leaves its model value at the end")
    func coverFades() {
        let view = makeView()
        view.setBurstShown(true, duration: 0.18)
        #expect(view.coverOpacity == 0)
        view.setBurstShown(false, duration: 0.18)
        #expect(view.coverOpacity == 1)
    }

    @Test("On a paused pill the play glyph gives way and comes back")
    func glyphGivesWay() {
        let view = makeView(isPlaying: false)
        #expect(view.playGlyphOpacity == 1)

        view.setBurstShown(true, duration: 0)
        #expect(view.playGlyphOpacity == 0)

        view.setBurstShown(false, duration: 0)
        #expect(view.playGlyphOpacity == 1)
    }

    @Test("A pause while the thumb shows keeps the glyph away until the thumb goes, and a play keeps the cover away")
    func playbackChangeDuringTheBurst() {
        let view = makeView()
        view.setBurstShown(true, duration: 0)

        view.show(spec: spec(isPlaying: false), geometry: geometry(), thumbnail: nil, change: .playback, widthDuration: 0)
        #expect(view.playGlyphOpacity == 0)
        view.setBurstShown(false, duration: 0)
        #expect(view.playGlyphOpacity == 1)

        view.setBurstShown(true, duration: 0)
        view.show(spec: spec(isPlaying: true), geometry: geometry(), thumbnail: nil, change: .playback, widthDuration: 0)
        #expect(view.playGlyphOpacity == 0)
        #expect(view.coverOpacity == 0)
        view.setBurstShown(false, duration: 0)
        #expect(view.coverOpacity == 1)
        #expect(view.playGlyphOpacity == 0)
    }

    @Test("A new song while the thumb shows brings its cover in hidden, so the thumb is not drawn over a picture")
    func newSongDuringTheBurst() {
        let view = makeView()
        view.setBurstShown(true, duration: 0)

        view.show(
            spec: spec(title: "Another One"),
            geometry: geometry("Another One"),
            thumbnail: nil,
            change: .content,
            widthDuration: 0.35
        )

        #expect(view.coverOpacity == 0)
        #expect(view.contentOpacity == 1)
        view.setBurstShown(false, duration: 0.18)
        #expect(view.coverOpacity == 1)
    }

    @Test("Showing the thumb twice, or taking it away when it is not there, changes nothing")
    func burstShownIsIdempotent() {
        let view = makeView()
        view.setBurstShown(false, duration: 0)
        #expect(view.coverOpacity == 1)
        view.setBurstShown(true, duration: 0)
        view.setBurstShown(true, duration: 0)
        #expect(view.coverOpacity == 0)
        view.setBurstShown(false, duration: 0)
        #expect(view.coverOpacity == 1)
    }

    @Test("Before any song shows, the thumb has nothing to hide, and the first content comes in with the cover as it should")
    func burstBeforeContent() {
        let view = MusicChipView(frame: NSRect(x: 0, y: 0, width: 160, height: 24), scale: 2)
        view.setBurstShown(true, duration: 0)
        view.setBurstShown(false, duration: 0)
        view.show(spec: spec(), geometry: geometry(), thumbnail: nil, change: .content, widthDuration: 0)
        #expect(view.coverOpacity == 1)
    }

    // MARK: - The sequence

    @MainActor
    private final class SleepLog {
        var delays: [TimeInterval] = []
    }

    private struct Rig {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        let view: MusicChipView
        let log = SleepLog()
        let burster: MusicChipBurster

        init(view: MusicChipView) {
            self.view = view
            container.addSubview(view)
            let log = self.log
            burster = MusicChipBurster(chipView: view, container: container, sleep: { log.delays.append($0) })
        }

        var hosts: [NSView] { container.subviews.filter { $0 !== view } }
    }

    @Test("A burst puts a view over the pill that takes no clicks, hides the cover, and shows the event at the slot")
    func playStartsTheBurst() throws {
        let rig = Rig(view: makeView())

        rig.burster.play(event(), slotOffset: -41)

        let host = try #require(rig.hosts.first)
        #expect(rig.hosts.count == 1)
        #expect(rig.container.subviews.last === host)
        #expect(host.frame == rig.container.bounds)
        #expect(host.hitTest(NSPoint(x: 20, y: 12)) == nil)
        #expect(rig.view.coverOpacity == 0)
        #expect(rig.burster.model.event == event())
        #expect(rig.burster.model.isShown)
        #expect(rig.burster.model.slotOffset == -41)
        #expect(rig.burster.isPlaying)
    }

    @Test("After the animation and the hold the thumb goes and the cover comes back, and the view is taken off")
    func sequenceEnds() async {
        let rig = Rig(view: makeView())

        rig.burster.play(event(.like), slotOffset: -41)
        await rig.burster.sequence?.value

        #expect(rig.log.delays.count == 2)
        #expect(rig.log.delays.first == MusicRateBurst.pillShownDuration(of: .like, reduceMotion: false))
        #expect(rig.log.delays.last == MusicRateBurst.Metrics.pillFade)
        #expect(rig.view.coverOpacity == 1)
        #expect(rig.hosts.isEmpty)
        #expect(rig.burster.model.event == nil)
        #expect(!rig.burster.model.isShown)
        #expect(!rig.burster.isPlaying)
    }

    @Test("A dislike is shown for its shorter animation and the same hold, and Reduce Motion for the short fade and the hold")
    func sequenceLengths() async {
        let dislike = Rig(view: makeView())
        dislike.burster.play(event(.dislike), slotOffset: 0)
        await dislike.burster.sequence?.value
        #expect(dislike.log.delays.first == 0.33 + 0.7)

        let reduced = Rig(view: makeView())
        reduced.burster.play(event(.like, reduceMotion: true), slotOffset: 0)
        await reduced.burster.sequence?.value
        #expect(reduced.log.delays.first == MusicRateBurst.Metrics.reducedDuration + 0.7)
    }

    @Test("A second burst while the first shows restarts it: one view, the cover stays away throughout, one way back")
    func secondBurstRestarts() async throws {
        let rig = Rig(view: makeView())

        rig.burster.play(event(.like), slotOffset: -41)
        let next = MusicRateBurstCenter.Event(
            id: 2,
            kind: .dislike,
            surface: .pill,
            reduceMotion: false,
            startedAt: Date(timeIntervalSince1970: 1_001)
        )
        rig.burster.play(next, slotOffset: -30)

        #expect(rig.hosts.count == 1)
        #expect(rig.view.coverOpacity == 0)
        #expect(rig.burster.model.event == next)
        #expect(rig.burster.model.slotOffset == -30)

        await rig.burster.sequence?.value
        // The cancelled first sequence took nothing away: only the second one's two sleeps counted to the end.
        #expect(rig.log.delays.last == MusicRateBurst.Metrics.pillFade)
        #expect(rig.view.coverOpacity == 1)
        #expect(rig.hosts.isEmpty)
    }

    @Test("Stopping takes the view off and gives the cover back at once, and a stopped sequence does not run on")
    func stopRestores() async {
        let rig = Rig(view: makeView())
        rig.burster.play(event(), slotOffset: -41)

        rig.burster.stop()

        #expect(rig.hosts.isEmpty)
        #expect(rig.view.coverOpacity == 1)
        #expect(!rig.burster.isPlaying)
        #expect(rig.burster.model.event == nil)
        await rig.burster.sequence?.value
        #expect(rig.view.coverOpacity == 1)
        // Stopping with nothing playing is harmless.
        rig.burster.stop()
        #expect(rig.hosts.isEmpty)
    }

    @Test("Cancelling the kind that shows hands the cover back at once, and takes the view off after one fade")
    func cancelFadesBackEarly() async {
        let rig = Rig(view: makeView())
        rig.burster.play(event(.like), slotOffset: -41)

        rig.burster.cancel(.like)

        // The thumb is already fading out and the cover already coming back, with the hold still unspent.
        #expect(!rig.burster.model.isShown)
        #expect(rig.view.coverOpacity == 1)
        #expect(rig.burster.isPlaying)
        #expect(rig.hosts.count == 1)

        await rig.burster.sequence?.value

        #expect(rig.hosts.isEmpty)
        #expect(!rig.burster.isPlaying)
        #expect(rig.burster.model.event == nil)
        #expect(rig.view.coverOpacity == 1)
        // The first sequence was cancelled: only the cancel's own wait for the fade ran to its end.
        #expect(rig.log.delays.filter { $0 == MusicRateBurst.Metrics.pillFade }.count == 1)
        #expect(rig.log.delays.last == MusicRateBurst.Metrics.pillFade)
    }

    @Test("Cancelling a dislike and a Reduce Motion burst fades back the same way")
    func cancelEveryKind() async {
        let dislike = Rig(view: makeView())
        dislike.burster.play(event(.dislike), slotOffset: 0)
        dislike.burster.cancel(.dislike)
        #expect(!dislike.burster.model.isShown)
        await dislike.burster.sequence?.value
        #expect(dislike.hosts.isEmpty)
        #expect(dislike.view.coverOpacity == 1)

        let reduced = Rig(view: makeView())
        reduced.burster.play(event(.like, reduceMotion: true), slotOffset: 0)
        reduced.burster.cancel(.like)
        #expect(!reduced.burster.model.isShown)
        await reduced.burster.sequence?.value
        #expect(reduced.hosts.isEmpty)
        #expect(reduced.view.coverOpacity == 1)
    }

    @Test("Cancelling the other kind leaves the burst showing, and it runs on to its own end")
    func cancelOfAnotherKindIsIgnored() async {
        let rig = Rig(view: makeView())
        rig.burster.play(event(.dislike), slotOffset: -41)

        rig.burster.cancel(.like)

        #expect(rig.burster.model.isShown)
        #expect(rig.view.coverOpacity == 0)
        #expect(rig.burster.isPlaying)

        await rig.burster.sequence?.value

        #expect(rig.log.delays == [MusicRateBurst.pillShownDuration(of: .dislike, reduceMotion: false), MusicRateBurst.Metrics.pillFade])
        #expect(rig.hosts.isEmpty)
        #expect(rig.view.coverOpacity == 1)
    }

    @Test("Cancelling with nothing showing does nothing: no view, no wait, no change to the cover")
    func cancelWhenIdleIsIgnored() async {
        let rig = Rig(view: makeView())

        rig.burster.cancel(.like)

        #expect(rig.hosts.isEmpty)
        #expect(!rig.burster.isPlaying)
        #expect(rig.burster.sequence == nil)
        #expect(rig.log.delays.isEmpty)
        #expect(rig.view.coverOpacity == 1)

        // Nor after a burst has run its course.
        rig.burster.play(event(.like), slotOffset: -41)
        await rig.burster.sequence?.value
        let waits = rig.log.delays.count
        rig.burster.cancel(.like)
        #expect(rig.burster.sequence == nil)
        #expect(rig.log.delays.count == waits)
        #expect(rig.hosts.isEmpty)
    }

    @Test("A second cancel while the thumb is already fading changes nothing")
    func cancelTwiceIsIgnored() async {
        let rig = Rig(view: makeView())
        rig.burster.play(event(.like), slotOffset: -41)
        rig.burster.cancel(.like)
        let fade = rig.burster.sequence

        rig.burster.cancel(.like)

        #expect(rig.burster.sequence == fade)
        await rig.burster.sequence?.value
        #expect(rig.log.delays.filter { $0 == MusicRateBurst.Metrics.pillFade }.count == 1)
        #expect(rig.hosts.isEmpty)
    }

    @Test("A burst that comes after a cancel plays whole: the fade of the cancelled one does not take it away")
    func burstAfterCancelPlaysWhole() async {
        let rig = Rig(view: makeView())
        rig.burster.play(event(.like), slotOffset: -41)
        rig.burster.cancel(.like)

        rig.burster.play(event(.like), slotOffset: -41)

        #expect(rig.burster.model.isShown)
        #expect(rig.view.coverOpacity == 0)
        #expect(rig.hosts.count == 1)
        await rig.burster.sequence?.value
        #expect(rig.hosts.isEmpty)
        #expect(rig.view.coverOpacity == 1)
    }

    // MARK: - A rating taken back

    @Test("The overlay's model starts empty: no event, nothing shown, the clock running, and a first thumb that fades in")
    func modelStartsEmpty() {
        let model = MusicChipBurstModel()
        #expect(model.event == nil)
        #expect(!model.isShown)
        #expect(model.pinnedElapsed == nil)
        #expect(model.fadesIn)
        #expect(model.slotOffset == 0)
    }

    @Test("A burster never pins the clock: only a render does")
    func bursterLeavesTheClockRunning() {
        let rig = Rig(view: makeView())
        rig.burster.play(event(.like, isRemoval: true), slotOffset: -41)
        #expect(rig.burster.model.pinnedElapsed == nil)
        rig.burster.play(event(.like, id: 2), slotOffset: -41)
        #expect(rig.burster.model.pinnedElapsed == nil)
    }

    @Test("A removal puts the same view over the pill, hides the cover, and shows the outline thumb at the slot")
    func removalStartsLikeABurst() throws {
        let rig = Rig(view: makeView())

        rig.burster.play(event(.like, isRemoval: true), slotOffset: -41)

        let host = try #require(rig.hosts.first)
        #expect(rig.hosts.count == 1)
        #expect(rig.container.subviews.last === host)
        #expect(host.frame == rig.container.bounds)
        #expect(host.hitTest(NSPoint(x: 20, y: 12)) == nil)
        #expect(rig.view.coverOpacity == 0)
        #expect(rig.burster.model.event == event(.like, isRemoval: true))
        #expect(rig.burster.model.isShown)
        #expect(rig.burster.model.slotOffset == -41)
        #expect(rig.burster.isPlaying)
    }

    @Test("A removal comes in with the cover going out; a thumb that is already there is not faded in again")
    func fadesInOnlyOverAnEmptySlot() async {
        let rig = Rig(view: makeView())
        #expect(rig.burster.model.fadesIn)

        rig.burster.play(event(.like, isRemoval: true), slotOffset: -41)
        #expect(rig.burster.model.fadesIn)

        rig.burster.play(event(.like, isRemoval: true, id: 2), slotOffset: -41)
        #expect(!rig.burster.model.fadesIn)

        await rig.burster.sequence?.value
        // Once it is all over the next one comes into an empty slot again.
        rig.burster.play(event(.dislike, isRemoval: true, id: 3), slotOffset: -41)
        #expect(rig.burster.model.fadesIn)
    }

    @Test("After its settle and the hold the thumb goes and the cover comes back, and the view is taken off")
    func removalSequenceEnds() async {
        let rig = Rig(view: makeView())

        rig.burster.play(event(.like, isRemoval: true), slotOffset: -41)
        await rig.burster.sequence?.value

        #expect(rig.log.delays.count == 2)
        #expect(rig.log.delays.first == MusicRateBurst.pillShownDuration(of: .like, reduceMotion: false, isRemoval: true))
        #expect(rig.log.delays.first == MusicRateBurst.Metrics.removalSettle + MusicRateBurst.Metrics.pillHold)
        #expect(rig.log.delays.last == MusicRateBurst.Metrics.pillFade)
        #expect(rig.view.coverOpacity == 1)
        #expect(rig.hosts.isEmpty)
        #expect(rig.burster.model.event == nil)
        #expect(!rig.burster.model.isShown)
        #expect(!rig.burster.isPlaying)
    }

    @Test("A dislike removal holds the same, and a Reduce Motion one for the short fade and the hold")
    func removalSequenceLengths() async {
        let dislike = Rig(view: makeView())
        dislike.burster.play(event(.dislike, isRemoval: true), slotOffset: 0)
        await dislike.burster.sequence?.value
        #expect(dislike.log.delays.first == MusicRateBurst.Metrics.removalSettle + 0.7)

        let reduced = Rig(view: makeView())
        reduced.burster.play(event(.like, reduceMotion: true, isRemoval: true), slotOffset: 0)
        await reduced.burster.sequence?.value
        #expect(reduced.log.delays.first == MusicRateBurst.Metrics.reducedDuration + 0.7)
    }

    @Test("A removal replaces a burst that shows: one view, the cover stays away, the thumb does not fade in again, one way back")
    func removalReplacesABurst() async {
        let rig = Rig(view: makeView())
        rig.burster.play(event(.like), slotOffset: -41)

        rig.burster.play(event(.like, isRemoval: true, id: 2), slotOffset: -41)

        #expect(rig.hosts.count == 1)
        #expect(rig.view.coverOpacity == 0)
        #expect(rig.burster.model.event == event(.like, isRemoval: true, id: 2))
        #expect(rig.burster.model.isShown)
        #expect(!rig.burster.model.fadesIn)

        await rig.burster.sequence?.value
        // The burst's own hold was dropped: the removal's hold restarted and ran to the end.
        #expect(rig.log.delays.contains(MusicRateBurst.pillShownDuration(of: .like, reduceMotion: false, isRemoval: true)))
        #expect(rig.log.delays.last == MusicRateBurst.Metrics.pillFade)
        #expect(rig.view.coverOpacity == 1)
        #expect(rig.hosts.isEmpty)
        #expect(!rig.burster.model.isShown)
        #expect(rig.burster.model.event == nil)
    }

    @Test("A burst replaces a removal that shows, and plays whole with the cover away until its own end")
    func burstReplacesARemoval() async {
        let rig = Rig(view: makeView())
        rig.burster.play(event(.like, isRemoval: true), slotOffset: -41)

        rig.burster.play(event(.like, id: 2), slotOffset: -41)

        #expect(rig.hosts.count == 1)
        #expect(rig.view.coverOpacity == 0)
        #expect(rig.burster.model.event == event(.like, id: 2))
        #expect(rig.burster.model.isShown)
        #expect(!rig.burster.model.fadesIn)

        await rig.burster.sequence?.value
        #expect(rig.log.delays.contains(MusicRateBurst.pillShownDuration(of: .like, reduceMotion: false)))
        #expect(rig.log.delays.last == MusicRateBurst.Metrics.pillFade)
        #expect(rig.view.coverOpacity == 1)
        #expect(rig.hosts.isEmpty)
    }

    @Test("A removal that comes while the thumb is already fading out brings it in again, with the cover away")
    func removalDuringTheHandBack() async {
        let rig = Rig(view: makeView())
        rig.burster.play(event(.like), slotOffset: -41)
        rig.burster.cancel(.like)
        #expect(!rig.burster.model.isShown)

        rig.burster.play(event(.like, isRemoval: true, id: 2), slotOffset: -41)

        #expect(rig.burster.model.isShown)
        #expect(rig.burster.model.fadesIn)
        #expect(rig.view.coverOpacity == 0)
        await rig.burster.sequence?.value
        #expect(rig.view.coverOpacity == 1)
        #expect(rig.hosts.isEmpty)
    }

    @Test("Cancelling the kind of a showing removal hands the cover back at once, and takes the view off after one fade")
    func cancelCutsARemovalShort() async {
        let rig = Rig(view: makeView())
        rig.burster.play(event(.like, isRemoval: true), slotOffset: -41)

        rig.burster.cancel(.like)

        #expect(!rig.burster.model.isShown)
        #expect(rig.view.coverOpacity == 1)
        #expect(rig.burster.isPlaying)
        await rig.burster.sequence?.value
        #expect(rig.hosts.isEmpty)
        #expect(rig.burster.model.event == nil)
        #expect(rig.view.coverOpacity == 1)
        #expect(rig.log.delays.filter { $0 == MusicRateBurst.Metrics.pillFade }.count == 1)
    }

    @Test("Cancelling the other kind leaves a showing removal alone, and it runs on to its own end")
    func cancelOfAnotherKindKeepsARemoval() async {
        let rig = Rig(view: makeView())
        rig.burster.play(event(.dislike, isRemoval: true), slotOffset: -41)

        rig.burster.cancel(.like)

        #expect(rig.burster.model.isShown)
        #expect(rig.view.coverOpacity == 0)
        await rig.burster.sequence?.value
        #expect(rig.log.delays == [
            MusicRateBurst.pillShownDuration(of: .dislike, reduceMotion: false, isRemoval: true),
            MusicRateBurst.Metrics.pillFade,
        ])
        #expect(rig.hosts.isEmpty)
        #expect(rig.view.coverOpacity == 1)
    }

    @Test("Stopping during a removal takes the view off and gives the cover back at once, and nothing runs on")
    func stopRestoresDuringARemoval() async {
        let rig = Rig(view: makeView())
        rig.burster.play(event(.like, isRemoval: true), slotOffset: -41)

        rig.burster.stop()

        #expect(rig.hosts.isEmpty)
        #expect(rig.view.coverOpacity == 1)
        #expect(!rig.burster.isPlaying)
        #expect(rig.burster.model.event == nil)
        #expect(!rig.burster.model.isShown)
        await rig.burster.sequence?.value
        #expect(rig.view.coverOpacity == 1)
        // The next one starts clean.
        rig.burster.play(event(.like, isRemoval: true, id: 2), slotOffset: -41)
        #expect(rig.hosts.count == 1)
        #expect(rig.burster.model.fadesIn)
    }

    @Test("A paused pill shows the removal in the middle and gives the glyph back after")
    func removalOnAPausedPill() async {
        let rig = Rig(view: makeView(isPlaying: false))
        rig.burster.play(event(.like, isRemoval: true), slotOffset: 0)
        #expect(rig.view.playGlyphOpacity == 0)

        await rig.burster.sequence?.value

        #expect(rig.view.playGlyphOpacity == 1)
        #expect(rig.view.coverOpacity == 1)
    }

    @Test("The slot follows the pill under a showing removal as it does under a burst")
    func slotFollowsThePillUnderARemoval() {
        let rig = Rig(view: makeView())
        rig.burster.play(event(.like, isRemoval: true), slotOffset: -41)
        rig.burster.moveSlot(to: -20, duration: 0)
        #expect(rig.burster.model.slotOffset == -20)
    }

    @Test("The slot follows the pill when its width changes under a thumb that is showing")
    func slotFollowsThePill() {
        let rig = Rig(view: makeView())
        rig.burster.play(event(), slotOffset: -41)

        rig.burster.moveSlot(to: -20, duration: 0.35)
        #expect(rig.burster.model.slotOffset == -20)

        rig.burster.moveSlot(to: -10, duration: 0)
        #expect(rig.burster.model.slotOffset == -10)
    }

    @Test("A paused pill shows the thumb in the middle and gives the glyph back after")
    func pausedPill() async {
        let rig = Rig(view: makeView(isPlaying: false))
        rig.burster.play(event(), slotOffset: 0)
        #expect(rig.view.playGlyphOpacity == 0)
        #expect(rig.burster.model.slotOffset == 0)

        await rig.burster.sequence?.value

        #expect(rig.view.playGlyphOpacity == 1)
        #expect(rig.view.coverOpacity == 1)
    }
}
