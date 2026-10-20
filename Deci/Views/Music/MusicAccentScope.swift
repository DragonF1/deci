// Deci/Views/Music/MusicAccentScope.swift
import SwiftUI

private struct MusicAccentKey: EnvironmentKey {
    static let defaultValue = MusicAccent.fallback
}

extension EnvironmentValues {
    /// The colour of the song on the player column: taken from its cover, lifted so it reads on the near black. The
    /// player column, the header's tab underline and everything that lights up with the song read it from here.
    var musicAccent: MusicTint {
        get { self[MusicAccentKey.self] }
        set { self[MusicAccentKey.self] = newValue }
    }
}

extension View {
    /// Provides `musicAccent` for the song `track`: its cover's colour once it is known (at once from the cache),
    /// else the hash palette's tint of its id. The previous song's colour stays until the new one is known, so the
    /// accent moves once. Views that draw it animate their own change.
    func musicAccentScope(track: MusicTrack?) -> some View {
        modifier(MusicAccentScope(track: track))
    }
}

private struct MusicAccentScope: ViewModifier {
    let track: MusicTrack?

    /// The cover's colour once it is known.
    @State private var coverTint: MusicTint?

    init(track: MusicTrack?) {
        self.track = track
        _coverTint = State(initialValue: MusicCoverTintStore.shared.cachedTint(for: track?.thumbnailURL))
    }

    private var accent: MusicTint {
        MusicAccent.accent(cover: track == nil ? nil : coverTint, videoId: track?.videoId)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.musicAccent, accent)
            .task(id: track?.thumbnailURL) { await loadTint(for: track?.thumbnailURL) }
    }

    private func loadTint(for url: URL?) async {
        guard let url else {
            coverTint = nil
            return
        }
        if let cached = MusicCoverTintStore.shared.cachedTint(for: url) {
            coverTint = cached
            return
        }
        let tint = await MusicCoverTintStore.shared.tint(for: url)
        guard !Task.isCancelled else { return }
        coverTint = tint
    }
}
