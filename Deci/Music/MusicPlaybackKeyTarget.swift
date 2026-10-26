// Deci/Music/MusicPlaybackKeyTarget.swift
import Foundation

/// Deci's music player as the play/pause, next and previous keys see it. It never builds the service: before the Music
/// popup was first opened nothing is loaded, so the keys find nothing to do.
@MainActor
final class MusicPlaybackKeyTarget: PlaybackKeyDeciControlling {
    private let musicHost: MusicServiceHost

    init(musicHost: MusicServiceHost) {
        self.musicHost = musicHost
    }

    /// Playing is the player being active: playing, loading a song, or wanting to play through a stall. A song that is
    /// loading counts, so a second Next while the first is still resolving skips again instead of finding Deci idle. A
    /// loaded song that is not active, paused or ended, reads as paused.
    var playbackState: DeciPlaybackState {
        guard let player = musicHost.service?.player, player.nowPlaying != nil else { return .idle }
        return player.isActive ? .playing : .pausedWithSong
    }

    /// Through the same calls the Now Playing remote commands make.
    func perform(_ action: DeciPlaybackAction) {
        guard let service = musicHost.service else { return }
        switch action {
        case .pause: service.handleRemote(.pause)
        case .resume: service.handleRemote(.play)
        case .next: service.handleRemote(.next)
        case .previous: service.handleRemote(.previous)
        }
    }
}
