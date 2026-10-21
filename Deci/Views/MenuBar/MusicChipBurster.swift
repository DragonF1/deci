// Deci/Views/MenuBar/MusicChipBurster.swift
// The like animation inside the menu bar pill. The chip view is layer-hosting and so can hold no subviews, so the thumb
// and its sparks are drawn by a SwiftUI view laid over it on the status item's button. While it plays, the cover (or a
// paused pill's play glyph) fades away under it, the filled thumb holds for a moment after the animation, and the cover
// comes back. The sparks are drawn within the height of the item and the view takes no clicks.

import AppKit
import Observation
import SwiftUI

/// What the pill's overlay shows. Read by the SwiftUI view, written by `MusicChipBurster`.
@MainActor
@Observable
final class MusicChipBurstModel {
    /// The burst being played; nil when there is none.
    var event: MusicRateBurstCenter.Event?
    /// Whether the thumb is drawn. It fades in with the burst and out when the hold is over.
    var isShown = false
    /// How far right of the pill's middle the thumb stands.
    var slotOffset: Double = 0
}

/// The thumb and its sparks, in the middle of the item, moved to the cover's slot.
struct MusicChipBurstOverlay: View {
    let model: MusicChipBurstModel

    var body: some View {
        ZStack {
            if let event = model.event {
                MusicRateBurstView(
                    event: event,
                    glyphSize: MusicChipLayout.burstGlyphSize,
                    restingOpacity: 1,
                    sparkReach: MusicChipLayout.burstReach
                )
                .offset(x: model.slotOffset)
                // Whole from the first frame, so the collapse and the pop are seen; it fades only on the way out.
                .opacity(model.isShown ? 1 : 0)
                .animation(.easeInOut(duration: MusicRateBurst.Metrics.pillFade), value: model.isShown)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The hosting view of the overlay. It takes no mouse events: the button's click, its hover tracking and the popover
/// toggle all keep working under it.
final class MusicChipBurstHost: NSHostingView<MusicChipBurstOverlay> {
    convenience init(model: MusicChipBurstModel) {
        self.init(rootView: MusicChipBurstOverlay(model: model))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Plays the like animation in the pill: puts the overlay over the chip, lets the cover give way, holds the filled thumb,
/// and gives everything back. One burst at a time; a newer one restarts the sequence.
@MainActor
final class MusicChipBurster {
    /// Waits for `seconds`. A test replaces it, to run the sequence at once.
    typealias Sleep = @MainActor (TimeInterval) async -> Void

    let model = MusicChipBurstModel()

    private let chipView: MusicChipView
    private let container: NSView
    private let sleep: Sleep
    private var host: MusicChipBurstHost?
    /// The wait for the end of the burst: the animation and the hold, then the fade back. Read by the tests.
    private(set) var sequence: Task<Void, Never>?

    /// Whether a burst is on screen.
    var isPlaying: Bool { host != nil }

    /// `container` is the view the chip view lives in (the status item's button); the overlay is laid over all of it.
    init(
        chipView: MusicChipView,
        container: NSView,
        sleep: @escaping Sleep = { seconds in try? await Task.sleep(for: .seconds(seconds)) }
    ) {
        self.chipView = chipView
        self.container = container
        self.sleep = sleep
    }

    /// Shows `event` with its thumb `slotOffset` points right of the pill's middle. A burst that is already showing is
    /// replaced: the cover stays away and the way back is the new burst's.
    func play(_ event: MusicRateBurstCenter.Event, slotOffset: Double) {
        sequence?.cancel()
        if host == nil {
            let host = MusicChipBurstHost(model: model)
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            // Added last, so it is over the chip view and anything else on the button.
            container.addSubview(host)
            self.host = host
        }
        model.slotOffset = slotOffset
        model.event = event
        model.isShown = true
        chipView.setBurstShown(true, duration: MusicRateBurst.Metrics.pillCoverOut)

        let shown = MusicRateBurst.pillShownDuration(of: event.kind, reduceMotion: event.reduceMotion)
        sequence = Task { @MainActor [weak self, sleep] in
            await sleep(shown)
            guard !Task.isCancelled, let self else { return }
            self.beginHandBack()
            await sleep(MusicRateBurst.Metrics.pillFade)
            guard !Task.isCancelled else { return }
            self.finish()
        }
    }

    /// Cuts a showing burst of `kind` short, for the rating that turned it on being taken back: the hold is dropped, the
    /// thumb fades out and the cover fades in at once, and the view comes off when the fade is over. A burst of the other
    /// kind, one already fading and no burst at all are left alone.
    func cancel(_ kind: MusicRateBurst.Kind) {
        guard host != nil, model.isShown, model.event?.kind == kind else { return }
        sequence?.cancel()
        beginHandBack()
        sequence = Task { @MainActor [weak self, sleep] in
            await sleep(MusicRateBurst.Metrics.pillFade)
            guard !Task.isCancelled, let self else { return }
            self.finish()
        }
    }

    /// Follows the pill when its width changes under a showing thumb (a dislike skips to a song with a longer title),
    /// easing over `duration` seconds like the pill does.
    func moveSlot(to offset: Double, duration: Double) {
        guard host != nil, model.slotOffset != offset else { return }
        if duration > 0 {
            withAnimation(.easeInOut(duration: duration)) { model.slotOffset = offset }
        } else {
            model.slotOffset = offset
        }
    }

    /// Takes the burst away at once and gives the cover back, for the chip coming down.
    func stop() {
        sequence?.cancel()
        sequence = nil
        guard host != nil else { return }
        chipView.setBurstShown(false, duration: 0)
        finish()
    }

    /// The hold is over: the thumb fades out as the cover fades in.
    private func beginHandBack() {
        model.isShown = false
        chipView.setBurstShown(false, duration: MusicRateBurst.Metrics.pillFade)
    }

    private func finish() {
        host?.removeFromSuperview()
        host = nil
        model.event = nil
        model.isShown = false
        sequence = nil
    }
}
