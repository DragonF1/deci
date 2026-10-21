// DeciTests/Music/MusicChipBurstCenteringTests.swift
// Where the like animation's thumb sits in the menu bar pill, measured on the pixels. The pill and the overlay are drawn
// offscreen as the status item draws them (MusicChipBurstRender), the white ink of the held thumb is measured to a
// fraction of a point, and its middle is compared with the middle of the cover it takes the place of. The thumb as the
// symbol draws it stands low and a little right of its box in that drawing, which is what MusicChipLayout's ink
// nudge puts right. The render stands in for a 1x and a 2x display (RenderWindow), because the backing scale decides
// how SwiftUI snaps what it places: to half a point at 2x, to whole points at 1x.

import AppKit
import Testing
@testable import Deci

@MainActor
@Suite("Music chip burst centring")
struct MusicChipBurstCenteringTests {
    /// How far the thumb's ink may be from the cover's middle, in points. At 2x, where a Retina status item snaps to half
    /// a point, a quarter. At 1x the thumb can only stand on whole points, and a thumb whose ink is a fraction of a point
    /// off the middle of its box cannot be put closer than that fraction: the filled thumb's is 0.36 up and down and
    /// 0.45 sideways, so 1x gets 0.4 and 0.6.
    private func tolerance(scale: Int, vertical: Bool) -> Double {
        scale >= 2 ? 0.25 : (vertical ? 0.4 : 0.6)
    }

    private let kinds: [MusicRateBurst.Kind] = [.like, .dislike]
    private let scales = [1, 2]
    private let heights: [Double] = [22, 24]

    private struct Measured {
        let pill: MusicChipBurstRender.Box
        let cover: MusicChipBurstRender.Box
        let thumb: MusicChipBurstRender.Box
    }

    /// The pill, its cover and the held thumb of a burst or a removal, measured.
    private func measure(
        kind: MusicRateBurst.Kind,
        isRemoval: Bool,
        scale: Int,
        height: Double
    ) throws -> Measured {
        let render = MusicChipBurstRender(scale: scale, height: height)
        let cover = render.drawCover()
        let fill = render.fillLevel(of: cover)
        let thumb = render.drawThumb(of: MusicChipBurstRender.event(kind, isRemoval: isRemoval), elapsed: 5)
        return Measured(
            pill: try #require(render.pillBox(in: cover)),
            cover: try #require(render.whiteBox(in: cover, fill: fill)),
            thumb: try #require(render.whiteBox(in: thumb, fill: fill))
        )
    }

    @Test("The cover is centred in the pill, so the pill's middle and the cover's middle are the one mark to centre on")
    func coverIsCentredInThePill() throws {
        for height in heights {
            for scale in scales {
                let m = try measure(kind: .like, isRemoval: false, scale: scale, height: height)
                #expect(abs(m.cover.centerY - m.pill.centerY) <= 0.05, "height \(height) at \(scale)x")
            }
        }
    }

    @Test("The held thumb of a like or a dislike has its ink centred on the cover's middle, up and down, at 1x and 2x")
    func burstThumbIsCentredVertically() throws {
        for kind in kinds {
            for height in heights {
                for scale in scales {
                    let m = try measure(kind: kind, isRemoval: false, scale: scale, height: height)
                    let off = m.thumb.centerY - m.cover.centerY
                    #expect(abs(off) <= tolerance(scale: scale, vertical: true), "\(kind) burst, height \(height) at \(scale)x is \(off) pt off")
                }
            }
        }
    }

    @Test("The held thumb of a like or a dislike has its ink centred on the cover's middle, left and right, at 1x and 2x")
    func burstThumbIsCentredHorizontally() throws {
        for kind in kinds {
            for height in heights {
                for scale in scales {
                    let m = try measure(kind: kind, isRemoval: false, scale: scale, height: height)
                    let off = m.thumb.centerX - m.cover.centerX
                    #expect(abs(off) <= tolerance(scale: scale, vertical: false), "\(kind) burst, height \(height) at \(scale)x is \(off) pt off")
                }
            }
        }
    }

    @Test("The outline thumb of a removal is centred on the cover's middle too, up and down and left and right")
    func removalThumbIsCentred() throws {
        for kind in kinds {
            for height in heights {
                for scale in scales {
                    let m = try measure(kind: kind, isRemoval: true, scale: scale, height: height)
                    let vertical = m.thumb.centerY - m.cover.centerY
                    let horizontal = m.thumb.centerX - m.cover.centerX
                    #expect(abs(vertical) <= tolerance(scale: scale, vertical: true), "\(kind) removal, height \(height) at \(scale)x is \(vertical) pt off, up and down")
                    #expect(abs(horizontal) <= tolerance(scale: scale, vertical: false), "\(kind) removal, height \(height) at \(scale)x is \(horizontal) pt off, sideways")
                }
            }
        }
    }

    @Test("The thumb fills the cover's slot as a thumb should: about as tall as the 12 pt cover, never past it")
    func thumbSizeFitsTheSlot() throws {
        for kind in kinds {
            let m = try measure(kind: kind, isRemoval: false, scale: 2, height: 22)
            let tall = m.thumb.bottom - m.thumb.top
            #expect(tall > 8)
            #expect(tall <= MusicChipLayout.thumbnailSize + 0.5)
            #expect(m.thumb.top >= m.pill.top)
            #expect(m.thumb.bottom <= m.pill.bottom)
        }
    }

    @Test("The removal's thumb and the burst's rest on the same spot, so one replaces the other without a jump")
    func removalAndBurstShareASpot() throws {
        for kind in kinds {
            let burst = try measure(kind: kind, isRemoval: false, scale: 2, height: 22)
            let removal = try measure(kind: kind, isRemoval: true, scale: 2, height: 22)
            #expect(abs(burst.thumb.centerY - removal.thumb.centerY) <= tolerance(scale: 2, vertical: true))
            #expect(abs(burst.thumb.centerX - removal.thumb.centerX) <= tolerance(scale: 2, vertical: false))
        }
    }
}
