// DeciTests/Music/FakeMusicBackend.swift
// Test doubles for the Music tab: a scriptable backend, a fake AVPlayer seam and small fixtures.

import Foundation
import MediaPlayer
import os
@testable import Deci

// MediaPlayer re-exports AudioToolbox, whose `MusicTrack` and `MusicPlayer` clash with ours: spell them `Deci.MusicTrack` in files that import it.

/// Suspends callers until `open()`; lets a test hold a request in flight.
actor MusicTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

/// Stands in for the wait before a disliked song is skipped. A wait returns at once, unless `hold()` was called: then each
/// wait parks until `release()`. It records how many seconds each wait was asked for, so a test can check the delay.
@MainActor
final class DislikeSkipSleep {
    private(set) var requested: [TimeInterval] = []
    private var holds = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    /// From now on a wait parks until `release()`.
    func hold() { holds = true }

    func sleep(_ seconds: TimeInterval) async {
        requested.append(seconds)
        guard holds else { return }
        await withCheckedContinuation { parked.append($0) }
    }

    /// Lets the waits that are parked return; waits asked for later return at once.
    func release() {
        holds = false
        let waiting = parked
        parked = []
        for continuation in waiting { continuation.resume() }
    }
}

actor FakeMusicBackend: MusicBackend {
    nonisolated struct Report: Equatable, Sendable {
        let kind: HistoryPing.Kind
        let url: URL
        let cpn: String
        let mediaTime: TimeInterval
        let details: WatchtimeDetails?
    }

    nonisolated struct MoreRadioCall: Hashable, Sendable {
        let seed: String
        let continuation: String
    }

    nonisolated struct MoreLibraryCall: Hashable, Sendable {
        let section: MusicLibrarySection
        let continuation: String
    }

    nonisolated struct MoreTracksCall: Hashable, Sendable {
        let browseId: String
        let continuation: String
    }

    nonisolated struct AddToPlaylistCall: Hashable, Sendable {
        let videoId: String
        let playlistId: String
    }

    nonisolated struct AddPlaylistCall: Hashable, Sendable {
        let sourceId: String
        let playlistId: String
    }

    nonisolated struct RemoveFromPlaylistCall: Hashable, Sendable {
        let videoId: String
        let setVideoId: String
        let playlistId: String
    }

    nonisolated struct RateCall: Hashable, Sendable {
        let videoId: String
        let status: MusicLikeStatus
    }

    private var signedIn: Bool
    private var signInError: (any Error)?
    private var searchResults: [String: [Deci.MusicTrack]] = [:]
    private var searchErrors: [String: any Error] = [:]
    private var searchGates: [String: MusicTestGate] = [:]
    private var artistSearchResults: [String: [MusicCollection]] = [:]
    private var artistSearchErrors: [String: any Error] = [:]
    private var artistSearchGates: [String: MusicTestGate] = [:]
    private var streams: [String: ResolvedStream] = [:]
    private var resolveErrors: [String: any Error] = [:]
    private var resolveGates: [String: MusicTestGate] = [:]
    private var reportErrors: [HistoryPing.Kind: any Error] = [:]
    private var reportStatus = 204
    private var reportGate: MusicTestGate?
    private var radioPages: [String: MusicQueuePage] = [:]
    private var radioErrors: [String: any Error] = [:]
    private var radioGates: [String: MusicTestGate] = [:]
    private var radioFailures: [String: (error: any Error, remaining: Int)] = [:]
    private var morePages: [MoreRadioCall: MusicQueuePage] = [:]
    private var moreErrors: [MoreRadioCall: any Error] = [:]
    private var moreGates: [MoreRadioCall: MusicTestGate] = [:]
    private var homePage = MusicHomePage(shelves: [], continuation: nil)
    private var homeError: (any Error)?
    private var homeGate: MusicTestGate?
    private var moreHomePages: [String: MusicHomePage] = [:]
    private var moreHomeErrors: [String: any Error] = [:]
    private var moreHomeGates: [String: MusicTestGate] = [:]
    private var historyPage = MusicHomePage(shelves: [], continuation: nil)
    private var historyError: (any Error)?
    private var historyGate: MusicTestGate?
    private var moreHistoryPages: [String: MusicHomePage] = [:]
    private var moreHistoryErrors: [String: any Error] = [:]
    private var moreHistoryGates: [String: MusicTestGate] = [:]
    private var libraryLists: [MusicLibrarySection: MusicCollectionList] = [:]
    private var libraryErrors: [MusicLibrarySection: any Error] = [:]
    private var libraryGates: [MusicLibrarySection: MusicTestGate] = [:]
    private var moreLibraryLists: [MoreLibraryCall: MusicCollectionList] = [:]
    private var moreLibraryErrors: [MoreLibraryCall: any Error] = [:]
    private var moreLibraryGates: [MoreLibraryCall: MusicTestGate] = [:]
    private var browsePages: [String: MusicBrowsePage] = [:]
    private var pageErrors: [String: any Error] = [:]
    private var pageGates: [String: MusicTestGate] = [:]
    private var moreTracksPages: [MoreTracksCall: MusicQueuePage] = [:]
    private var moreTracksErrors: [MoreTracksCall: any Error] = [:]
    private var moreTracksGates: [MoreTracksCall: MusicTestGate] = [:]
    private var playlistOptions: [String: [MusicPlaylistOption]] = [:]
    private var playlistOptionsErrors: [String: any Error] = [:]
    private var playlistOptionsGates: [String: MusicTestGate] = [:]
    private var sourceOptions: [String: [MusicPlaylistOption]] = [:]
    private var sourceOptionsErrors: [String: any Error] = [:]
    private var sourceOptionsGates: [String: MusicTestGate] = [:]
    private var addToPlaylistError: (any Error)?
    private var addToPlaylistGate: MusicTestGate?
    private var removeFromPlaylistError: (any Error)?
    private var removeFromPlaylistRowErrors: [String: any Error] = [:]
    private var removeFromPlaylistGate: MusicTestGate?
    private var likeStatuses: [String: MusicLikeStatus] = [:]
    private var likeStatusErrors: [String: any Error] = [:]
    private var likeStatusGates: [String: MusicTestGate] = [:]
    private var rateErrors: [String: any Error] = [:]
    private var rateGates: [String: MusicTestGate] = [:]

    private(set) var radioSeeds: [String] = []
    private(set) var moreRadioCalls: [MoreRadioCall] = []
    private(set) var homeCallCount = 0
    private(set) var moreHomeCalls: [String] = []
    private(set) var historyCallCount = 0
    private(set) var moreHistoryCalls: [String] = []
    private(set) var libraryCalls: [MusicLibrarySection] = []
    private(set) var moreLibraryCalls: [MoreLibraryCall] = []
    private(set) var pageCalls: [String] = []
    private(set) var moreTracksCalls: [MoreTracksCall] = []
    private(set) var playlistOptionsCalls: [String] = []
    private(set) var sourceOptionsCalls: [String] = []
    private(set) var addToPlaylistCalls: [AddToPlaylistCall] = []
    private(set) var addPlaylistCalls: [AddPlaylistCall] = []
    private(set) var removeFromPlaylistCalls: [RemoveFromPlaylistCall] = []
    private(set) var likeStatusCalls: [String] = []
    private(set) var rateCalls: [RateCall] = []
    private(set) var searchedQueries: [String] = []
    private(set) var searchedArtistQueries: [String] = []
    private(set) var resolvedIDs: [String] = []
    private(set) var reportAttempts: [Report] = []
    private(set) var signInCookies: [[StoredCookie]] = []
    private var identity: Bool?
    private var account: MusicAccount?
    private var accountError: (any Error)?
    private var accountGate: MusicTestGate?
    private(set) var accountCallCount = 0
    private var currentCookies: [StoredCookie] = []
    private(set) var signOutCount = 0
    /// How many times the quit path asked for the held-back cookies to be written. Counted outside the
    /// actor, because the real call is synchronous.
    private nonisolated let cookieFlushes = OSAllocatedUnfairLock(initialState: 0)

    nonisolated var cookieFlushCount: Int { cookieFlushes.withLock { $0 } }

    /// How many artist searches were cancelled while held at their gate. Counted outside the actor, because the
    /// cancellation handler runs on the cancelling task.
    private nonisolated let artistCancels = OSAllocatedUnfairLock(initialState: 0)

    nonisolated var artistSearchCancelCount: Int { artistCancels.withLock { $0 } }

    init(signedIn: Bool = true) {
        self.signedIn = signedIn
    }

    // MARK: Scripting

    func setSignedIn(_ value: Bool) { signedIn = value }
    func setChannelIdentity(_ value: Bool?) { identity = value }
    func setSessionCookies(_ value: [StoredCookie]) { currentCookies = value }
    /// What the account menu answers with. A gate holds the call until it is opened; passing nil removes a gate or an error.
    func setAccount(_ value: MusicAccount?) { account = value }
    func setAccountError(_ error: (any Error)?) { accountError = error }
    func setAccountGate(_ gate: MusicTestGate?) { accountGate = gate }
    func setSignInError(_ error: (any Error)?) { signInError = error }
    func setSearch(_ query: String, results: [Deci.MusicTrack]) { searchResults[query] = results }
    func setSearchError(_ query: String, _ error: any Error) { searchErrors[query] = error }
    func setSearchGate(_ query: String, _ gate: MusicTestGate) { searchGates[query] = gate }
    /// What the artists filter of a search answers with. An error or a gate holds for that query only.
    func setArtistSearch(_ query: String, results: [MusicCollection]) { artistSearchResults[query] = results }
    func setArtistSearchError(_ query: String, _ error: any Error) { artistSearchErrors[query] = error }
    func setArtistSearchGate(_ query: String, _ gate: MusicTestGate) { artistSearchGates[query] = gate }
    func setStream(_ stream: ResolvedStream) { streams[stream.videoId] = stream }
    func setResolveError(_ videoId: String, _ error: any Error) { resolveErrors[videoId] = error }
    func clearResolveError(_ videoId: String) { resolveErrors[videoId] = nil }
    func setResolveGate(_ videoId: String, _ gate: MusicTestGate) { resolveGates[videoId] = gate }
    /// Makes history pings throw `error`: both kinds, or just `kind` when given. Nil clears.
    func setReportError(_ error: (any Error)?, kind: HistoryPing.Kind? = nil) {
        for each in kind.map({ [$0] }) ?? [.playback, .watchtime] { reportErrors[each] = error }
    }
    func setReportStatus(_ status: Int) { reportStatus = status }
    /// Holds every history ping at the gate until it is opened, after it has been recorded: a ping in flight. Nil removes it.
    func setReportGate(_ gate: MusicTestGate?) { reportGate = gate }
    func setRadio(seed: String, tracks: [Deci.MusicTrack], continuation: String? = nil) {
        radioPages[seed] = MusicQueuePage(tracks: tracks, continuation: continuation)
    }
    func setRadioError(seed: String, _ error: (any Error)?) { radioErrors[seed] = error }
    func setRadioGate(seed: String, _ gate: MusicTestGate) { radioGates[seed] = gate }
    /// The radio of `seed` fails with `error` for the next `times` calls, then answers as scripted.
    func setRadioFailures(seed: String, _ error: any Error, times: Int) { radioFailures[seed] = (error, times) }
    func setMoreRadio(seed: String, continuation: String, tracks: [Deci.MusicTrack], next: String? = nil) {
        morePages[MoreRadioCall(seed: seed, continuation: continuation)] = MusicQueuePage(tracks: tracks, continuation: next)
    }
    func setMoreRadioError(seed: String, continuation: String, _ error: any Error) {
        moreErrors[MoreRadioCall(seed: seed, continuation: continuation)] = error
    }
    func setMoreRadioGate(seed: String, continuation: String, _ gate: MusicTestGate) {
        moreGates[MoreRadioCall(seed: seed, continuation: continuation)] = gate
    }

    // Browse scripting. An unscripted call answers with an empty result. A gate holds that call
    // until it is opened; passing nil removes a gate or an error.
    func setHome(shelves: [MusicShelf], continuation: String? = nil) {
        homePage = MusicHomePage(shelves: shelves, continuation: continuation)
    }
    func setHomeError(_ error: (any Error)?) { homeError = error }
    func setHomeGate(_ gate: MusicTestGate?) { homeGate = gate }
    func setMoreHome(continuation: String, shelves: [MusicShelf], next: String? = nil) {
        moreHomePages[continuation] = MusicHomePage(shelves: shelves, continuation: next)
    }
    func setMoreHomeError(continuation: String, _ error: (any Error)?) { moreHomeErrors[continuation] = error }
    func setMoreHomeGate(continuation: String, _ gate: MusicTestGate?) { moreHomeGates[continuation] = gate }

    func setHistory(shelves: [MusicShelf], continuation: String? = nil) {
        historyPage = MusicHomePage(shelves: shelves, continuation: continuation)
    }
    func setHistoryError(_ error: (any Error)?) { historyError = error }
    func setHistoryGate(_ gate: MusicTestGate?) { historyGate = gate }
    func setMoreHistory(continuation: String, shelves: [MusicShelf], next: String? = nil) {
        moreHistoryPages[continuation] = MusicHomePage(shelves: shelves, continuation: next)
    }
    func setMoreHistoryError(continuation: String, _ error: (any Error)?) { moreHistoryErrors[continuation] = error }
    func setMoreHistoryGate(continuation: String, _ gate: MusicTestGate?) { moreHistoryGates[continuation] = gate }

    func setLibrary(_ section: MusicLibrarySection, items: [MusicCollection], continuation: String? = nil) {
        libraryLists[section] = MusicCollectionList(items: items, continuation: continuation)
    }
    func setLibraryError(_ section: MusicLibrarySection, _ error: (any Error)?) { libraryErrors[section] = error }
    func setLibraryGate(_ section: MusicLibrarySection, _ gate: MusicTestGate?) { libraryGates[section] = gate }
    func setMoreLibrary(_ section: MusicLibrarySection, continuation: String, items: [MusicCollection], next: String? = nil) {
        moreLibraryLists[MoreLibraryCall(section: section, continuation: continuation)] = MusicCollectionList(items: items, continuation: next)
    }
    func setMoreLibraryError(_ section: MusicLibrarySection, continuation: String, _ error: (any Error)?) {
        moreLibraryErrors[MoreLibraryCall(section: section, continuation: continuation)] = error
    }
    func setMoreLibraryGate(_ section: MusicLibrarySection, continuation: String, _ gate: MusicTestGate?) {
        moreLibraryGates[MoreLibraryCall(section: section, continuation: continuation)] = gate
    }

    func setPage(_ page: MusicBrowsePage) { browsePages[page.browseId] = page }
    func setPageError(_ browseId: String, _ error: (any Error)?) { pageErrors[browseId] = error }
    func setPageGate(_ browseId: String, _ gate: MusicTestGate?) { pageGates[browseId] = gate }
    func setMoreTracks(browseId: String, continuation: String, tracks: [Deci.MusicTrack], next: String? = nil) {
        moreTracksPages[MoreTracksCall(browseId: browseId, continuation: continuation)] = MusicQueuePage(tracks: tracks, continuation: next)
    }
    func setMoreTracksError(browseId: String, continuation: String, _ error: (any Error)?) {
        moreTracksErrors[MoreTracksCall(browseId: browseId, continuation: continuation)] = error
    }
    func setMoreTracksGate(browseId: String, continuation: String, _ gate: MusicTestGate?) {
        moreTracksGates[MoreTracksCall(browseId: browseId, continuation: continuation)] = gate
    }

    // Song actions. The picker's list is scripted per video, or per source playlist when a whole album or playlist is
    // being saved; the write calls (a song, or a whole playlist, added) share one error and one gate and are recorded.
    // A gate holds the call after it was recorded; nil removes a gate or an error.
    func setPlaylistOptions(videoId: String, _ options: [MusicPlaylistOption]) { playlistOptions[videoId] = options }
    func setPlaylistOptionsError(videoId: String, _ error: (any Error)?) { playlistOptionsErrors[videoId] = error }
    func setPlaylistOptionsGate(videoId: String, _ gate: MusicTestGate?) { playlistOptionsGates[videoId] = gate }
    func setSourceOptions(sourceId: String, _ options: [MusicPlaylistOption]) { sourceOptions[sourceId] = options }
    func setSourceOptionsError(sourceId: String, _ error: (any Error)?) { sourceOptionsErrors[sourceId] = error }
    func setSourceOptionsGate(sourceId: String, _ gate: MusicTestGate?) { sourceOptionsGates[sourceId] = gate }
    func setAddToPlaylistError(_ error: (any Error)?) { addToPlaylistError = error }
    func setAddToPlaylistGate(_ gate: MusicTestGate?) { addToPlaylistGate = gate }
    func setRemoveFromPlaylistError(_ error: (any Error)?) { removeFromPlaylistError = error }
    /// Makes the removal of one row (named by its setVideoId) throw `error`, while removals of other rows go through; nil clears.
    func setRemoveFromPlaylistError(setVideoId: String, _ error: (any Error)?) { removeFromPlaylistRowErrors[setVideoId] = error }
    func setRemoveFromPlaylistGate(_ gate: MusicTestGate?) { removeFromPlaylistGate = gate }

    // Likes. The like state is scripted per video (an unscripted video has none: nil), and a successful rate call changes
    // it, as YouTube would. An error or a gate holds for that video only, after the call was recorded; nil removes it.
    func setLikeStatus(videoId: String, _ status: MusicLikeStatus?) { likeStatuses[videoId] = status }
    func setLikeStatusError(videoId: String, _ error: (any Error)?) { likeStatusErrors[videoId] = error }
    func setLikeStatusGate(videoId: String, _ gate: MusicTestGate?) { likeStatusGates[videoId] = gate }
    func setRateError(videoId: String, _ error: (any Error)?) { rateErrors[videoId] = error }
    func setRateGate(videoId: String, _ gate: MusicTestGate?) { rateGates[videoId] = gate }

    // MARK: MusicBackend

    func isSignedIn() async -> Bool { signedIn }

    func signIn(with cookies: [StoredCookie]) async throws {
        signInCookies.append(cookies)
        if let signInError { throw signInError }
        signedIn = true
    }

    nonisolated func flushCookies() {
        cookieFlushes.withLock { $0 += 1 }
    }

    func signOut() async {
        signOutCount += 1
        signedIn = false
    }

    func channelIdentity() async -> Bool? { signedIn ? identity : nil }

    func sessionCookies() async -> [StoredCookie] { currentCookies }

    // Like the browse calls, the answer is what was scripted when the call was made, even if a gate holds it.
    func accountInfo() async throws -> MusicAccount? {
        accountCallCount += 1
        let gate = accountGate, error = accountError, value = signedIn ? account : nil
        if let gate { await gate.wait() }
        if let error { throw error }
        return value
    }

    // A browse call answers with what was scripted when it was made, even if a gate holds it while
    // the test scripts something else: a slow server does not look at the request again.
    func home() async throws -> MusicHomePage {
        homeCallCount += 1
        let gate = homeGate, error = homeError, page = homePage
        if let gate { await gate.wait() }
        if let error { throw error }
        return page
    }

    func moreHome(continuation: String) async throws -> MusicHomePage {
        moreHomeCalls.append(continuation)
        let gate = moreHomeGates[continuation], error = moreHomeErrors[continuation]
        let page = moreHomePages[continuation] ?? MusicHomePage(shelves: [], continuation: nil)
        if let gate { await gate.wait() }
        if let error { throw error }
        return page
    }

    func history() async throws -> MusicHomePage {
        historyCallCount += 1
        let gate = historyGate, error = historyError, page = historyPage
        if let gate { await gate.wait() }
        if let error { throw error }
        return page
    }

    func moreHistory(continuation: String) async throws -> MusicHomePage {
        moreHistoryCalls.append(continuation)
        let gate = moreHistoryGates[continuation], error = moreHistoryErrors[continuation]
        let page = moreHistoryPages[continuation] ?? MusicHomePage(shelves: [], continuation: nil)
        if let gate { await gate.wait() }
        if let error { throw error }
        return page
    }

    func library(_ section: MusicLibrarySection) async throws -> MusicCollectionList {
        libraryCalls.append(section)
        let gate = libraryGates[section], error = libraryErrors[section]
        let list = libraryLists[section] ?? MusicCollectionList(items: [], continuation: nil)
        if let gate { await gate.wait() }
        if let error { throw error }
        return list
    }

    func moreLibrary(_ section: MusicLibrarySection, continuation: String) async throws -> MusicCollectionList {
        let call = MoreLibraryCall(section: section, continuation: continuation)
        moreLibraryCalls.append(call)
        let gate = moreLibraryGates[call], error = moreLibraryErrors[call]
        let list = moreLibraryLists[call] ?? MusicCollectionList(items: [], continuation: nil)
        if let gate { await gate.wait() }
        if let error { throw error }
        return list
    }

    func page(browseId: String) async throws -> MusicBrowsePage {
        pageCalls.append(browseId)
        let gate = pageGates[browseId], error = pageErrors[browseId]
        let page = browsePages[browseId]
            ?? MusicBrowsePage(browseId: browseId, title: "", subtitle: nil, thumbnailURL: nil, tracks: [], continuation: nil, shelves: [])
        if let gate { await gate.wait() }
        if let error { throw error }
        return page
    }

    func moreTracks(browseId: String, continuation: String) async throws -> MusicQueuePage {
        let call = MoreTracksCall(browseId: browseId, continuation: continuation)
        moreTracksCalls.append(call)
        let gate = moreTracksGates[call], error = moreTracksErrors[call]
        let page = moreTracksPages[call] ?? MusicQueuePage(tracks: [], continuation: nil)
        if let gate { await gate.wait() }
        if let error { throw error }
        return page
    }

    func addToPlaylistOptions(videoId: String) async throws -> [MusicPlaylistOption] {
        playlistOptionsCalls.append(videoId)
        let gate = playlistOptionsGates[videoId], error = playlistOptionsErrors[videoId]
        let options = playlistOptions[videoId] ?? []
        if let gate { await gate.wait() }
        if let error { throw error }
        return options
    }

    func addToPlaylistOptions(sourcePlaylistId: String) async throws -> [MusicPlaylistOption] {
        sourceOptionsCalls.append(sourcePlaylistId)
        let gate = sourceOptionsGates[sourcePlaylistId], error = sourceOptionsErrors[sourcePlaylistId]
        let options = sourceOptions[sourcePlaylistId] ?? []
        if let gate { await gate.wait() }
        if let error { throw error }
        return options
    }

    func addToPlaylist(videoId: String, playlistId: String) async throws {
        addToPlaylistCalls.append(AddToPlaylistCall(videoId: videoId, playlistId: playlistId))
        let gate = addToPlaylistGate, error = addToPlaylistError
        if let gate { await gate.wait() }
        if let error { throw error }
    }

    func addPlaylistToPlaylist(sourceId: String, playlistId: String) async throws {
        addPlaylistCalls.append(AddPlaylistCall(sourceId: sourceId, playlistId: playlistId))
        let gate = addToPlaylistGate, error = addToPlaylistError
        if let gate { await gate.wait() }
        if let error { throw error }
    }

    func removeFromPlaylist(videoId: String, setVideoId: String, playlistId: String) async throws {
        removeFromPlaylistCalls.append(RemoveFromPlaylistCall(videoId: videoId, setVideoId: setVideoId, playlistId: playlistId))
        let gate = removeFromPlaylistGate, error = removeFromPlaylistRowErrors[setVideoId] ?? removeFromPlaylistError
        if let gate { await gate.wait() }
        if let error { throw error }
    }

    // Like the browse calls, the like state answered is the one scripted when the call was made, even if a gate holds it.
    func likeStatus(videoId: String) async throws -> MusicLikeStatus? {
        likeStatusCalls.append(videoId)
        let gate = likeStatusGates[videoId], error = likeStatusErrors[videoId], status = likeStatuses[videoId]
        if let gate { await gate.wait() }
        if let error { throw error }
        return status
    }

    func rate(videoId: String, status: MusicLikeStatus) async throws {
        rateCalls.append(RateCall(videoId: videoId, status: status))
        let gate = rateGates[videoId], error = rateErrors[videoId]
        if let gate { await gate.wait() }
        if let error { throw error }
        likeStatuses[videoId] = status
    }

    func search(_ query: String) async throws -> [Deci.MusicTrack] {
        searchedQueries.append(query)
        if let gate = searchGates[query] { await gate.wait() }
        if let error = searchErrors[query] { throw error }
        return searchResults[query] ?? []
    }

    func searchArtists(_ query: String) async throws -> [MusicCollection] {
        searchedArtistQueries.append(query)
        if let gate = artistSearchGates[query] {
            // The gate itself does not end early on a cancel, so a test can hold the call past it and see that it was told.
            await withTaskCancellationHandler {
                await gate.wait()
            } onCancel: {
                artistCancels.withLock { $0 += 1 }
            }
        }
        if let error = artistSearchErrors[query] { throw error }
        return artistSearchResults[query] ?? []
    }

    func resolve(videoId: String) async throws -> ResolvedStream {
        resolvedIDs.append(videoId)
        if let gate = resolveGates[videoId] { await gate.wait() }
        if let error = resolveErrors[videoId] { throw error }
        return streams[videoId] ?? MusicSamples.stream(videoId: videoId)
    }

    func radio(seedVideoId: String) async throws -> MusicQueuePage {
        radioSeeds.append(seedVideoId)
        if let gate = radioGates[seedVideoId] { await gate.wait() }
        if var failing = radioFailures[seedVideoId], failing.remaining > 0 {
            failing.remaining -= 1
            radioFailures[seedVideoId] = failing
            throw failing.error
        }
        if let error = radioErrors[seedVideoId] { throw error }
        return radioPages[seedVideoId] ?? MusicQueuePage(tracks: [], continuation: nil)
    }

    func moreRadio(seedVideoId: String, continuation: String) async throws -> MusicQueuePage {
        let call = MoreRadioCall(seed: seedVideoId, continuation: continuation)
        moreRadioCalls.append(call)
        if let gate = moreGates[call] { await gate.wait() }
        if let error = moreErrors[call] { throw error }
        return morePages[call] ?? MusicQueuePage(tracks: [], continuation: nil)
    }

    func reportHistory(_ ping: HistoryPing) async throws -> Int {
        reportAttempts.append(Report(kind: ping.kind, url: ping.url, cpn: ping.cpn, mediaTime: ping.mediaTime, details: ping.details))
        if let gate = reportGate { await gate.wait() }
        if let error = reportErrors[ping.kind] { throw error }
        return reportStatus
    }
}

