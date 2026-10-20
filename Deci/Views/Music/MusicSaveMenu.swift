// Deci/Views/Music/MusicSaveMenu.swift
import AppKit
import SwiftUI

/// Where the save to playlist menu opens: its top right corner at the pointer, so it unfolds to the left and down like a
/// submenu of the "..." menu, slid back inside the popup where it would run off an edge. Pure, so it can be tested.
nonisolated enum MusicSaveMenuPlacement {
    /// The room the menu keeps from the popup's edges.
    static let margin: CGFloat = 8

    /// The menu's top left corner in the layer, for a menu of `size` opened at `anchor` (nil: the pointer was not over
    /// the popup, so it opens centred).
    static func origin(anchor: CGPoint?, size: CGSize, in bounds: CGSize) -> CGPoint {
        let maxX = max(margin, bounds.width - size.width - margin)
        let maxY = max(margin, bounds.height - size.height - margin)
        guard let anchor else {
            return CGPoint(x: min(max(margin, (bounds.width - size.width) / 2), maxX),
                           y: min(max(margin, (bounds.height - size.height) / 2), maxY))
        }
        return CGPoint(x: min(max(margin, anchor.x - size.width), maxX),
                       y: min(max(margin, anchor.y), maxY))
    }
}

/// The save to playlist menu, over the whole popup like the account card. It wears the native menu look: the playlists
/// the song can go to, a check on those that hold it. A click adds the song and ticks the row; the menu stays open so it
/// can go to another playlist too. A click outside or Escape closes it. There is no New playlist item: the app cannot
/// make one.
struct MusicSaveMenuLayer: View {
    let store: MusicTrackActionsStore
    let picker: MusicTrackActionsStore.Picker
    let onClose: () -> Void

    static let width: CGFloat = 230
    /// The list scrolls past this many rows.
    static let visibleRows = 12

    /// The pointer when the menu opened, in the layer; nil opens it centred.
    @State private var anchor: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let bounds = geometry.size
            let opened = anchor
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onClose() }
                    .accessibilityHidden(true)

                // The guides place the menu from its own size in the same layout pass, so it never shows misplaced.
                menu
                    .alignmentGuide(.leading) { -Self.origin(opened, $0, bounds).x }
                    .alignmentGuide(.top) { -Self.origin(opened, $0, bounds).y }
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .onAppear { anchor = Self.pointer(in: geometry.frame(in: .global)) }
            // Opened again for another song while open (the chip's card): it moves to the new pointer.
            .onChange(of: picker.track.videoId) { anchor = Self.pointer(in: geometry.frame(in: .global)) }
        }
    }

    nonisolated private static func origin(_ anchor: CGPoint?, _ menu: ViewDimensions, _ bounds: CGSize) -> CGPoint {
        MusicSaveMenuPlacement.origin(anchor: anchor, size: CGSize(width: menu.width, height: menu.height), in: bounds)
    }

    private var menu: some View {
        MusicNativeMenu(width: Self.width) {
            MusicNativeMenuSectionHead(title: "Save to playlist")
            switch picker.load {
            case .idle, .loading:
                MusicNativeMenuItem(title: "Loading playlists\u{2026}", isEnabled: false, leading: {
                    MusicSpinner(size: 10, lineWidth: 1.5, color: .white.opacity(0.75))
                }, action: {})
            case .failed(let message):
                MusicNativeMenuItem(title: message, isEnabled: false) {}
                MusicNativeMenuItem(title: "Try again") { store.openPicker(for: picker.track) }
            case .loaded(let options) where options.isEmpty:
                MusicNativeMenuItem(title: "No playlists you can add to", isEnabled: false) {}
            case .loaded(let options):
                list(options)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Save \(picker.track.title) to playlist")
    }

    /// The rows, scrolling once there are more than fit.
    @ViewBuilder
    private func list(_ options: [MusicPlaylistOption]) -> some View {
        if options.count > Self.visibleRows {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(options, id: \.playlistId) { option in
                        row(option)
                    }
                }
            }
            .frame(height: CGFloat(Self.visibleRows) * MusicNativeMenuMetrics.itemHeight)
        } else {
            VStack(spacing: 0) {
                ForEach(options, id: \.playlistId) { option in
                    row(option)
                }
            }
        }
    }

    private func row(_ option: MusicPlaylistOption) -> some View {
        let isSaving = picker.saving.contains(option.playlistId)
        return MusicNativeMenuItem(title: option.title, leading: {
            if option.containsVideo {
                MusicNativeMenuCheck()
            } else if isSaving {
                MusicSpinner(size: 10, lineWidth: 1.5, color: .white.opacity(0.75))
            }
        }) {
            store.choose(option)
        }
        .accessibilityValue(option.containsVideo ? "Has this song" : isSaving ? "Saving" : "")
        .accessibilityAddTraits(option.containsVideo ? .isSelected : [])
    }

    /// The pointer in the layer's own coordinates, or nil when it is not over the layer (the menu was opened from the
    /// chip's card, outside the popup). `frame` is the layer in its window, top left origin.
    @MainActor
    private static func pointer(in frame: CGRect) -> CGPoint? {
        guard let window = NSApp.windows.first(where: { $0.isVisible && MenuBarStatusItems.itemID(of: $0) == .music }),
              let content = window.contentView else { return nil }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = CGPoint(x: inWindow.x - frame.minX, y: content.bounds.height - inWindow.y - frame.minY)
        guard point.x >= 0, point.y >= 0, point.x <= frame.width, point.y <= frame.height else { return nil }
        return point
    }
}
