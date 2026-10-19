// Deci/Music/MusicTrackActionsStore.swift
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicTrackActions")

/// The state behind a song's "..." menu: the add-to-playlist picker, the short line that says what happened, and
/// which songs the user pinned to Listen again. `MusicService` owns one (`service.trackActions`). The state lives
/// here, not in the views, because the popover panel hides whenever it loses focus. Nothing here logs a playlist,
/// song or token, only counts and error kinds.
@MainActor
@Observable
final class MusicTrackActionsStore {
    /// The picker panel: the song being saved and the playlists it can go to.
    struct Picker: Equatable {
        let track: MusicTrack
        var load: MusicBrowseStore.Load<[MusicPlaylistOption]>
        /// A save is out; the list ignores taps until it answers.
        var isSaving = false
    }

    /// A short line under the list: what was done, or why it was not.
    struct Notice: Equatable {
        let id: Int
        let text: String
        let isError: Bool
    }

    private(set) var picker: Picker?
    private(set) var notice: Notice?
    /// The pin state of songs pinned or unpinned this session, over what the row said when it loaded. Keyed by song:
    /// every row of the same song shows the same Pin / Unpin.
    private var pins: [String: MusicFeedbackToggle] = [:]

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
    /// Told when a call says the session is gone, so the service can sign out.
    @ObservationIgnored var onSessionExpired: (@MainActor () -> Void)?

    init(backend: any MusicBackend, browse: MusicBrowseStore, noticeDuration: Duration = .seconds(3)) {
        self.backend = backend
        self.browse = browse
        self.noticeDuration = noticeDuration
    }

    // MARK: - What a song offers

    /// The model's list for this song, with Pin / Unpin facing the way it was last left this session.
    func actions(for track: MusicTrack, in context: MusicTrackContext) -> [MusicTrackAction] {
        MusicTrackActions.available(for: withPinState(track), in: context)
    }

    /// Only a song YouTube offered the toggle for has one; another row's pin never gives one to a row that has none.
    private func withPinState(_ track: MusicTrack) -> MusicTrack {
        guard track.listenAgainPin != nil, let toggle = pins[track.videoId] else { return track }
        var pinned = track
        pinned.listenAgainPin = toggle
        return pinned
    }

    // MARK: - Save to playlist

    /// Opens the picker for a song and loads its playlists. Opening it again retries a failed list.
    func openPicker(for track: MusicTrack) {
        pickerRun += 1
        let run = pickerRun
        picker = Picker(track: track, load: .loading)
        pickerTask?.cancel()
        let videoId = track.videoId
        pickerTask = Task { [weak self, backend] in
            do {
                let options = try await backend.addToPlaylistOptions(videoId: videoId)
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

    /// A playlist was tapped. One that already holds the song says so without a call. Otherwise the song is added,
    /// the picker closes and the line says it saved; a failure keeps the picker open for another try.
    func choose(_ option: MusicPlaylistOption) {
        guard let current = picker, case .loaded = current.load, !current.isSaving else { return }
        if option.containsVideo {
            closePicker()
            post("Already in \(option.title)")
            return
        }
        picker?.isSaving = true
        let run = pickerRun, session = sessionRun
        let videoId = current.track.videoId
        Task { [weak self, backend] in
            do {
                try await backend.addToPlaylist(videoId: videoId, playlistId: option.playlistId)
                self?.landSave(option, run: run, session: session)
            } catch {
                self?.failSave(error, run: run, session: session)
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

    private func landSave(_ option: MusicPlaylistOption, run: Int, session: Int) {
        guard sessionRun == session else { return }
        if pickerRun == run { closePicker() }
        post("Saved to \(option.title)")
    }

    private func failSave(_ error: any Error, run: Int, session: Int) {
        guard sessionRun == session else { return }
        logger.error("save failed: \(MusicService.logDescription(of: error), privacy: .public)")
        if pickerRun == run { picker?.isSaving = false }
        if !expireIfSignedOut(error) { post(MusicService.message(for: error), isError: true) }
    }

    // MARK: - Remove from playlist

    /// Takes the row out of the playlist on YouTube, and then off the page. Does nothing where the rules do not
    /// offer it (a page the user cannot edit, Liked Music, a row with no place in the playlist).
    func remove(_ track: MusicTrack, in context: MusicTrackContext) {
        guard MusicTrackActions.available(for: track, in: context).contains(.removeFromPlaylist),
              let setVideoId = track.playlistSetVideoId, let pageId = context.pageBrowseId else { return }
        let key = "remove:\(pageId):\(setVideoId)"
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

    // MARK: - Pin to Listen again

    /// Pins the song to Listen again, or unpins it, whichever the row offers. The row flips to the other word only
    /// once YouTube says it worked.
    func togglePin(_ track: MusicTrack) {
        let track = withPinState(track)
        guard let toggle = track.listenAgainPin, let token = toggle.nextToken, !token.isEmpty else { return }
        let key = "pin:\(track.videoId)"
        guard busy.insert(key).inserted else { return }
        let session = sessionRun
        let videoId = track.videoId
        Task { [weak self, backend] in
            do {
                try await backend.sendFeedback(token: token)
                self?.landPin(toggle.flipped(), videoId: videoId, key: key, session: session)
            } catch {
                self?.failWrite(error, key: key, session: session)
            }
        }
    }

    private func landPin(_ toggle: MusicFeedbackToggle, videoId: String, key: String, session: Int) {
        busy.remove(key)
        guard sessionRun == session else { return }
        pins[videoId] = toggle
        post(toggle.isPinned ? "Pinned to Listen again" : "Unpinned from Listen again")
    }

    // MARK: - Shared

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
    private func post(_ text: String, isError: Bool = false) {
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
        pins.removeAll()
        busy.removeAll()
    }
}