/// Stands in for AVPlayer: records what the player asked for and lets a test fire engine events.
@MainActor
final class FakePlaybackEngine: PlaybackEngine {
    struct Load {
        let stream: ResolvedStream
        let startAt: TimeInterval
        let autoplay: Bool
    }

    var onTick: (@MainActor (TimeInterval, Bool) -> Void)?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    var position: TimeInterval = 0

    private(set) var loads: [Load] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var seeks: [TimeInterval] = []
    private(set) var unloadCount = 0
    /// Every output device the mixer asked for, in order; nil is the system default.
    private(set) var outputDevices: [String?] = []

    struct FallbackLevel: Equatable {
        let volume: Float
        let muted: Bool
    }
    /// Every volume and mute the mixer asked the player to fall back to, in order.
    private(set) var fallbackLevels: [FallbackLevel] = []

    func load(_ stream: ResolvedStream, startAt: TimeInterval, autoplay: Bool) {
        loads.append(Load(stream: stream, startAt: startAt, autoplay: autoplay))
    }

    func setOutputDevice(uid: String?) { outputDevices.append(uid) }
    func setFallbackLevel(volume: Float, muted: Bool) { fallbackLevels.append(FallbackLevel(volume: volume, muted: muted)) }

    func play() { playCount += 1 }
    func pause() { pauseCount += 1 }
    func seek(to seconds: TimeInterval) { seeks.append(seconds) }
    func unload() { unloadCount += 1 }

