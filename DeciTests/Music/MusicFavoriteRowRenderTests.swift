// DeciTests/Music/MusicFavoriteRowRenderTests.swift
// Offscreen renders of the transport row with different favorites in its slots, for review. No window is opened.

import AppKit
import SwiftUI
import Testing
@testable import Deci

@MainActor
@Suite("Music favorite row render")
struct MusicFavoriteRowRenderTests {
    static let outDir = "/Volumes/Storage/_test/deci-favorites"

    private func row(_ slots: MusicFavoriteSlots, snapshot: MusicFavoriteSnapshot) -> some View {
        MusicTransportRow(slots: slots, snapshot: snapshot, canGoNext: true, state: .paused, actions: .none)
        .padding(12)
        .background(MusicStyle.Palette.playerPanel)
        .environment(\.colorScheme, .light)
    }

    private func render(_ view: some View, name: String) throws -> NSImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: Self.outDir, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: "\(Self.outDir)/\(name)"))
        return image
    }

    @Test("the three rows render at the same size, so a swapped slot shifts nothing")
    func rows() throws {
        let defaults = try render(row(.default, snapshot: MusicFavoriteSnapshot()), name: "row-1-defaults.png")
        let crossfadeLike = try render(
            row(MusicFavoriteSlots(left: .crossfade, right: .like), snapshot: MusicFavoriteSnapshot(crossfade: true, isLiked: true, canLike: true)),
            name: "row-2-crossfade-like.png"
        )
        let autoplay = try render(
            row(MusicFavoriteSlots(left: .autoplay, right: .loop), snapshot: MusicFavoriteSnapshot(autoplay: true)),
            name: "row-3-autoplay.png"
        )
        #expect(defaults.size.width > 0)
        #expect(defaults.size == crossfadeLike.size)
        #expect(defaults.size == autoplay.size)
    }
}
