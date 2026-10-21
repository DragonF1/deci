// Deci/Music/MusicTrackActionsStore.swift
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicTrackActions")

/// The state behind a song's or a tile's "..." menu: the save to playlist menu and the short line that says what
/// happened. `MusicService` owns one (`service.trackActions`). The state lives here, not in the views, because the popover
/// panel hides whenever it loses focus. Nothing here logs a playlist or song, only counts and error kinds.
@MainActor
@Observable
final class MusicTrackActionsStore {
    /// The save to playlist menu: what is being saved and the playlists it can go to. It stays open while the user
    /// adds it to one playlist after another.
    struct Picker: Equatable {
        /// A song, or a whole album or playlist with the id of the playlist its songs are added from.
        enum Target: Equatable {
            case track(MusicTrack)
            case collection(MusicCollection, sourceId: String)

            /// Names what is saved, for the saves out and the busy keys. A song and a playlist never share one.
            var key: String {
                switch self {
                case .track(let track): "track:" + track.videoId
                case .collection(_, let sourceId): "list:" + sourceId
                }
            }
        }

        let target: Target
        var load: MusicBrowseStore.Load<[MusicPlaylistOption]>
        /// Playlists a save is out for; their rows show it and ignore taps until it answers.
        var saving: Set<String> = []

        /// The song being saved; nil when it is a whole album or playlist.
        var track: MusicTrack? {
            if case .track(let track) = target { track } else { nil }
        }

        /// The album or playlist being saved; nil when it is a song.
        var collection: MusicCollection? {
            if case .collection(let collection, _) = target { collection } else { nil }
        }

        /// The name of what is being saved.
        var title: String {
            switch target {
            case .track(let track): track.title
            case .collection(let collection, _): collection.title
            }
        }
    }

    /// A short line under the list: what was done, or why it was not.
    struct Notice: Equatable {
        let id: Int
        let text: String
        let isError: Bool
    }

    private(set) var picker: Picker?
    private(set) var notice: Notice?

    @ObservationIgnored private let backend: any MusicBackend
    @ObservationIgnored private let browse: MusicBrowseStore
    @ObservationIgnored private let noticeDuration: Duration
    /// Names the current picker; an answer for an older one is dropped.
    @ObservationIgnored private var pickerRun = 0
    /// Bumped by `reset`: a write that was out when the session ended must not touch the next one.
    @ObservationIgnored private var sessionRun = 0
    @ObservationIgnored private var noticeCounter = 0
    @ObservationIgnored private var pickerTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Writes in flight, so a second tap on the same thing sends nothing more.
    @ObservationIgnored private var busy: Set<String> = []
    /// The playlists a save is out for, by what is saved (`Picker.Target.key`), so a menu opened again for it shows them saving.
    @ObservationIgnored private var savesOut: [String: Set<String>] = [:]
    /// Told when a call says the session is gone, so the service can sign out.
    @ObservationIgnored var onSessionExpired: (@MainActor () -> Void)?

    /// How long a line says what an action did: about 2 s, as the design has it.
    static let defaultNoticeDuration: Duration = .seconds(2)

    init(backend: any MusicBackend, browse: MusicBrowseStore, noticeDuration: Duration = defaultNoticeDuration) {
        self.backend = backend
        self.browse = browse
        self.noticeDuration = noticeDuration
    }

    // MARK: - Save to playlist

    /// Opens the picker for a song and loads its playlists. Opening it again retries a failed list.
    func openPicker(for track: MusicTrack) {
        open(.track(track))
    }

    /// Opens the picker for a whole album or playlist and loads the playlists it can go to. Does nothing for a tile
    /// with no playlist to add from (`MusicTrackActions.playlistSourceId`).
    func openPicker(for collection: MusicCollection) {
        guard let sourceId = MusicTrackActions.playlistSourceId(for: collection) else { return }
        open(.collection(collection, sourceId: sourceId))
    }

    /// The menu's Try again: loads the open picker's list again.
    func retryPicker() {
        guard let target = picker?.target else { return }
        open(target)
    }

