// DeciTests/Music/MusicRightColumnHeaderLayoutTests.swift
// The Music header with the search field open: the three tabs sit beside it while that leaves the field its base width,
// otherwise only the active tab stays. With the field closed, the three tabs and the trailing buttons all fit the
// compact popup. The header is laid out and drawn offscreen (a hosting view that is never put in a window) and read
// back from the bitmap, so these see the real layout. Everything is measured in points: the bitmap's scale is divided
// out, so a 2x context reads the same as a 1x one.

import AppKit
import SwiftUI
import Testing
@testable import Deci

@MainActor
@Suite("MusicRightColumnHeader layout")
struct MusicRightColumnHeaderLayoutTests {
    /// The header drawn at one width, with its scale from pixels to points.
    private struct Drawn {
        let rep: NSBitmapImageRep
        let scale: CGFloat

        /// The sRGB colour at `x` points from the left on the row `row` points from the top.
        func color(x: Int, row: Int) -> NSColor? {
            rep.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(row) * scale))?.usingColorSpace(.sRGB)
        }
    }

    /// The field's outline in points: where its left side starts and where its right side ends.
    private struct Outline {
        let left: CGFloat
        let right: CGFloat
        var width: CGFloat { right - left }
    }

    private func makeNavigation(tab: MusicBrowseStore.Tab, fieldOpen: Bool) async -> (MusicService, MusicSearchNavigation) {
        let service = MusicService(
            backend: FakeMusicBackend(signedIn: true),
            player: MusicPlayer(engine: FakePlaybackEngine()),
            presentSignIn: { _ in },
            presentChannelPicker: { _, _ in },
            closeSignInWindow: {},
            raiseSignInWindow: {},
            nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
            refreshOnCreate: false
        )
        await service.refreshAuth()
        let navigation = MusicSearchNavigation(service: service)
        navigation.select(tab)
        if fieldOpen { navigation.openField() }
        return (service, navigation)
    }

    private func draw(tab: MusicBrowseStore.Tab, fieldOpen: Bool, columnWidth: CGFloat) async throws -> Drawn {
        let (service, navigation) = await makeNavigation(tab: tab, fieldOpen: fieldOpen)
        let header = MusicRightColumnHeader(service: service, navigation: navigation, isAccountCardOpen: .constant(false))
            .background(Color(white: 0.09))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: header)
        host.frame = NSRect(x: 0, y: 0, width: columnWidth, height: MusicPopupMetrics.rightPaddingTop + MusicPopupMetrics.headerHeight)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        #expect(scale >= 1)
        return Drawn(rep: rep, scale: scale)
    }

    /// The open field's outline at a popup size: the accent pixels on the middle row of the 32 pt header are its two sides.
    private func outline(of tab: MusicBrowseStore.Tab, popupWidth: CGFloat) async throws -> Outline {
        let columnWidth = MusicPopupMetrics.rightColumnWidth(popupWidth: popupWidth)
        let drawn = try await draw(tab: tab, fieldOpen: true, columnWidth: columnWidth)
        let row = Int(MusicPopupMetrics.rightPaddingTop + MusicPopupMetrics.headerHeight / 2)
        var columns: [Int] = []
        for x in 0..<Int(columnWidth) {
            guard let color = drawn.color(x: x, row: row) else { continue }
            if color.redComponent > color.blueComponent + 0.15, color.redComponent > 0.3 { columns.append(x) }
        }
        let first = try #require(columns.first)
        let last = try #require(columns.last)
        return Outline(left: CGFloat(first), right: CGFloat(last + 1))
    }

    // MARK: - The field open

    @Test(
        "the field is never narrower than it was beside two tabs, on any tab at any popup size",
        arguments: [MusicBrowseStore.Tab.home, .library, .history], MenuBarPopupSize.allCases
    )
    func fieldKeepsItsBaseWidth(tab: MusicBrowseStore.Tab, size: MenuBarPopupSize) async throws {
        let field = try await outline(of: tab, popupWidth: size.dimensions.width)
        // One point of slack for the outline's antialiased edge.
        #expect(field.width >= MusicPopupMetrics.openFieldMinWidth - 1)
    }

    @Test("in the compact popup only the active tab stays beside the open field", arguments: [MusicBrowseStore.Tab.home, .library, .history])
    func compactKeepsTheActiveTab(tab: MusicBrowseStore.Tab) async throws {
        let field = try await outline(of: tab, popupWidth: MenuBarPopupSize.compact.dimensions.width)
        // The side padding, one label (at most about 60 pt) and the gap: far left of where three labels would end.
        #expect(field.left < 110)
    }

    @Test("a popup too narrow for three tabs and the base field keeps one tab, the widest keeps all three")
    func widthDecidesTheTabs() async throws {
        let comfortable = try await outline(of: .history, popupWidth: MenuBarPopupSize.comfortable.dimensions.width)
        #expect(comfortable.left < 110)

        // Home, Library and History take about 160 pt, so the field starts well past 150 pt.
        let spacious = try await outline(of: .history, popupWidth: MenuBarPopupSize.spacious.dimensions.width)
        #expect(spacious.left > 150)
        #expect(spacious.width >= MusicPopupMetrics.openFieldMinWidth - 1)
    }

    // MARK: - The field closed

    /// How many of the points in `columns` (from the left of `a`) differ from the same points of `b` shifted `shift`
    /// points to the right, and how many of them carry ink (a label or a glyph, not the background).
    private func compare(_ a: Drawn, _ b: Drawn, columns: Range<Int>, shift: Int) -> (differing: Int, inked: Int) {
        var differing = 0
        var inked = 0
        for x in columns {
            for row in 0..<Int(MusicPopupMetrics.rightPaddingTop + MusicPopupMetrics.headerHeight) {
                guard let left = a.color(x: x, row: row), let right = b.color(x: x + shift, row: row) else { continue }
                let delta = abs(left.redComponent - right.redComponent) + abs(left.greenComponent - right.greenComponent)
                    + abs(left.blueComponent - right.blueComponent)
                if delta > 0.06 { differing += 1 }
                if left.redComponent > 0.3 { inked += 1 }
            }
        }
        return (differing, inked)
    }

    @Test("with the field closed, the compact popup shows all three tabs and the refresh, magnifier and avatar unclipped")
    func closedHeaderFitsCompact() async throws {
        let compact = MusicPopupMetrics.rightColumnWidth(popupWidth: MenuBarPopupSize.compact.dimensions.width)
        let wide: CGFloat = 600
        let narrow = try await draw(tab: .home, fieldOpen: false, columnWidth: compact)
        let roomy = try await draw(tab: .home, fieldOpen: false, columnWidth: wide)

        // Home's refresh is there: it is the leftmost of the trailing buttons, so the trailing 100 pt hold all three.
        let trailing = Int(compact) - 100 ..< Int(compact)
        // The tabs lead the header. Up to 185 pt is where the three labels end and the refresh button has not begun.
        let leading = 0 ..< 185

        // Roomy is the header with nothing to squeeze it. The compact popup draws the tabs exactly as it does, and the
        // buttons at the trailing edge exactly as it does.
        let tabs = compare(narrow, roomy, columns: leading, shift: 0)
        #expect(tabs.inked > 150, "the three labels draw ink")
        #expect(tabs.differing == 0, "no tab label is cut or moved")

        let buttons = compare(narrow, roomy, columns: trailing, shift: Int(wide - compact))
        #expect(buttons.inked > 80, "the refresh, the magnifier and the avatar draw ink")
        #expect(buttons.differing == 0, "no trailing button is cut or moved")
    }
}
