// Deci/Music/MusicTrackActionsStore.swift
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicTrackActions")

/// The state behind a song's or a tile's "..." menu: the save to playlist menu (which also takes a song back out of a
/// playlist that holds it) and the short line that says what happened. `MusicService` owns one
/// (`service.trackActions`). The state lives here, not in the views, because the popover panel hides whenever it loses
/// focus. Nothing here logs a playlist or song, only counts and error kinds.
@MainActor
@Observable
final class MusicTrackActionsStore {
    /// The save to playlist menu: what is being saved and the playlists it can go to. It stays open while the user
    /// adds it to one playlist after another, or takes a song out of the playlists that hold it.
    struct Picker: Equatable {
        /// A song, several songs picked together (two or more, each once, in list order), or a whole album or playlist
        /// with the id of the playlist its songs are added from.
        enum Target: Equatable {
            case track(MusicTrack)
            case tracks([MusicTrack])
            case collection(MusicCollection, sourceId: String)

            /// Names what is saved, for the saves out and the busy keys. A song, a pick of songs and a playlist never
            /// share one; the same picks always do.
            var key: String {
                switch self {
                case .track(let track): "track:" + track.videoId
                case .tracks(let tracks): "tracks:" + Self.fingerprint(of: tracks.map(\.videoId))
                case .collection(_, let sourceId): "list:" + sourceId
                }
            }

            /// A short stable name for a list of ids, in order (FNV-1a over the ids): a key of a 500 song pick stays short.
            nonisolated static func fingerprint(of ids: [String]) -> String {
                var hash: UInt64 = 0xcbf29ce484222325
                for id in ids {
                    for byte in id.utf8 {
                        hash ^= UInt64(byte)
                        hash = hash &* 0x100000001b3
                    }
                    hash ^= 0x0a
                    hash = hash &* 0x100000001b3
                }
                return String(hash, radix: 16)
            }
        }

        let target: Target
        /// The menu was opened from the selection bar or menu, so closing it after a write ends the selection.
        var fromSelection = false
        /// A write for what is saved landed while this menu was open, even a part of one.
        var wrote = false
        /// For a pick of songs: the picked songs each playlist is known to hold, which a row that is neither ticked nor
        /// empty (mixed) tells from the rest. A playlist that was not read, or whose read failed, has no entry: it is
        /// taken to hold none.
        var held: [String: Set<String>] = [:]
        var load: MusicBrowseStore.Load<[MusicPlaylistOption]>
        /// Playlists a write is out for, a save or a removal; their rows show it and ignore taps until it answers.
        var saving: Set<String> = []
        /// The playlists in `saving` that the song is being taken out of. The rest are being saved to, even a row that
        /// shows a tick: a late membership read can tick a row while a save to it is still out.
        var removing: Set<String> = []
        /// Playlists the song was taken out of in this menu. A membership read that began before the removal landed
        /// may still have seen the song there, and must not tick the row again.
        var removedFrom: Set<String> = []

        /// The song being saved; nil when it is a whole album or playlist.
        var track: MusicTrack? {
            if case .track(let track) = target { track } else { nil }
        }

        /// The album or playlist being saved; nil when it is a song.
        var collection: MusicCollection? {
            if case .collection(let collection, _) = target { collection } else { nil }
        }

        /// The songs being saved: one, the picked ones, or none for an album or playlist.
        var songs: [MusicTrack] {
            switch target {
            case .track(let track): [track]
            case .tracks(let tracks): tracks
            case .collection: []
            }
        }

        /// The name of what is being saved.
        var title: String {
            switch target {
            case .track(let track): track.title
            case .tracks(let tracks): "\(tracks.count) songs"
            case .collection(let collection, _): collection.title
            }
        }