    private func open(_ target: Picker.Target) {
        pickerRun += 1
        let run = pickerRun
        picker = Picker(target: target, load: .loading, saving: savesOut[target.key] ?? [])
        pickerTask?.cancel()
        pickerTask = Task { [weak self, backend] in
            do {
                let options: [MusicPlaylistOption]
                switch target {
                case .track(let track):
                    options = try await backend.addToPlaylistOptions(videoId: track.videoId)
                case .collection(_, let sourceId):
                    options = try await backend.addToPlaylistOptions(sourcePlaylistId: sourceId)
                }
                self?.landOptions(options, run: run)
            } catch {
                self?.failOptions(error, run: run)
            }
        }
    }

    func closePicker() {
        pickerRun += 1
        pickerTask?.cancel()
        picker = nil
    }

    /// A playlist was tapped. One that already holds the song (or all of the album or playlist) says so without a
    /// call. Otherwise it is added and the line says it saved; the menu stays open, the row ticked, so it can go to
    /// another playlist too. Saves to different playlists can be out at once. A failure leaves the row unticked for
    /// another try.
    func choose(_ option: MusicPlaylistOption) {
        guard let current = picker, case .loaded(let options) = current.load,
              !current.saving.contains(option.playlistId) else { return }
        // The list's own row, which a save since may have ticked, over the copy the tap carried.
        let option = options.first { $0.playlistId == option.playlistId } ?? option
        if option.containsVideo {
            post("Already in \(option.title)")
            return
        }
        let target = current.target
        let key = busyKey("save:\(option.playlistId):\(target.key)")
        guard busy.insert(key).inserted else { return }
        savesOut[target.key, default: []].insert(option.playlistId)
        picker?.saving.insert(option.playlistId)
        let session = sessionRun
        Task { [weak self, backend] in
            do {
                switch target {
                case .track(let track):
                    try await backend.addToPlaylist(videoId: track.videoId, playlistId: option.playlistId)
                case .collection(_, let sourceId):
                    try await backend.addPlaylistToPlaylist(sourceId: sourceId, playlistId: option.playlistId)
                }
                self?.landSave(option, targetKey: target.key, key: key, session: session)
            } catch {
                self?.failSave(error, option: option, targetKey: target.key, key: key, session: session)
            }
        }
    }

    private func landOptions(_ options: [MusicPlaylistOption], run: Int) {
        guard pickerRun == run, picker != nil else { return }
        logger.info("picker loaded \(options.count) playlists")
        picker?.load = .loaded(options)
    }

    private func failOptions(_ error: any Error, run: Int) {
        guard pickerRun == run, picker != nil else { return }
        logger.error("picker failed: \(MusicService.logDescription(of: error), privacy: .public)")
        picker?.load = .failed(MusicService.message(for: error))
        expireIfSignedOut(error)
    }

    /// Ticks the row in whichever menu is open for what was saved, the one the tap came from or one opened again since.
    private func landSave(_ option: MusicPlaylistOption, targetKey: String, key: String, session: Int) {
        busy.remove(key)
        guard sessionRun == session else { return }
        endSave(option.playlistId, targetKey: targetKey)
        if var current = picker, current.target.key == targetKey {
            current.saving.remove(option.playlistId)
            if case .loaded(var options) = current.load,
               let index = options.firstIndex(where: { $0.playlistId == option.playlistId }) {
                let row = options[index]
                options[index] = MusicPlaylistOption(
                    playlistId: row.playlistId, title: row.title, thumbnailURL: row.thumbnailURL, containsVideo: true)
                current.load = .loaded(options)
            }
            picker = current
        }
        post("Saved to \(option.title)")
    }