    func emit(_ event: PlaybackEngineEvent) { onEvent?(event) }
    func tick(_ position: TimeInterval, playing: Bool) {
        self.position = position
        onTick?(position, playing)
    }
}

/// Stands in for MPNowPlayingInfoCenter and MPRemoteCommandCenter: records what the controller asked for.
@MainActor
final class FakeNowPlayingSurface: NowPlayingSurface {
    struct Published {
        let info: [String: Any]
        let isPlaying: Bool

        var title: String? { info[MPMediaItemPropertyTitle] as? String }
        var elapsed: Double? { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double }
        var duration: Double? { info[MPMediaItemPropertyPlaybackDuration] as? Double }
        var rate: Double? { info[MPNowPlayingInfoPropertyPlaybackRate] as? Double }
    }

    private(set) var published: [Published] = []
    private(set) var clearCount = 0
    private(set) var registerCount = 0
    private(set) var removeCount = 0
    private var handler: (@MainActor (NowPlayingCommand) -> Void)?

    var last: Published? { published.last }
    var hasCommands: Bool { handler != nil }

    func setInfo(_ info: [String: Any], isPlaying: Bool) {
        published.append(Published(info: info, isPlaying: isPlaying))
    }

    func clearInfo() { clearCount += 1 }

    func registerCommands(_ handler: @escaping @MainActor (NowPlayingCommand) -> Void) {
        registerCount += 1
        self.handler = handler
    }

