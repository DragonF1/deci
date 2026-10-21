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

/// What a row of the save to playlist menu says besides its title, in words a test can check. A tick means two things:
/// in a song's menu a click on it takes the song out of that playlist, in an album's or playlist's menu it only says
/// the playlist has it already.
nonisolated enum MusicSaveMenuRowWords {
    /// The hover help and VoiceOver hint of a row: a ticked row of a song's menu says it removes. Any other row has
    /// none, since its title already says where a click goes.
    static func help(title: String, isTicked: Bool, isSong: Bool) -> String? {
        isTicked && isSong ? "Remove from \(title)" : nil
    }

    /// What VoiceOver hears as the row's value. A busy row is Removing when the song is being taken out of that
    /// playlist and Saving for any other write, so a ticked row can still be Saving: a save went out and a late read
    /// of the playlist ticked the row before the save answered. A row that is not busy says what its tick says, or
    /// nothing.
    static func state(isTicked: Bool, isBusy: Bool, isRemoving: Bool, tickedText: String) -> String {
        if isBusy { return isRemoving ? "Removing" : "Saving" }
        return isTicked ? tickedText : ""
    }
}

/// The save to playlist menu, over the whole popup like the account card. It wears the native menu look: the playlists
/// a song, album or playlist can go to, a check on those that hold it. A click adds it and ticks the row; the menu stays
/// open so it can go to another playlist too. A click on a ticked row of a song's menu takes the song out of that
/// playlist again and unticks the row. A click outside or Escape closes it. There is no New playlist item: the
/// app cannot make one.
struct MusicSaveMenuLayer: View {
    let store: MusicTrackActionsStore
    let picker: MusicTrackActionsStore.Picker
    let onClose: () -> Void

    static let width: CGFloat = 230
    /// The list scrolls past this many rows.
    static let visibleRows = 12

    /// The pointer when the menu opened, in the layer; nil opens it centred.
    @State private var anchor: CGPoint?
    /// The pointer has been read, so the first frame never shows the menu centred and then jumping to it.
    @State private var placed = false

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
                    .opacity(placed ? 1 : 0)
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .onAppear {
                anchor = Self.pointer(in: geometry.frame(in: .global))
                placed = true
            }
            // Opened again for another song or tile while open (the chip's card): it moves to the new pointer.
            .onChange(of: picker.target.key) { anchor = Self.pointer(in: geometry.frame(in: .global)) }
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
                MusicNativeMenuItem(title: "Try again") { store.retryPicker() }
            case .loaded(let options) where options.isEmpty:
                MusicNativeMenuItem(title: "No playlists you can add to", isEnabled: false) {}
            case .loaded(let options):
                list(options)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Save \(picker.title) to playlist")
    }

    /// What a ticked row says to VoiceOver: the playlist holds what is being saved.
    private var hasText: String {
        switch picker.collection?.kind {
        case nil: "Has this song"
        case .album: "Has this album"
        case .playlist, .artist: "Has this playlist"
        }
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
        let isRemoving = picker.removing.contains(option.playlistId)
        let help = MusicSaveMenuRowWords.help(title: option.title, isTicked: option.containsVideo, isSong: picker.track != nil)
        return MusicNativeMenuItem(title: option.title, leading: {
            if isSaving {
                MusicSpinner(size: 10, lineWidth: 1.5, color: .white.opacity(0.75))
            } else if option.containsVideo {
                MusicNativeMenuCheck()
            }
        }) {
            store.choose(option)
        }
        .help(help ?? "")
        .accessibilityHint(help ?? "")
        .accessibilityValue(MusicSaveMenuRowWords.state(
            isTicked: option.containsVideo, isBusy: isSaving, isRemoving: isRemoving, tickedText: hasText
        ))
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
