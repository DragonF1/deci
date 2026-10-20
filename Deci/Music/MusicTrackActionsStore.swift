// Deci/Music/MusicTrackActionsStore.swift
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicTrackActions")

/// The state behind a song's "..." menu: the save to playlist menu, the short line that says what happened, and
/// which songs, playlists and albums the user pinned to Listen again. `MusicService` owns one (`service.trackActions`). The state lives
/// here, not in the views, because the popover panel hides whenever it loses focus. Nothing here logs a playlist,
/// song or token, only counts and error kinds.
@MainActor
@Observable
final class MusicTrackActionsStore {
    /// The save to playlist menu: the song being saved and the playlists it can go to. It stays open while the user
    /// adds the song to one playlist after another.
    struct Picker: Equatable {
        let track: MusicTrack
        var load: MusicBrowseStore.Load<[MusicPlaylistOption]>
        /// Playlists a save is out for; their rows show it and ignore taps until it answers.
        var saving: Set<String> = []
    }

    /// A short line under the list: what was done, or why it was not.
    struct Notice: Equatable {
        let id: Int
        let text: String
        let isError: Bool
    }

    private(set) var picker: Picker?
    private(set) var notice: Notice?
    /// A pin or unpin made this session, over what the row said when it loaded.
    struct PinOverride: Equatable {
        /// The row's own toggle when it was flipped. A row loaded since (new state or new tokens) shows its own.
        let source: MusicFeedbackToggle
        let toggle: MusicFeedbackToggle
    }

    /// Keyed by song ("t:" + video id) or by playlist or album ("c:" + browse id): every row of the same thing, from
    /// the same load, shows the same Pin / Unpin.
    private var pins: [String: PinOverride] = [:]

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
    /// The playlists a save is out for, by song, so a menu opened again for that song shows them saving.
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

    // MARK: - What a song offers

    /// The model's list for this song, with Pin / Unpin facing the way it was last left this session. `home` is the
    /// song's Pin to Home state, which the Pinned items hold and this store does not.
    func actions(for track: MusicTrack, in context: MusicTrackContext, home: MusicHomePinState? = nil) -> [MusicTrackAction] {
        MusicTrackActions.available(for: withPinState(track), in: context, home: home)
    }

    /// Only a song YouTube offered the toggle for has one; another row's pin never gives one to a row that has none.
    private func withPinState(_ track: MusicTrack) -> MusicTrack {
        guard track.listenAgainPin != nil else { return track }
        var pinned = track
        pinned.listenAgainPin = pinState(track.listenAgainPin, key: Self.pinKey(track))
        return pinned
    }

    /// A playlist or album tile or row's Pin / Unpin, facing the way it was last left this session. Nil when YouTube
    /// offers no toggle for it, or none for its next move.
    func listenAgainPin(for collection: MusicCollection) -> MusicFeedbackToggle? {
        Self.offered(pinState(collection.listenAgainPin, key: Self.pinKey(collection.browseId)))
    }

    /// The same for an open playlist or album page, from its header menu.
    func listenAgainPin(for page: MusicBrowsePage) -> MusicFeedbackToggle? {
        Self.offered(pinState(page.listenAgainPin, key: Self.pinKey(page.browseId)))
    }

    /// Whether the song is pinned to Listen again, as last left this session. It reads the toggle itself, not
    /// `actions(for:in:)`, so a pinned song YouTube gives no unpin token for still counts. False for a row with no toggle.
    func isPinnedToListenAgain(_ track: MusicTrack) -> Bool {
        pinState(track.listenAgainPin, key: Self.pinKey(track))?.isPinned == true
    }

    /// The same for a playlist or album tile or row.
    func isPinnedToListenAgain(_ collection: MusicCollection) -> Bool {
        pinState(collection.listenAgainPin, key: Self.pinKey(collection.browseId))?.isPinned == true
    }

    /// The same for an open playlist or album page.
    func isPinnedToListenAgain(_ page: MusicBrowsePage) -> Bool {
        pinState(page.listenAgainPin, key: Self.pinKey(page.browseId))?.isPinned == true
    }

    /// The toggle as last left: an override from this session only while the row still carries the toggle that was
    /// flipped. A row loaded since (new state or new tokens) shows its own.
    private func pinState(_ own: MusicFeedbackToggle?, key: String) -> MusicFeedbackToggle? {
        guard let own else { return nil }
        guard let override = pins[key], override.source == own else { return own }
        return override.toggle
    }

    private static func offered(_ toggle: MusicFeedbackToggle?) -> MusicFeedbackToggle? {
        toggle?.nextToken?.isEmpty == false ? toggle : nil
    }

