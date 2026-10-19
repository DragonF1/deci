// Deci/Music/Lyrics/LyricsScrollGeometry.swift
import CoreGraphics

/// Where the synced list has to scroll to put a line at the anchor, from plain numbers: the row's place in the content,
/// the visible height and the content height. The view reads those from the real scroll view; nothing here knows about
/// it, so the arithmetic is tested without one.
///
/// Offsets count down from the top of the content (0 is the top), whatever the scroll view's own coordinates are.
enum LyricsScrollGeometry {
    /// The offset that puts the same fraction of the row (`anchor`) on the same fraction of the visible area, which is
    /// what a scroll to a row with an anchor does. Held between the top of the content and its last full screen, so
    /// the list never scrolls past either end. A number that is not finite, or a negative size, leaves the list at 0.
    static func targetOffset(
        rowTop: CGFloat, rowHeight: CGFloat, viewportHeight: CGFloat, contentHeight: CGFloat, anchor: CGFloat
    ) -> CGFloat {
        guard rowTop.isFinite, rowHeight.isFinite, viewportHeight.isFinite, contentHeight.isFinite, anchor.isFinite,
              viewportHeight >= 0, contentHeight >= 0
        else { return 0 }
        let fraction = min(1, max(0, anchor))
        let wanted = rowTop + max(0, rowHeight) * fraction - viewportHeight * fraction
        return min(max(0, contentHeight - viewportHeight), max(0, wanted))
    }

    /// The y of a clip view's bounds origin that shows `offset`. A flipped document (what SwiftUI's scroll view
    /// has) counts from the top, so the origin is the offset; an unflipped one counts from the bottom. The offset is held
    /// inside the content first. A number that is not finite gives 0.
    static func boundsOriginY(
        forOffset offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat, isFlipped: Bool
    ) -> CGFloat {
        guard offset.isFinite, contentHeight.isFinite, viewportHeight.isFinite else { return 0 }
        let furthest = max(0, contentHeight - viewportHeight)
        let held = min(furthest, max(0, offset))
        return isFlipped ? held : furthest - held
    }

    /// True when the list is already within half a point of where it is going: not worth a glide.
    static func isAtTarget(current: CGFloat, target: CGFloat) -> Bool {
        abs(current - target) < 0.5
    }
}
