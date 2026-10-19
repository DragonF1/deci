// DeciTests/Music/MusicPinBadgeTests.swift
// The size and place of the pin badge on a cover: it scales with the cover, never under the floor, and a round cover
// is inset further so the dot sits on the circle's edge.

import CoreGraphics
import Testing
@testable import Deci

@MainActor
@Suite("MusicPinBadge")
struct MusicPinBadgeTests {

    @Test("The dot is 14 on a row and on the covers of the page rows")
    func diameters() {
        #expect(MusicPinBadge.diameter(coverSize: MusicCollectionRow.coverSize) == 14)
        #expect(MusicPinBadge.diameter(coverSize: MusicSongRowLayout.playlist.coverSize ?? 0) == 14)
    }

    @Test("The dot grows with the cover and never falls under the floor")
    func diameterBounds() {
        #expect(MusicPinBadge.diameter(coverSize: 0) == MusicPinBadge.minDiameter)
        #expect(MusicPinBadge.diameter(coverSize: 1) == MusicPinBadge.minDiameter)
        #expect(MusicPinBadge.diameter(coverSize: 200) > MusicPinBadge.diameter(coverSize: 96))
        #expect(MusicPinBadge.diameter(coverSize: 10_000) > 0)
    }

    @Test("A square cover is inset 4 whatever its size")
    func squareInset() {
        for size: CGFloat in [32, 40, 72, 96, 400] {
            #expect(MusicPinBadge.inset(coverSize: size, circular: false) == 4)
        }
    }

    @Test("A round cover is inset a tenth of its size, and no less than a square one")
    func roundInset() {
        #expect(abs(MusicPinBadge.inset(coverSize: 96, circular: true) - 9.6) < 0.0001)
        #expect(abs(MusicPinBadge.inset(coverSize: 72, circular: true) - 7.2) < 0.0001)
        #expect(MusicPinBadge.inset(coverSize: 40, circular: true) == 4)
        #expect(MusicPinBadge.inset(coverSize: 10, circular: true) == 4)
    }

    @Test("The badge stays inside the cover's square on every cover the Music tab draws")
    func badgeFitsTheSquare() {
        let covers: [CGFloat] = [
            MusicStyle.Size.coverTile, MusicCollectionRow.coverSize,
            MusicSongRowLayout.playlist.coverSize ?? 0,
        ]
        for size in covers {
            for circular in [false, true] {
                let reach = MusicPinBadge.diameter(coverSize: size) + MusicPinBadge.inset(coverSize: size, circular: circular)
                #expect(reach <= size)
            }
        }
    }
}