    private static func pinKey(_ track: MusicTrack) -> String { "t:" + track.videoId }
    private static func pinKey(_ browseId: String) -> String { "c:" + browseId }

    // MARK: - Save to playlist

    /// Opens the picker for a song and loads its playlists. Opening it again retries a failed list.
    func openPicker(for track: MusicTrack) {
        pickerRun += 1
        let run = pickerRun
        picker = Picker(track: track, load: .loading, saving: savesOut[track.videoId] ?? [])
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

    /// A playlist was tapped. One that already holds the song says so without a call. Otherwise the song is added and
    /// the line says it saved; the menu stays open, the row ticked, so the song can go to another playlist too. Saves
    /// to different playlists can be out at once. A failure leaves the row unticked for another try.
    func choose(_ option: MusicPlaylistOption) {
        guard let current = picker, case .loaded(let options) = current.load,
              !current.saving.contains(option.playlistId) else { return }
        // The list's own row, which a save since may have ticked, over the copy the tap carried.
        let option = options.first { $0.playlistId == option.playlistId } ?? option
        if option.containsVideo {
            post("Already in \(option.title)")
            return
        }
        let videoId = current.track.videoId
        let key = busyKey("save:\(option.playlistId):\(videoId)")
        guard busy.insert(key).inserted else { return }
        savesOut[videoId, default: []].insert(option.playlistId)
        picker?.saving.insert(option.playlistId)
        let session = sessionRun
        Task { [weak self, backend] in
            do {
                try await backend.addToPlaylist(videoId: videoId, playlistId: option.playlistId)
                self?.landSave(option, videoId: videoId, key: key, session: session)
            } catch {
                self?.failSave(error, option: option, videoId: videoId, key: key, session: session)
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

    /// Ticks the row in whichever menu is open for the song, the one the tap came from or one opened again since.
    private func landSave(_ option: MusicPlaylistOption, videoId: String, key: String, session: Int) {
        busy.remove(key)
        guard sessionRun == session else { return }
        endSave(option.playlistId, videoId: videoId)
        if var current = picker, current.track.videoId == videoId {
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
        _ error: any Error, option: MusicPlaylistOption, videoId: String, key: String, session: Int
    ) {
        busy.remove(key)
        guard sessionRun == session else { return }
        logger.error("save failed: \(MusicService.logDescription(of: error), privacy: .public)")
        endSave(option.playlistId, videoId: videoId)
        if picker?.track.videoId == videoId { picker?.saving.remove(option.playlistId) }
        guard !expireIfSignedOut(error) else { return }
        if (error as? MusicError) == .rejected {
            post("Not added. \(option.title) may already have it.", isError: true)
        } else {
            post(MusicService.message(for: error), isError: true)
        }
    }

    private func endSave(_ playlistId: String, videoId: String) {
        savesOut[videoId]?.remove(playlistId)
        if savesOut[videoId]?.isEmpty == true { savesOut[videoId] = nil }
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

    // MARK: - Pin to Listen again

    /// Pins the song to Listen again, or unpins it, whichever the row offers. The row flips to the other word only
    /// once YouTube says it worked.
    func togglePin(_ track: MusicTrack) {
        togglePin(source: track.listenAgainPin, pinKey: Self.pinKey(track))
    }

    /// The same for a playlist or album tile or row.
    func togglePin(_ collection: MusicCollection) {
        togglePin(source: collection.listenAgainPin, pinKey: Self.pinKey(collection.browseId))
    }

    /// The same for an open playlist or album page.
    func togglePin(_ page: MusicBrowsePage) {
        togglePin(source: page.listenAgainPin, pinKey: Self.pinKey(page.browseId))
    }

    private func togglePin(source: MusicFeedbackToggle?, pinKey: String) {
        guard let source, let toggle = pinState(source, key: pinKey), let token = toggle.nextToken, !token.isEmpty else { return }
        let key = busyKey("pin:\(pinKey)")
        guard busy.insert(key).inserted else { return }
        let session = sessionRun
        Task { [weak self, backend] in
            do {
                try await backend.sendFeedback(token: token)
                self?.landPin(PinOverride(source: source, toggle: toggle.flipped()), pinKey: pinKey, key: key, session: session)
            } catch {
                self?.failWrite(error, key: key, session: session)
            }
        }
    }

    private func landPin(_ override: PinOverride, pinKey: String, key: String, session: Int) {
        busy.remove(key)
        guard sessionRun == session else { return }
        pins[pinKey] = override
        post(override.toggle.isPinned ? "Pinned to Listen again" : "Unpinned from Listen again")
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
        savesOut.removeAll()
    }
}