        /// Whether the row holds some of the picked songs but not all: not ticked, not empty.
        func isMixed(_ option: MusicPlaylistOption) -> Bool {
            !option.containsVideo && !(held[option.playlistId]?.isEmpty ?? true)
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
    /// The playlists a save or a removal is out for, by what is saved (`Picker.Target.key`), so a menu opened again for
    /// it shows them saving.
    @ObservationIgnored private var savesOut: [String: Set<String>] = [:]
    /// The part of `savesOut` that is removals, so a menu opened again for a song says which rows are being removed
    /// from.
    @ObservationIgnored private var removalsOut: [String: Set<String>] = [:]
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

    /// Opens the picker for the songs picked in a list: each song once, in list order. One song is the song's own menu;
    /// two or more are saved together. Closing it after a write ends the selection (`closePicker`). Nothing opens for
    /// no songs.
    func openPicker(forSelection tracks: [MusicTrack]) {
        var seen = Set<String>()
        let songs = tracks.filter { !$0.videoId.isEmpty && seen.insert($0.videoId).inserted }
        switch songs.count {
        case 0: return
        case 1: open(.track(songs[0]), fromSelection: true)
        default: open(.tracks(songs), fromSelection: true)
        }
    }

    /// Opens the picker for a whole album or playlist and loads the playlists it can go to. Does nothing for a tile
    /// with no playlist to add from (`MusicTrackActions.playlistSourceId`).
    func openPicker(for collection: MusicCollection) {
        guard let sourceId = MusicTrackActions.playlistSourceId(for: collection) else { return }
        open(.collection(collection, sourceId: sourceId))
    }

    /// The menu's Try again: loads the open picker's list again.
    func retryPicker() {
        guard let current = picker else { return }
        open(current.target, fromSelection: current.fromSelection, wrote: current.wrote)
    }

    private func open(_ target: Picker.Target, fromSelection: Bool = false, wrote: Bool = false) {
        pickerRun += 1
        let run = pickerRun
        picker = Picker(
            target: target, fromSelection: fromSelection, wrote: wrote, load: .loading,
            saving: savesOut[target.key] ?? [], removing: removalsOut[target.key] ?? []
        )
        pickerTask?.cancel()
        membershipTask?.cancel()
        pickerTask = Task { [weak self, backend] in
            do {
                let options: [MusicPlaylistOption]
                switch target {
                case .track(let track):
                    options = try await backend.addToPlaylistOptions(videoId: track.videoId)
                case .tracks(let tracks):
                    // The list of playlists does not depend on the song, so the first one asks for all.
                    options = try await backend.addToPlaylistOptions(videoId: tracks.first?.videoId ?? "")
                case .collection(_, let sourceId):
                    options = try await backend.addToPlaylistOptions(sourcePlaylistId: sourceId)
                }
                self?.landOptions(options, run: run)
            } catch {
                self?.failOptions(error, run: run)
            }
        }
    }

    /// Closes the menu. Says whether it was a selection's menu and a write landed in it or is still out, so the caller
    /// ends the selection; a menu closed without one leaves the selection as it was.
    @discardableResult
    func closePicker() -> Bool {
        // A write still out is taken as landed: it lands after the menu is gone, and nothing would end the selection then.
        let wrote = picker.map { $0.fromSelection && ($0.wrote || !$0.saving.isEmpty) } ?? false
        pickerRun += 1
        pickerTask?.cancel()
        membershipTask?.cancel()
        picker = nil
        return wrote
    }

    /// A playlist was tapped. One that holds all of an album or playlist says so without a call. One that holds a
    /// song takes it out again (`removeSong`). Otherwise it is added and the line says it saved; the menu stays open,
    /// the row ticked, so it can go to another playlist too. Writes to different playlists can be out at once. A
    /// failed save leaves the row unticked for another try.
    func choose(_ option: MusicPlaylistOption) {
        guard let current = picker, case .loaded(let options) = current.load,
              !current.saving.contains(option.playlistId) else { return }
        // The list's own row, which a save since may have ticked, over the copy the tap carried.
        let option = options.first { $0.playlistId == option.playlistId } ?? option
        if case .tracks(let songs) = current.target {
            chooseSongs(songs, from: option, held: current.held[option.playlistId] ?? [])
            return
        }
        if option.containsVideo {
            if case .track(let track) = current.target {
                removeSong(track, from: option)
            } else {
                post("Already in \(option.title)")
            }
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
                case .tracks:
                    // Taken before, by `chooseSongs`.
                    return
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
        var options = options
        if case .tracks(_)? = picker?.target {
            // A flag on a row says whether the song the list was asked for is in, which says nothing of the others.
            options = options.map { $0.containsVideo ? Self.unticked($0) : $0 }
        }
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
            current.wrote = true
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

    /// The row with its tick off.
    private static func unticked(_ row: MusicPlaylistOption) -> MusicPlaylistOption {
        MusicPlaylistOption(playlistId: row.playlistId, title: row.title, thumbnailURL: row.thumbnailURL, containsVideo: false)
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
            post(Self.playlistWriteMessage(for: error), isError: true)
        }
    }

    private func endSave(_ playlistId: String, targetKey: String) {
        savesOut[targetKey]?.remove(playlistId)
        if savesOut[targetKey]?.isEmpty == true { savesOut[targetKey] = nil }
        removalsOut[targetKey]?.remove(playlistId)
        if removalsOut[targetKey]?.isEmpty == true { removalsOut[targetKey] = nil }
    }

    // MARK: - Take a song out of a playlist

    /// Why a removal found nothing to send: the playlist, read for the song's place in it, no longer holds the song.
    private enum RemovalMiss: Error {
        case notFound
    }

    /// A tap on a ticked row of a song's menu: that one playlist is read, to its end or the page limit, for the place
    /// of every row that holds the song (YouTube names a row of a playlist by its setVideoId, and the same song can sit
    /// in one playlist more than once), and the song goes out of each of them. The read happens on every tap, even for
    /// a row the membership pass ticked: the pass stops at the first page that shows the song, and the playlist may
    /// have changed since. The row is busy the way a save is, and stays ticked until YouTube has answered. If the menu
    /// is closed or the session ends before the read lands, nothing is sent and nothing is said. A session that ends
    /// between two writes stops the rest the same way; a menu closed between them does not.
    private func removeSong(_ track: MusicTrack, from option: MusicPlaylistOption) {
        let targetKey = Picker.Target.track(track).key
        let key = busyKey("unsave:\(option.playlistId):\(targetKey)")
        guard busy.insert(key).inserted else { return }
        savesOut[targetKey, default: []].insert(option.playlistId)
        removalsOut[targetKey, default: []].insert(option.playlistId)
        picker?.saving.insert(option.playlistId)
        picker?.removing.insert(option.playlistId)
        let session = sessionRun, run = pickerRun
        Task { [weak self, backend] in
            var left: [String] = []
            var done: [String] = []
            do {
                left = try await Self.places(of: track.videoId, inPlaylist: option.playlistId, backend: backend)
                guard self?.pickerRun == run, self?.sessionRun == session else {
                    self?.dropRemoval(option, targetKey: targetKey, key: key, session: session)
                    return
                }
                if left.isEmpty { throw RemovalMiss.notFound }
                while let place = left.first {
                    // Checked before every write: a session that ended while one was out gets none of the rest.
                    guard self?.sessionRun == session else {
                        self?.dropRemoval(option, targetKey: targetKey, key: key, session: session)
                        return
                    }
                    try await backend.removeFromPlaylist(videoId: track.videoId, setVideoId: place, playlistId: option.playlistId)
                    done.append(left.removeFirst())
                }
                self?.landSongRemoval(option, removed: done, targetKey: targetKey, key: key, session: session)
            } catch {
                self?.failSongRemoval(error, option: option, removed: done, targetKey: targetKey, key: key, session: session)
            }
        }
    }

    /// What a removal said when a later call failed after earlier ones landed: how many of the songs are gone. A song
    /// counts only when every copy of it went (a song's copies can fall in two calls). nil when none is gone, or no call
    /// landed, so the failure's own line stands.
    private static func partialRemovalLine(
        done: [MusicPlaylistRemoval], of found: [MusicPlaylistRemoval], title: String
    ) -> String? {
        guard !done.isEmpty else { return nil }
        let gone = Set(done.map(\.setVideoId))
        let all = Set(found.map(\.videoId))
        let left = Set(found.filter { !gone.contains($0.setVideoId) }.map(\.videoId))
        let removed = all.subtracting(left).count
        guard removed > 0 else { return nil }
        return "Removed \(removed) of \(songCount(all.count)) from \(title)"
    }

    /// Unticks the row in whichever menu is open for the song, the one the tap came from or one opened again since, and
    /// takes the song off a playlist page that is open.
    private func landSongRemoval(
        _ option: MusicPlaylistOption, removed: [String], message: String? = nil, targetKey: String, key: String, session: Int
    ) {
        busy.remove(key)
        guard sessionRun == session else { return }
        endSave(option.playlistId, targetKey: targetKey)
        if var current = picker, current.target.key == targetKey {
            current.saving.remove(option.playlistId)
            current.removing.remove(option.playlistId)
            current.removedFrom.insert(option.playlistId)
            current.held[option.playlistId] = nil
            current.wrote = true
            if case .loaded(var options) = current.load,
               let index = options.firstIndex(where: { $0.playlistId == option.playlistId }) {
                options[index] = Self.unticked(options[index])
                current.load = .loaded(options)
            }
            picker = current
        }
        dropFromPage(option, places: removed)
        post(message ?? "Removed from \(option.title)")
    }

    /// A removal that did not go all the way: the row stays ticked, and a tap on it again reads the playlist afresh, so
    /// it sends only the places that are still there. The places that did go are off an open page already.
    private func failSongRemoval(
        _ error: any Error, option: MusicPlaylistOption, removed: [String], several: Bool = false,
        partialLine: String? = nil, targetKey: String, key: String, session: Int
    ) {
        busy.remove(key)
        guard sessionRun == session else { return }
        logger.error("removal failed: \(MusicService.logDescription(of: error), privacy: .public)")
        endSave(option.playlistId, targetKey: targetKey)
        if picker?.target.key == targetKey {
            picker?.saving.remove(option.playlistId)
            picker?.removing.remove(option.playlistId)
            if !removed.isEmpty { picker?.wrote = true }
        }
        dropFromPage(option, places: removed)
        guard !expireIfSignedOut(error) else { return }
        if let partialLine {
            post(partialLine, isError: true)
        } else if case RemovalMiss.notFound = error {
            post("Not removed. Couldn't find \(several ? "them" : "it") in \(option.title).", isError: true)
        } else if (error as? MusicError) == .rejected {
            post("Not removed from \(option.title).", isError: true)
        } else {
            post(Self.playlistWriteMessage(for: error), isError: true)
        }
    }

    /// A removal that must not go on: the read of the playlist landed after its menu was closed or its session ended
    /// (nothing was sent), or the session ended between two of its writes (the rest were not sent). The row is only
    /// freed, and nothing is said.
    private func dropRemoval(_ option: MusicPlaylistOption, targetKey: String, key: String, session: Int) {
        busy.remove(key)
        guard sessionRun == session else { return }
        endSave(option.playlistId, targetKey: targetKey)
        if picker?.target.key == targetKey {
            picker?.saving.remove(option.playlistId)
            picker?.removing.remove(option.playlistId)
        }
    }

    /// Takes the rows that were removed off the playlist's page, if it is open.
    private func dropFromPage(_ option: MusicPlaylistOption, places: [String]) {
        for place in places { browse.removeTrack(setVideoId: place, from: "VL" + option.playlistId) }
    }

    // MARK: - Save or take out several songs

    /// How many songs go in one call to YouTube.
    nonisolated static let editBatchSize = 50

    nonisolated private static func chunks<T>(_ items: [T]) -> [[T]] {
        stride(from: 0, to: items.count, by: editBatchSize).map { Array(items[$0..<min($0 + editBatchSize, items.count)]) }
    }

    private static func songCount(_ count: Int) -> String {
        count == 1 ? "1 song" : "\(count) songs"
    }

    /// A tap on a row of a menu for several songs. A ticked row holds all of them and takes them out again; any other
    /// row, empty or mixed, gets the songs it lacks.
    private func chooseSongs(_ songs: [MusicTrack], from option: MusicPlaylistOption, held: Set<String>) {
        guard let targetKey = picker?.target.key else { return }
        if option.containsVideo {
            removeSongs(songs, from: option, targetKey: targetKey)
        } else {
            addSongs(songs, to: option, held: held, targetKey: targetKey)
        }
    }

    /// Adds the songs the playlist is not known to hold, `editBatchSize` to a call. A call YouTube refuses is tried again
    /// one song at a time (it refuses a whole call when one song is in already), and the line counts what went in. Any
    /// other failure stops the rest, with its own line; what had gone in stays in. A chunk of one song has nothing
    /// smaller to try. The session is checked before every write: one that ended while a call was out gets none of the
    /// rest, and no line.
    private func addSongs(_ songs: [MusicTrack], to option: MusicPlaylistOption, held: Set<String>, targetKey: String) {
        let wanted = songs.map(\.videoId).filter { !held.contains($0) }
        guard !wanted.isEmpty else {
            post("Already in \(option.title)")
            return
        }
        let key = busyKey("save:\(option.playlistId):\(targetKey)")
        guard busy.insert(key).inserted else { return }
        savesOut[targetKey, default: []].insert(option.playlistId)
        picker?.saving.insert(option.playlistId)
        let session = sessionRun
        Task { [weak self, backend] in
            var added: [String] = []
            var failure: (any Error)?
            for chunk in Self.chunks(wanted) {
                guard self?.sessionRun == session else { return }
                do {
                    try await backend.addToPlaylist(videoIds: chunk, playlistId: option.playlistId)
                    added += chunk
                } catch {
                    guard (error as? MusicError) == .rejected else {
                        failure = error
                        break
                    }
                    guard chunk.count > 1 else { continue }
                    for id in chunk {
                        guard self?.sessionRun == session else { return }
                        do {
                            try await backend.addToPlaylist(videoId: id, playlistId: option.playlistId)
                            added.append(id)
                        } catch {
                            guard (error as? MusicError) == .rejected else {
                                failure = error
                                break
                            }
                        }
                    }
                    if failure != nil { break }
                }
            }
            self?.landSongsAdd(option, wanted: wanted, added: added, failure: failure, targetKey: targetKey, key: key, session: session)
        }
    }

    /// Notes the songs that went in: the playlist now holds them, and its row is ticked once it holds all of the picked
    /// songs, mixed while it holds some.
    private func landSongsAdd(
        _ option: MusicPlaylistOption, wanted: [String], added: [String], failure: (any Error)?,
        targetKey: String, key: String, session: Int
    ) {
        busy.remove(key)
        guard sessionRun == session else { return }
        endSave(option.playlistId, targetKey: targetKey)
        if var current = picker, current.target.key == targetKey {
            current.saving.remove(option.playlistId)
            if !added.isEmpty {
                current.wrote = true
                let now = (current.held[option.playlistId] ?? []).union(added)
                current.held[option.playlistId] = now
                if Set(current.songs.map(\.videoId)).isSubset(of: now), case .loaded(var options) = current.load,
                   let index = options.firstIndex(where: { $0.playlistId == option.playlistId }) {
                    options[index] = Self.ticked(options[index])
                    current.load = .loaded(options)
                }
            }
            picker = current
        }
        if let failure {
            logger.error("save failed: \(MusicService.logDescription(of: failure), privacy: .public)")
            guard !expireIfSignedOut(failure) else { return }
            if added.isEmpty {
                post(Self.playlistWriteMessage(for: failure), isError: true)
            } else {
                // Some went in before the call that failed: the line says how many, which the failure's own cannot.
                post("Added \(added.count) of \(Self.songCount(wanted.count)) to \(option.title)", isError: true)
            }
        } else if added.isEmpty {
            post("Not added. \(option.title) may already have them.", isError: true)
        } else if added.count == wanted.count {
            post("Added \(Self.songCount(added.count)) to \(option.title)")
        } else {
            post("Added \(added.count) of \(Self.songCount(wanted.count)) to \(option.title)")
        }
    }

    /// A tap on a ticked row of a menu for several songs: that one playlist is read once for the place of every row
    /// that holds any of them (all copies), and they go out in calls of `editBatchSize`. Like `removeSong` it reads on
    /// every tap, sends nothing when the menu closed or the session ended before the read landed, and keeps the row
    /// ticked until YouTube has answered. A call that fails stops the rest; the rows already taken out stay out.
    private func removeSongs(_ songs: [MusicTrack], from option: MusicPlaylistOption, targetKey: String) {
        let key = busyKey("unsave:\(option.playlistId):\(targetKey)")
        guard busy.insert(key).inserted else { return }
        savesOut[targetKey, default: []].insert(option.playlistId)
        removalsOut[targetKey, default: []].insert(option.playlistId)
        picker?.saving.insert(option.playlistId)
        picker?.removing.insert(option.playlistId)
        let session = sessionRun, run = pickerRun
        let wanted = Set(songs.map(\.videoId))
        Task { [weak self, backend] in
            var done: [MusicPlaylistRemoval] = []
            var found: [MusicPlaylistRemoval] = []
            do {
                found = try await Self.removals(of: wanted, inPlaylist: option.playlistId, backend: backend)
                guard self?.pickerRun == run, self?.sessionRun == session else {
                    self?.dropRemoval(option, targetKey: targetKey, key: key, session: session)
                    return
                }
                if found.isEmpty { throw RemovalMiss.notFound }
                for chunk in Self.chunks(found) {
                    guard self?.sessionRun == session else {
                        self?.dropRemoval(option, targetKey: targetKey, key: key, session: session)
                        return
                    }
                    try await backend.removeFromPlaylist(chunk, playlistId: option.playlistId)
                    done += chunk
                }
                let count = Self.songCount(Set(done.map(\.videoId)).count)
                self?.landSongRemoval(
                    option, removed: done.map(\.setVideoId), message: "Removed \(count) from \(option.title)",
                    targetKey: targetKey, key: key, session: session
                )
            } catch {
                self?.failSongRemoval(
                    error, option: option, removed: done.map(\.setVideoId), several: true,
                    partialLine: Self.partialRemovalLine(done: done, of: found, title: option.title),
                    targetKey: targetKey, key: key, session: session
                )
            }
        }
    }

    // MARK: - Which playlists hold it

    /// How a pass read one playlist against what is being saved.
    private enum Membership: Sendable {
        case holdsAll
        /// Holds all but some of the picked songs: the ones it does hold, none for a single song or album.
        case lacksSome(held: Set<String>)
        case failed(any Error)
        case cancelled
    }

    /// Why the pass gave up before reading any playlist, other than a failed read.
    private enum MembershipSkip: Error {
        case emptySource
        case sourceTooLong
    }

    /// YouTube Music does not say which playlists already hold the song (its answer has no such flag), so the store
    /// reads them itself. Each row not ticked yet has its playlist's songs read, `membershipConcurrency` playlists at a
    /// time, and is ticked the moment the playlist is found to hold all that is being saved. The pass only ticks: it
    /// stops at the first page that shows the song, so it does not know every place the song sits in, and a tap that
    /// takes the song out reads the playlist again (`removeSong`). A row is never unticked here: a save may have ticked
    /// it meanwhile, and one the song was taken out of is not ticked again. A read that fails leaves its row as it was
    /// and shows nothing, and the others go on. Nothing in this pass signs the user out; a gone session shows on the
    /// next tap.
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
                    case .lacksSome(let some):
                        if !some.isEmpty { self?.landHeld(playlistId, some, run: run, targetKey: key) }
                    case .cancelled:
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
    /// while the pass is out, and the song was not taken out of it meanwhile.
    private func needsMembershipRead(_ playlistId: String, run: Int, targetKey: String) -> Bool {
        guard pickerRun == run, let current = picker, current.target.key == targetKey,
              case .loaded(let options) = current.load,
              let row = options.first(where: { $0.playlistId == playlistId }) else { return false }
        return !row.containsVideo && !current.removedFrom.contains(playlistId)
    }

    /// Ticks one row, in the picker the pass was started for. Never unticks, and leaves a row a save ticked or a
    /// removal unticked alone.
    private func landMembership(_ playlistId: String, run: Int, targetKey: String) {
        guard pickerRun == run, var current = picker, current.target.key == targetKey,
              case .loaded(var options) = current.load,
              let index = options.firstIndex(where: { $0.playlistId == playlistId }),
              !options[index].containsVideo, !current.removedFrom.contains(playlistId) else { return }
        options[index] = Self.ticked(options[index])
        current.load = .loaded(options)
        picker = current
    }

    /// Notes which of the picked songs a playlist holds, for the mixed mark. Only a pick of songs has one, and a
    /// playlist the songs were taken out of is not told again by a read that began before.
    private func landHeld(_ playlistId: String, _ some: Set<String>, run: Int, targetKey: String) {
        guard pickerRun == run, var current = picker, current.target.key == targetKey, case .tracks(_) = current.target,
              !current.removedFrom.contains(playlistId) else { return }
        current.held[playlistId, default: []].formUnion(some)
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
        case .tracks(let tracks):
            return Set(tracks.map(\.videoId))
        case .collection(_, let sourceId):
            let source = try await readPlaylist(browseId: "VL" + sourceId, backend: backend, until: nil)
            if source.ids.isEmpty { throw MembershipSkip.emptySource }
            if !source.complete { throw MembershipSkip.sourceTooLong }
            return source.ids
        }
    }

    nonisolated private static func membership(
        ofPlaylist playlistId: String, holding wanted: Set<String>, backend: any MusicBackend
    ) async -> Membership {
        do {
            let read = try await readPlaylist(browseId: "VL" + playlistId, backend: backend, until: wanted)
            return wanted.isSubset(of: read.ids) ? .holdsAll : .lacksSome(held: wanted.intersection(read.ids))
        } catch {
            return Task.isCancelled ? .cancelled : .failed(error)
        }
    }

    /// The setVideoId of every row of a playlist that holds the song, in playlist order, from the whole playlist (up to
    /// the page limit). Empty when the song is not there, or its rows name no place.
    nonisolated private static func places(
        of videoId: String, inPlaylist playlistId: String, backend: any MusicBackend
    ) async throws -> [String] {
        try await readPlaylist(browseId: "VL" + playlistId, backend: backend, until: nil, placesOf: [videoId]).places.map(\.setVideoId)
    }

    /// The place of every row of a playlist that holds any of the songs, with its song, in playlist order, from the whole
    /// playlist (up to the page limit).
    nonisolated private static func removals(
        of songs: Set<String>, inPlaylist playlistId: String, backend: any MusicBackend
    ) async throws -> [MusicPlaylistRemoval] {
        try await readPlaylist(browseId: "VL" + playlistId, backend: backend, until: nil, placesOf: songs).places
    }

    /// The video ids on a playlist page and the pages behind it, at most `membershipPageLimit` pages. With `wanted` it
    /// stops as soon as all of them have been seen. `complete` is false when it stopped at the limit with pages left.
    /// With `placesOf` it also gathers the place (setVideoId, with its song) of each row holding one of those songs on
    /// the pages it read; a row that names no place, or one already gathered, adds nothing.
    nonisolated private static func readPlaylist(
        browseId: String, backend: any MusicBackend, until wanted: Set<String>?, placesOf songs: Set<String> = []
    ) async throws -> (ids: Set<String>, complete: Bool, places: [MusicPlaylistRemoval]) {
        try Task.checkCancellation()
        let first = try await backend.page(browseId: browseId)
        var ids = Set(first.tracks.map(\.videoId))
        var places: [MusicPlaylistRemoval] = []
        gatherPlaces(of: songs, in: first.tracks, into: &places)
        var token = first.continuation
        var pages = 1
        while true {
            if let wanted, wanted.isSubset(of: ids) { return (ids, true, places) }
            guard let current = token else { return (ids, true, places) }
            guard pages < membershipPageLimit else { return (ids, false, places) }
            try Task.checkCancellation()
            let more = try await backend.moreTracks(browseId: browseId, continuation: current)
            pages += 1
            ids.formUnion(more.tracks.map(\.videoId))
            gatherPlaces(of: songs, in: more.tracks, into: &places)
            token = more.continuation
        }
    }

    nonisolated private static func gatherPlaces(
        of songs: Set<String>, in tracks: [MusicTrack], into places: inout [MusicPlaylistRemoval]
    ) {
        guard !songs.isEmpty else { return }
        for track in tracks where songs.contains(track.videoId) {
            if let place = track.playlistSetVideoId, !place.isEmpty, !places.contains(where: { $0.setVideoId == place }) {
                places.append(MusicPlaylistRemoval(videoId: track.videoId, setVideoId: place))
            }
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

    /// Takes the rows out of the open playlist, `editBatchSize` to a call, and each call's rows off the page as it is
    /// answered. Only rows the playlist's rules offer to remove count (an editable playlist page, never Liked Music, a
    /// row with a place); a row listed twice is one. A call that fails stops the rest and leaves its rows on the page;
    /// the rows before it stay removed, and the line says how many went. `onRemoved` runs once when every call has landed,
    /// and never for one that failed. The same pick sent again while it is out goes once.
    func removeRows(_ rows: [MusicTrack], in context: MusicTrackContext, onRemoved: (@MainActor () -> Void)? = nil) {
        var seen = Set<String>()
        let removals = rows.compactMap { row -> MusicPlaylistRemoval? in
            guard MusicTrackActions.canRemove(row, in: context), let place = row.playlistSetVideoId,
                  seen.insert(place).inserted else { return nil }
            return MusicPlaylistRemoval(videoId: row.videoId, setVideoId: place)
        }
        guard !removals.isEmpty, let pageId = context.pageBrowseId else { return }
        let key = busyKey("removeRows:\(pageId):\(Picker.Target.fingerprint(of: removals.map(\.setVideoId)))")
        guard busy.insert(key).inserted else { return }
        let session = sessionRun
        let name = Self.playlistName(context.pageTitle)
        Task { [weak self, backend] in
            var done = 0
            do {
                for chunk in Self.chunks(removals) {
                    guard self?.sessionRun == session else { return }
                    try await backend.removeFromPlaylist(chunk, playlistId: pageId)
                    guard self?.sessionRun == session else { return }
                    for removal in chunk { self?.browse.removeTrack(setVideoId: removal.setVideoId, from: pageId) }
                    done += chunk.count
                }
                self?.landRowsRemoval(count: done, name: name, key: key, session: session, onRemoved: onRemoved)
            } catch {
                self?.failRowsRemoval(error, removed: done, of: removals.count, name: name, key: key, session: session)
            }
        }
    }

    private func landRowsRemoval(count: Int, name: String, key: String, session: Int, onRemoved: (@MainActor () -> Void)?) {
        busy.remove(key)
        guard sessionRun == session else { return }
        post("Removed \(Self.songCount(count)) from \(name)")
        onRemoved?()
    }

    /// `removed` of the `total` rows had gone when a call failed; they are off the page already.
    private func failRowsRemoval(_ error: any Error, removed: Int, of total: Int, name: String, key: String, session: Int) {
        busy.remove(key)
        guard sessionRun == session else { return }
        logger.error("removal of rows failed: \(MusicService.logDescription(of: error), privacy: .public)")
        guard !expireIfSignedOut(error) else { return }
        if removed > 0 {
            post("Removed \(removed) of \(Self.songCount(total)) from \(name)", isError: true)
        } else if (error as? MusicError) == .rejected {
            post("Not removed from \(name).", isError: true)
        } else {
            post(Self.playlistWriteMessage(for: error), isError: true)
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

    /// A playlist write that failed: the session going away signs out, anything else shows its line and leaves the page as it was.
    private func failWrite(_ error: any Error, key: String, session: Int) {
        busy.remove(key)
        guard sessionRun == session else { return }
        logger.error("write failed: \(MusicService.logDescription(of: error), privacy: .public)")
        if !expireIfSignedOut(error) { post(Self.playlistWriteMessage(for: error), isError: true) }
    }

    /// What a refused edit of a playlist says when YouTube Music answers 403: the channel in use does not own the
    /// playlist, which the generic line for a 403 cannot tell.
    static let playlistForbiddenText =
        "This channel can't edit that playlist. If it's on another channel, use Switch channel in the account card."

    /// The line for a failed playlist write (remove from a playlist, add to a playlist, add a whole playlist). Every
    /// other error keeps its generic line. Likes and the picker's list do not come through here.
    private static func playlistWriteMessage(for error: any Error) -> String {
        (error as? MusicError) == .forbidden ? playlistForbiddenText : MusicService.message(for: error)
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

    /// Shows what a Like, Dislike or Save came to when it did not happen, in the words the hotkey HUD has for it: a
    /// refusal or a failed call, as an error. An outcome with no words (a quiet one, or a rating that was made, which
    /// the like animation and the icons show) shows nothing and leaves a line that is up.
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
        removalsOut.removeAll()
    }
}
