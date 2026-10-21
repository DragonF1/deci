// Deci/Views/MenuBar/MusicChipLengthAnimator.swift
// Steps the Music status item's length from one pill width to the next, on the same ease-in-out curve the pill's own
// layer follows, so the menu bar makes room for the growing pill frame by frame. The display link runs only while a
// change is under way and is gone as soon as it ends.

import AppKit
import QuartzCore

@MainActor
final class MusicChipLengthAnimator: NSObject {
    private let item: NSStatusItem
    private let button: NSStatusBarButton

    private var link: CADisplayLink?
    private var fromWidth = 0.0
    private var toWidth = 0.0
    private var duration = 0.0
    private var startTime = 0.0
    /// Counts changes, so a late safety check from an earlier change does nothing.
    private var generation = 0

    /// The pill width the item was last given, in points.
    private(set) var currentWidth = 0.0

    init(item: NSStatusItem, button: NSStatusBarButton) {
        self.item = item
        self.button = button
        super.init()
    }

    /// Gives the item the length of a pill `width` points wide at once, ending any change under way. The item is
    /// exactly as wide as the pill, so its highlight and hit area match the pill.
    func set(pillWidth width: Double) {
        cancel()
        currentWidth = width
        item.length = width
    }

    /// Moves the item's length to a pill `width` points wide over `duration` seconds, from where it stands now. No
    /// duration is the same as `set`.
    func animate(to width: Double, duration newDuration: Double) {
        guard newDuration > 0, newDuration.isFinite, width != currentWidth else {
            set(pillWidth: width)
            return
        }
        cancel()
        fromWidth = currentWidth
        toWidth = width
        duration = newDuration
        startTime = CACurrentMediaTime()
        generation += 1
        let current = generation

        let newLink = button.displayLink(target: self, selector: #selector(step(_:)))
        newLink.add(to: .main, forMode: .common)
        link = newLink

        // The status item may sit where no display link fires (a screen that is off): the length still ends right.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(newDuration + 0.2))
            guard let self, self.generation == current, self.link != nil else { return }
            self.finish()
        }
    }

    /// Stops a change under way and leaves the item at the width it has reached.
    func cancel() {
        link?.invalidate()
        link = nil
        generation += 1
    }

    @objc private func step(_ displayLink: CADisplayLink) {
        // The frame about to show, not the one on screen now.
        let elapsed = displayLink.targetTimestamp - startTime
        if elapsed >= duration {
            finish()
            return
        }
        let width = MusicChipMotion.easedWidth(from: fromWidth, to: toWidth, elapsed: elapsed, duration: duration)
        currentWidth = width
        item.length = width
    }

    /// The last step, exact, and the link gone.
    private func finish() {
        link?.invalidate()
        link = nil
        currentWidth = toWidth
        item.length = toWidth
    }
}