    func removeCommands() {
        removeCount += 1
        handler = nil
    }

    /// What a media key press does.
    func send(_ command: NowPlayingCommand) { handler?(command) }
}

nonisolated enum MusicSamples {
    static func track(
        _ id: String = "vid1",
        title: String = "Song",
        artist: String = "Artist",
        seconds: Int? = 200,
        albumBrowseId: String? = nil,
        setVideoId: String? = nil
    ) -> Deci.MusicTrack {
        var track = Deci.MusicTrack(videoId: id, title: title, artist: artist, album: nil, durationSeconds: seconds, thumbnailURL: nil)
        track.albumBrowseId = albumBrowseId
        track.playlistSetVideoId = setVideoId
        return track
    }

    static func playlistOption(_ id: String, title: String? = nil, contains: Bool = false) -> MusicPlaylistOption {
        MusicPlaylistOption(playlistId: id, title: title ?? "Playlist \(id)", thumbnailURL: nil, containsVideo: contains)
    }

    static func tracks(_ ids: String...) -> [Deci.MusicTrack] {
        ids.map { track($0, title: "Song \($0)") }
    }

    static func collection(
        _ browseId: String,
        kind: MusicCollection.Kind = .playlist,
        title: String? = nil,
        subtitle: String = "Playlist",
        artistLinks: [MusicArtistLink] = [],
        audioPlaylistId: String? = nil
    ) -> MusicCollection {
        MusicCollection(
            browseId: browseId,
            kind: kind,
            title: title ?? "Title \(browseId)",
            subtitle: subtitle,
            thumbnailURL: nil,
            artistLinks: artistLinks,
            audioPlaylistId: audioPlaylistId
        )
    }

    static func collections(_ ids: String...) -> [MusicCollection] {
        ids.map { collection($0) }
    }

    static func shelf(_ title: String, _ ids: String...) -> MusicShelf {
        MusicShelf(title: title, items: ids.map { .collection(collection($0)) })
    }

    static func page(
        _ browseId: String,
        tracks: [Deci.MusicTrack] = [],
        continuation: String? = nil,
        title: String = "Page",
        shelves: [MusicShelf] = [],
        isEditable: Bool = false
    ) -> MusicBrowsePage {
        MusicBrowsePage(
            browseId: browseId,
            title: title,
            subtitle: nil,
            thumbnailURL: nil,
            tracks: tracks,
            continuation: continuation,
            shelves: shelves,
            isEditable: isEditable
        )
    }

    static func stream(
        videoId: String = "vid1",
        expiresAt: Date = Date(timeIntervalSinceNow: 6 * 3600),
        trackingURL: URL? = URL(string: "https://music.example.test/stats?ev=1"),
        watchtimeURL: URL? = nil,
        duration: Double? = 200,
        viewCount: Int? = nil
    ) -> ResolvedStream {
        ResolvedStream(
            videoId: videoId,
            url: URL(string: "https://media.example.test/\(videoId).m4a")!,
            itag: 140,
            durationSeconds: duration,
            expiresAt: expiresAt,
            playbackTrackingURL: trackingURL,
            watchtimeTrackingURL: watchtimeURL,
            viewCount: viewCount,
            httpHeaders: ["User-Agent": "test-agent"]
        )
    }

    static func cookie(_ name: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: "v", .domain: domain, .path: "/"])!
    }
}