    /// YouTube refuses an add the playlist already holds (no dedupe option is sent), so a refusal most likely means
    /// the list was out of date and it is already there.
    private func failSave(
        _ error: any Error, option: MusicPlaylistOption, targetKey: String, key: String, session: Int
    ) {
        busy.remove(key)
        guard sessionRun == session else { return }
        logger.error("save failed: \(MusicService.logDescription(of: error), privacy: .public)")
        endSave(option.playlistId, targetKey: targetKey)
        if picker?.target.key == targetKey { picker?.saving.remove(option.playlistId) }
        guard !expireIfSignedOut(error) else { return }
        if (error as? MusicError) == .rejected {
            post("Not added. \(option.title) may already have it.", isError: true)
        } else {
            post(MusicService.message(for: error), isError: true)
        }
    }

    private func endSave(_ playlistId: String, targetKey: String) {
        savesOut[targetKey]?.remove(playlistId)
        if savesOut[targetKey]?.isEmpty == true { savesOut[targetKey] = nil }
    }

    // MARK: - Remove from playlist

    /// Takes the row out of the playlist on YouTube, and then off the page. Does nothing where the rules do not
    /// offer it (a page the user cannot edit, Liked Music, a row with no place in the playlist).
    func remove(_ track: MusicTrack, in context: MusicTrackContext) {
        guard MusicTrackActions.available(for: track, in: context).contains(.removeFromPlaylist),
              let setVideoId = track.playlistSetVideoId, let pageId = context.pageBrowseId else { return }
        let key = busyKey("remove:\(pageId):\(setVideoId)")
        guard busy.insert(key).inserted else { return }
        let session = sessionRun
        let videoId = track.videoId
        let name = Self.playlistName(context.pageTitle)
        Task { [weak self, backend] in
            do {
                try await backend.removeFromPlaylist(videoId: videoId, setVideoId: setVideoId, playlistId: pageId)
                self?.landRemoval(key: key, setVideoId: setVideoId, pageId: pageId, name: name, session: session)
            } catch {
                self?.failWrite(error, key: key, session: session)
            }
        }
    }

    private func landRemoval(key: String, setVideoId: String, pageId: String, name: String, session: Int) {
        busy.remove(key)
        guard sessionRun == session else { return }
        browse.removeTrack(setVideoId: setVideoId, from: pageId)
        post("Removed from \(name)")
    }

    private static func playlistName(_ title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "playlist" : trimmed
    }

    // MARK: - Shared

    /// A busy key carries its session: an older session's call that lands after `reset` frees only its own key,
    /// never the same write started in the new session.
    private func busyKey(_ base: String) -> String {
        "\(sessionRun)|\(base)"
    }

    /// A write that failed: the session going away signs out, anything else shows its line and leaves the page as it was.
    private func failWrite(_ error: any Error, key: String, session: Int) {
        busy.remove(key)
        guard sessionRun == session else { return }
        logger.error("write failed: \(MusicService.logDescription(of: error), privacy: .public)")
        if !expireIfSignedOut(error) { post(MusicService.message(for: error), isError: true) }
    }

    /// Tells the service when the session is gone; says whether it was.
    @discardableResult
    private func expireIfSignedOut(_ error: any Error) -> Bool {
        guard (error as? MusicError) == .signedOut else { return false }
        onSessionExpired?()
        return true
    }

    // MARK: - Notice

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    /// Shows a line that clears itself. A newer line is never cleared by an older line's timer.
    func post(_ text: String, isError: Bool = false) {
        noticeCounter += 1
        let id = noticeCounter
        notice = Notice(id: id, text: text, isError: isError)
        noticeTask?.cancel()
        noticeTask = Task { [weak self, noticeDuration] in
            try? await Task.sleep(for: noticeDuration)
            guard !Task.isCancelled else { return }
            self?.expireNotice(id)
        }
    }

    private func expireNotice(_ id: Int) {
        if notice?.id == id { notice = nil }
    }

    // MARK: - Reset

    /// Drops everything: on sign-out and after an account or channel switch. A call still out lands nowhere.
    func reset() {
        sessionRun += 1
        pickerRun += 1
        pickerTask?.cancel()
        noticeTask?.cancel()
        picker = nil
        notice = nil
        busy.removeAll()
        savesOut.removeAll()
    }
}
