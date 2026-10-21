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
    /// Reads which of the open picker's playlists already hold what is saved (`startMembershipPass`).
    @ObservationIgnored private var membershipTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Writes in flight, so a second tap on the same thing sends nothing more.
    @ObservationIgnored private var busy: Set<String> = []
    /// The playlists a save is out for, by what is saved (`Picker.Target.key`), so a menu opened again for it shows them saving.
    @ObservationIgnored private var savesOut: [String: Set<String>] = [:]
    /// Told when a call says the session is gone, so the service can sign out.
    @ObservationIgnored var onSessionExpired: (@MainActor () -> Void)?

    /// How long a line says what an action did: about 2 s, as the design has it.
    static let defaultNoticeDuration: Duration = .seconds(2)

    /// How many pages of one playlist are read to look for the songs being saved. The first page counts as page one.
    nonisolated static let membershipPageLimit = 20
    /// How many playlists are read at once.
    nonisolated static let membershipConcurrency = 4

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
        membershipTask?.cancel()
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
        membershipTask?.cancel()
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
        if let target = picker?.target { startMembershipPass(options, target: target, run: run) }
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
                options[index] = Self.ticked(options[index])
                current.load = .loaded(options)
            }
            picker = current
        }
        post("Saved to \(option.title)")
    }

    /// The row with its tick on. `MusicPlaylistOption` is a let-struct, so it is rebuilt.
    private static func ticked(_ row: MusicPlaylistOption) -> MusicPlaylistOption {
        MusicPlaylistOption(playlistId: row.playlistId, title: row.title, thumbnailURL: row.thumbnailURL, containsVideo: true)
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

    // MARK: - Which playlists hold it

    /// How a pass read one playlist against what is being saved.
    private enum Membership: Sendable {
        case holdsAll
        case lacksSome
        case failed(any Error)
        case cancelled
    }

    /// Why the pass gave up before reading any playlist, other than a failed read.
    private enum MembershipSkip: Error {
        case emptySource
        case sourceTooLong
    }

    /// YouTube Music does not say which playlists already hold the song (its answer has no such flag), so the store reads
    /// them itself. Each row not ticked yet has its playlist's songs read, `membershipConcurrency` playlists at a time,
    /// and is ticked the moment the playlist is found to hold all that is being saved. A row is never unticked here: a
    /// save may have ticked it meanwhile. A read that fails leaves its row as it was and shows nothing, and the others
    /// go on. Nothing in this pass signs the user out; a gone session shows on the next tap.
    private func startMembershipPass(_ options: [MusicPlaylistOption], target: Picker.Target, run: Int) {
        membershipTask?.cancel()
        var listed = Set<String>()
        let playlistIds = options.filter { !$0.containsVideo && listed.insert($0.playlistId).inserted }.map(\.playlistId)
        guard !playlistIds.isEmpty else {
            membershipTask = nil
            return
        }
        let key = target.key
        membershipTask = Task { [weak self, backend] in
            let wanted: Set<String>
            do {
                wanted = try await Self.songs(being: target, backend: backend)
            } catch {
                self?.skipMembership(because: error)
                return
            }
            var read = 0, held = 0, failed = 0
            await withTaskGroup(of: (String, Membership).self) { group in
                var next = 0, running = 0
                while !Task.isCancelled {
                    // A sliding window: as one playlist is done the next one starts.
                    while running < Self.membershipConcurrency, next < playlistIds.count {
                        let playlistId = playlistIds[next]
                        next += 1
                        guard self?.needsMembershipRead(playlistId, run: run, targetKey: key) == true else { continue }
                        running += 1
                        group.addTask { (playlistId, await Self.membership(ofPlaylist: playlistId, holding: wanted, backend: backend)) }
                    }
                    guard running > 0, let (playlistId, outcome) = await group.next() else { break }
                    running -= 1
                    read += 1
                    switch outcome {
                    case .holdsAll:
                        held += 1
                        self?.landMembership(playlistId, run: run, targetKey: key)
                    case .lacksSome, .cancelled:
                        break
                    case .failed(let error):
                        failed += 1
                        logger.error("membership read failed: \(MusicService.logDescription(of: error), privacy: .public)")
                    }
                }
                group.cancelAll()
            }
            guard !Task.isCancelled else { return }
            logger.info("membership read \(read) playlists: \(held) hold it, \(failed) failed")
        }
    }

    /// Whether a playlist still needs reading: the same picker is open and its row is not ticked, which a save can do
    /// while the pass is out.
    private func needsMembershipRead(_ playlistId: String, run: Int, targetKey: String) -> Bool {
        guard pickerRun == run, let current = picker, current.target.key == targetKey,
              case .loaded(let options) = current.load,
              let row = options.first(where: { $0.playlistId == playlistId }) else { return false }
        return !row.containsVideo
    }

    /// Ticks one row, in the picker the pass was started for. Never unticks, and leaves a row a save ticked alone.
    private func landMembership(_ playlistId: String, run: Int, targetKey: String) {
        guard pickerRun == run, var current = picker, current.target.key == targetKey,
              case .loaded(var options) = current.load,
              let index = options.firstIndex(where: { $0.playlistId == playlistId }),
              !options[index].containsVideo else { return }
        options[index] = Self.ticked(options[index])
        current.load = .loaded(options)
        picker = current
    }

    private func skipMembership(because error: any Error) {
        guard !Task.isCancelled else { return }
        let reason: String
        switch error {
        case MembershipSkip.emptySource: reason = "the source has no songs"
        case MembershipSkip.sourceTooLong: reason = "the source is longer than \(Self.membershipPageLimit) pages"
        default: reason = "reading the source failed: \(MusicService.logDescription(of: error))"
        }
        logger.error("membership skipped: \(reason, privacy: .public)")
    }

    /// The video ids of what is being saved: the song, or every song of the album or playlist it is copied from. A source
    /// that cannot be read, has no songs, or runs past the page limit gives no answer: ticking against part of an album
    /// would say a playlist holds all of it when it does not.
    nonisolated private static func songs(being target: Picker.Target, backend: any MusicBackend) async throws -> Set<String> {
        switch target {
        case .track(let track):
            return [track.videoId]
        case .collection(_, let sourceId):
            let source = try await videoIds(ofBrowseId: "VL" + sourceId, backend: backend, until: nil)
            if source.ids.isEmpty { throw MembershipSkip.emptySource }
            if !source.complete { throw MembershipSkip.sourceTooLong }
            return source.ids
        }
    }

    nonisolated private static func membership(
        ofPlaylist playlistId: String, holding wanted: Set<String>, backend: any MusicBackend
    ) async -> Membership {
        do {
            let read = try await videoIds(ofBrowseId: "VL" + playlistId, backend: backend, until: wanted)
            return wanted.isSubset(of: read.ids) ? .holdsAll : .lacksSome
        } catch {
            return Task.isCancelled ? .cancelled : .failed(error)
        }
    }

    /// The video ids on a playlist page and the pages behind it, at most `membershipPageLimit` pages. With `wanted` it
    /// stops as soon as all of them have been seen. `complete` is false when it stopped at the limit with pages left.
    nonisolated private static func videoIds(
        ofBrowseId browseId: String, backend: any MusicBackend, until wanted: Set<String>?
    ) async throws -> (ids: Set<String>, complete: Bool) {
        try Task.checkCancellation()
        let first = try await backend.page(browseId: browseId)
        var ids = Set(first.tracks.map(\.videoId))
        var token = first.continuation
        var pages = 1
        while true {
            if let wanted, wanted.isSubset(of: ids) { return (ids, true) }
            guard let current = token else { return (ids, true) }
            guard pages < membershipPageLimit else { return (ids, false) }
            try Task.checkCancellation()
            let more = try await backend.moreTracks(browseId: browseId, continuation: current)
            pages += 1
            ids.formUnion(more.tracks.map(\.videoId))
            token = more.continuation
        }
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

    /// Shows what a Like, Dislike or Save came to, in the words the hotkey HUD has for it. A refusal or a failed call
    /// shows as an error. A quiet outcome shows nothing and leaves a line that is up.
    func post(_ outcome: MusicActionOutcome) {
        guard let text = outcome.noticeText else { return }
        post(text, isError: outcome.isFailure)
    }

    /// Shows only an outcome that did not go through, since the button that made the call already shows one that did.
    func postIfFailed(_ outcome: MusicActionOutcome) {
        guard outcome.isRatingFailure else { return }
        post(outcome)
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
        membershipTask?.cancel()
        noticeTask?.cancel()
        picker = nil
        notice = nil
        busy.removeAll()
        savesOut.removeAll()
    }
}
