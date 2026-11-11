// Deci/Music/MusicService.swift
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "Music")

/// Sign-in, search, the radio queue and playback for the Music tab. Everything network-facing goes through `MusicBackend`.
@MainActor
@Observable
final class MusicService {
    enum AuthState: Equatable {
        case unknown, signedOut, signingIn, signedIn
    }

    /// Opens the sign-in UI and reports the harvested cookies, or nil when the user closed it.
    typealias SignInPresenter = @MainActor (_ completion: @escaping @MainActor ([StoredCookie]?) -> Void) -> Void
    /// Opens the channel picker on the current session and reports the cookies under the picked
    /// channel, or nil when the user closed it without picking.
    typealias ChannelPickerPresenter = @MainActor (
        _ session: [StoredCookie],
        _ completion: @escaping @MainActor ([StoredCookie]?) -> Void
    ) -> Void
    /// Waits for `seconds`. A test replaces it, to run the wait before a disliked song is skipped at once or by hand.
    typealias Sleep = @MainActor (TimeInterval) async -> Void

    private(set) var authState: AuthState = .unknown
    /// Whether plays (and so History) land on a brand channel; nil until the home page says.
    private(set) var isBrandChannel: Bool?
    private(set) var isSwitchingChannel = false
    /// Who the session is signed in as, for the account card; nil until the account menu answers.
    private(set) var account: MusicAccount?
    /// The sign-in window is open to add another Google account on top of the current session.
    private(set) var isAddingAccount = false
    var query = ""
    private(set) var results: [MusicTrack] = []
    /// The artists the search found, best match first, for the shelf above the songs. Never more than
    /// `maxArtistResults`; empty when the artists search found none or failed.
    private(set) var artistResults: [MusicCollection] = []
    /// The albums the search found: the owner's own matching albums and playlists first, then the public albums, best
    /// match first. The public ones never pass `maxAlbumResults`; empty when none matched or the albums search failed
    /// and the library held nothing.
    private(set) var albumResults: [MusicCollection] = []
    private(set) var isSearching = false
    /// One short human line for the UI; never contains cookies or URLs.
    private(set) var lastError: String?
    let player: MusicPlayer
    /// What plays next: the tapped track, then the radio's tracks as they arrive, or a page's tracks in page order.
    private(set) var queue = MusicQueue() {
        didSet {
            reconcilePreload()
            askForQueueLengths()
        }
    }
    /// Home, Library, History and the pages opened from them.
    let browse: MusicBrowseStore
    /// Synced lyrics of the playing track, for the lyrics panel.
    let lyrics: MusicLyricsStore
    /// The song actions (save to playlist, remove from playlist) and their notice line.
    let trackActions: MusicTrackActionsStore
    /// The like state of the songs played this session, for the Like and Dislike buttons and shortcuts.
    let likes: MusicLikeStore
    /// The songs YouTube Music suggests next to a song, for the Related panel.
    let related: MusicRelatedStore
    /// What Deci knows about one song, for the Song data panel.
    let songData: MusicSongDataStore
    /// The artists, playlists, albums and songs pinned to the top of Home. Remembered across launches, and kept
    /// through sign-out and account switches: they belong to the app, not to an account.
    let pinnedItems: MusicPinnedItems
    /// The downloaded songs, which play from their files. Nil in a service built without them (a preview, most tests).
    let downloads: MusicDownloadService?
    /// Whether the network is reachable. Nil in a service built without it (a preview, most tests): always online.
    @ObservationIgnored private let connectivity: MusicConnectivity?
    @ObservationIgnored private let mixFlags: MusicMixFlagStore?
    /// The settings the parked plan was last checked against (see `syncCrossfade`).
    @ObservationIgnored private var syncedSettings: ReplanSettings?
    /// Bumped by every mix flag change. Read by `mixItems`, so a menu built in a view body is built again after a pick.
    private var mixRevision = 0
    /// The network is gone. Observable: the views that read it redraw when it goes and when it returns.
    var isOffline: Bool {
        guard let connectivity else { return false }
        return !connectivity.isOnline
    }
    /// Next is on while a track follows. At the last track it stays on when something can still follow: Loop playlist
    /// wraps to the first track, a page waits for its next page or the radio that is loading, and Autoplay (with Loop
    /// playlist off) plays the staged radio or asks for a new one. A mix that can still grow always has more. With Autoplay
    /// off a radio queue has only the songs the listener queued: its radio is parked.
    var canGoNext: Bool {
        // Offline only a downloaded song can follow, and nothing is coming from the network: the queue ends at the last one
        // (Loop playlist starts it over from the first).
        if isOffline {
            if queue.hasNext(where: canPlayNow) { return true }
            return loopMode == .playlist && queue.tracks.contains(where: canPlayNow)
        }
        if queue.hasNext { return true }
        if queue.isEmpty { return false }
        if queue.mixHasMore { return true }
        if loopMode == .playlist { return true }
        if queue.isPage, queue.continuation != nil { return true }
        return isAutoplayOn && (isFillingQueue || queue.continuation != nil || !queue.autoplay.isEmpty || queue.refillSeed != nil)
    }
    /// A queue page or a radio is loading, or about to be asked for again: Up next shows that more is on its way.
    private(set) var isFillingQueue = false
    /// The queue plays in a shuffled order. Remembered across launches.
    private(set) var isShuffleOn: Bool {
        didSet { reconcilePreload() }
    }
    /// The shuffle is Mix: the songs after the playing one are ordered to blend into each other. `isShuffleOn` is true
    /// then too. Remembered across launches.
    private(set) var isMixOn = false
    /// What the shuffle button is set to.
    var shuffleMode: MusicShuffleMode { isMixOn ? .mix : MusicShuffleMode(shuffle: isShuffleOn) }
    /// How each song in Up next is reached in Mix, by `MusicMixPairInfo.key(from:to:)`. Only pairs whose two songs have a
    /// stored analysis row are here; empty outside Mix.
    private(set) var mixPairs: [String: MusicMixPairInfo] = [:]
    /// Tier 4b: the style of the last transition that was applied. The picker never repeats it, and the first Up next glyph
    /// is chosen against it.
    private(set) var lastAppliedStyle: MusicTransitionStyle?
    /// Tier 4c: the rate the playing deck keeps for its whole song (the applied Mix plan's incoming rate; 1 after a skip, a
    /// load or a plain start). Read from the engine, which resets it on every one of those, so it cannot go stale.
    var activeDeckRate: Double { player.deckRate }
    /// What happens when a track or the queue ends. Remembered across launches.
    private(set) var loopMode: MusicLoopMode {
        didSet { reconcilePreload() }
    }
    /// Keep playing recommended songs after a playlist or an album has finished. Remembered across launches.
    private(set) var isAutoplayOn: Bool {
        didSet { reconcilePreload() }
    }
    /// Fade the next song in over the end of the playing one; off is the gapless switch. Remembered across launches.
    private(set) var isCrossfadeOn: Bool {
        didSet { reconcilePreload() }
    }
    /// Told whenever Deci's own player starts or stops playing (not on every state change).
    @ObservationIgnored var onNativePlayingChange: (@MainActor (Bool) -> Void)?
    /// Told when a tap turns Like or Dislike on for the song playing now, as its state flips and before YouTube Music
    /// answers. A song that is not playing, and the removal of a rating, are not told. The like animation plays on it.
    @ObservationIgnored var onRatingBurst: (@MainActor (MusicRateBurst.Kind) -> Void)?
    /// Told, with the kind, when a tap takes the playing song's Like or Dislike away and no burst replaces it, as its
    /// state flips. The pill shows the removal, which also replaces a burst of that kind still playing. A song that is not
    /// playing is not told.
    @ObservationIgnored var onRatingRemoval: (@MainActor (MusicRateBurst.Kind) -> Void)?
    /// Told, with the kind, when a rating YouTube Music did not take goes back, so a burst or removal of that kind still
    /// showing is cut short. A song that is not playing is not told.
    @ObservationIgnored var onRatingBurstCancel: (@MainActor (MusicRateBurst.Kind) -> Void)?
    /// Told, with its words, when adding an account or switching the channel failed. The old session stays, so these are
    /// not `lastError`, which belongs to the signed-out screen and marks a search as failed. The app shows them where the
    /// listener is looking, the Music popup's notice line or else the HUD (`MusicOutcomeReporter`). The words hold no
    /// cookies and no URLs. Without a listener the failure shows nowhere.
    @ObservationIgnored var onAccountFailure: (@MainActor (String) -> Void)?

    /// One playback session: one CPN, one listening-time count, one playback ping and, when the stream has a
    /// watchtime URL, the watchtime pings with the same CPN: one with the playback ping, one per 40 s of playing
    /// after it, one on each pause, and a final one when the session ends.
    private struct Session {
        let cpn: String
        /// When the session began: the `rt` of its watchtime pings counts from here.
        let startedAt: Date
        var trackingURL: URL?
        var watchtimeURL: URL?
        var accumulator = PlaybackTimeAccumulator()
        var watchtime = WatchtimeTracker()
        /// The song the session plays and its length, for the local listening count.
        var videoId: String?
        var durationSeconds: TimeInterval?
        /// The account behind the ping URLs expired: no ping is sent or attached for this session, but it keeps counting
        /// what the listener hears for the local listening history.
        var pingsDropped = false
    }

    private enum Direction { case forward, backward }

    /// An advance the queue could not make because the radio or the page may still add tracks: it waits for the next page.
    private enum PendingAdvance {
        /// The track played to its end.
        case ended
        /// The listener pressed Next.
        case skipped
        /// The stream died and cannot be recovered.
        case failed
    }

    /// How many artists the search shelf shows: one row of tiles, not a second list.
    static let maxArtistResults = 6
    /// How many public albums the search lists: one row of tiles, like the artists.
    static let maxAlbumResults = 6
    /// Previous restarts the track instead of going back once it has played this long.
    private static let restartThreshold: TimeInterval = 3
    /// Consecutive tracks that may fail before playback stops with an error.
    private static let maxFailures = 3
    /// The next track's stream is resolved this long before the current one ends.
    private static let prefetchLead: TimeInterval = 15
    /// The next song is resolved and analysed as soon as it has been the same next song this long, so a run of Next
    /// presses does not fetch every song flicked past.
    static let analysisSettle: TimeInterval = 1
    /// A beat mix can start up to a phrase plus its 8-bar overlap before the trimmed end: its window opens this early
    /// (the next song is analysed from the moment it is next, so its file is cached and analysed long before).
    static let beatLead: TimeInterval = 70
    /// The engine needs about this long to park, preroll and arm the next song: a beat mix starts no sooner than this
    /// after the plan is made, and a song that is not parked this long before the mix point is mixed the smart way.
    static let beatPrerollLead: TimeInterval = 8
    /// With less than this left to the trimmed end the next song is offered with whatever analysis it has (scheduleWindow
    /// 6 s plus a 4 s preroll margin): waiting for its analysis stops here (tier 2b).
    static let analysisDeadline: TimeInterval = 10
    /// How long the crossfade of a manual skip onto the preloaded track lasts.
    static let quickFadeSeconds: TimeInterval = 0.3
    /// Radio pages overlap, so a page can add nothing new. This many in a row ends a top-up.
    private static let maxEmptyPages = 3
    /// A queue page that failed for a reason that may pass (network, 5xx) is asked for again this many times, each
    /// wait twice the last, before the queue waits for the next track change.
    private static let maxQueueRetries = 3
    /// While a song plays its place is saved this often, on the player's own position ticks.
    private static let sessionSaveInterval: TimeInterval = 10

    @ObservationIgnored private let backend: any MusicBackend
    @ObservationIgnored private let presentSignIn: SignInPresenter
    @ObservationIgnored private let presentChannelPicker: ChannelPickerPresenter
    @ObservationIgnored private let closeSignInWindow: @MainActor () -> Void
    @ObservationIgnored private let raiseSignInWindow: @MainActor () -> Void
    @ObservationIgnored private let nowPlaying: NowPlayingController
    /// The clock the watchtime schedule and `lact` read.
    @ObservationIgnored private let now: () -> Date
    /// How long a search waits for the artists after the songs have landed. Past it the songs show alone.
    @ObservationIgnored private let artistGrace: Duration
    /// The wait before the first retry of a queue page that failed; each later retry waits twice as long.
    @ObservationIgnored private let queueRetryDelay: Duration
    /// The wait before a disliked song is skipped.
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private var queueRetryAttempts = 0
    /// When the listener last touched a control: the `lact` of every watchtime ping.
    @ObservationIgnored private var lastActivity: Date
    /// The player volume (0 to 100) and mute the watchtime pings report: the Mixer tab's music player row (shown as Deci).
    @ObservationIgnored private let listenerLevel: @MainActor () -> (volume: Int, muted: Bool)
    /// Told the three playback options whenever one changes, so the app can keep them in settings.
    @ObservationIgnored private let savePreferences: @MainActor (MusicPlaybackPreferences) -> Void
    /// The fade length as Settings has it right now, read when a transition is planned. Nil: the length the service started with.
    @ObservationIgnored private let liveCrossfadeSeconds: (@MainActor () -> Double)?
    @ObservationIgnored private var startingCrossfadeSeconds: Double
    /// Settings' beat-matched transitions switch, read live when the service is wired to settings.
    @ObservationIgnored private let liveBeatMix: (@MainActor () -> Bool)?
    @ObservationIgnored private var startingBeatMix: Bool
    @ObservationIgnored private let liveVocalGuard: (@MainActor () -> Bool)?
    @ObservationIgnored private let startingVocalGuard: Bool
    /// Settings' DJ-length songs switch, read live when the service is wired to settings.
    @ObservationIgnored private let liveDJLength: (@MainActor () -> Bool)?
    @ObservationIgnored private let startingDJLength: Bool
    /// The songs that really played before the current one (they passed the play-count point), newest last, at most
    /// `MusicDJLength.runSongs - 1`: with the playing song they are the run whose energy the DJ-length rule reads.
    @ObservationIgnored private var playedRun: [String] = []
    /// The energy rating of the songs of the run, kept when their row arrives: the row mirror drops a song once it is left.
    @ObservationIgnored private var songEnergy: [String: Float] = [:]
    @ObservationIgnored private let vocalLookahead: MusicVocalLookahead?
    /// The incoming song a beat mix was given up for (it was not parked in time): its transition is planned the smart
    /// way from then on. Forgotten when the track changes.
    @ObservationIgnored private var beatFallbackFor: String?
    /// True while a settings reset puts the options back: the file was cleared already, so nothing is written.
    @ObservationIgnored private var holdsPreferences = false
    @ObservationIgnored private var shuffleGenerator: MusicShuffleGenerator
    @ObservationIgnored private var session: Session? {
        // Every way a session ends (track change, crossfade flip, skip, stop, sign-out, quit) replaces or clears it.
        didSet {
            if let ended = oldValue, ended.cpn != session?.cpn { noteListening(of: ended) }
        }
    }
    /// The local per-song listening history; nil (a test's default) keeps none.
    @ObservationIgnored private let listening: (any MusicListeningRecording)?
    @ObservationIgnored private var direction = Direction.forward
    @ObservationIgnored private var failureStreak = 0
    @ObservationIgnored private var pendingAdvance: PendingAdvance?
    /// Why the last stream refresh failed; read when the player then gives up on the track.
    @ObservationIgnored private var refreshError: (any Error)?
    @ObservationIgnored private var nativePlaying = false
    @ObservationIgnored private var radioGeneration = 0
    @ObservationIgnored private var prefetchAttempt: String?
    /// The video id last handed to the player as the preload; nil when none is out. One offer per track and window.
    @ObservationIgnored private var preloadOffered: String?
    @ObservationIgnored private var prefetched: ResolvedStream?
    /// The song whose early resolve failed and has not been tried again: the preload window tries it once more.
    @ObservationIgnored private var resolveFailed: String?
    /// The song whose resolve was already retried once; a second failure is left to the playback path.
    @ObservationIgnored private var resolveRetried: String?
    /// The song whose near-expiry stream was already replaced once, so a short-lived answer is not asked for every tick.
    @ObservationIgnored private var expiryRefreshed: String?
    /// History pings earned and not yet sent. One drain task sends them one at a time, in the order they were earned.
    @ObservationIgnored private var pendingPings: [HistoryPing] = []
    @ObservationIgnored private var isSendingPings = false
    /// Bumped when the pings are dropped (sign-out, account swap): a drain from before it sends nothing more.
    @ObservationIgnored private var reportGeneration = 0

    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
    @ObservationIgnored private(set) var playTask: Task<Void, Never>?
    @ObservationIgnored private(set) var signInTask: Task<Void, Never>?
    @ObservationIgnored private(set) var reportTask: Task<Void, Never>?
    /// The background fetch of a downloaded song's ping URLs, which the song's file does not have; nil when none runs.
    /// Read by the tests, which await it.
    @ObservationIgnored private(set) var trackingTask: Task<Void, Never>?
    @ObservationIgnored private(set) var signOutTask: Task<Void, Never>?
    @ObservationIgnored private(set) var identityTask: Task<Void, Never>?
    @ObservationIgnored private(set) var channelSwitchTask: Task<Void, Never>?
    @ObservationIgnored private(set) var accountTask: Task<Void, Never>?
    @ObservationIgnored private(set) var addAccountTask: Task<Void, Never>?
    /// The wait before the song that was just disliked is skipped, and the skip that follows it; nil until a dislike has
    /// scheduled one. A newer dislike replaces it. Read by the tests, which await it.
    @ObservationIgnored private(set) var dislikeSkip: Task<Void, Never>?
    /// The radio or page fetch in flight (first radio page or a continuation); nil when none is running.
    @ObservationIgnored private(set) var radioTask: Task<Void, Never>? {
        didSet {
            if radioTask == nil { pageRadioSeed = nil }
            noteQueueFilling()
        }
    }
    /// The song the radio in flight follows a playlist or album page after; nil when none is, or the fetch is of another
    /// kind. A shuffle or an edit that moves the page's last own song makes it stale (see `dropStaleRadio`).
    @ObservationIgnored private var pageRadioSeed: String?
    /// The wait before a failed queue page is asked for again; nil when no retry is due.
    @ObservationIgnored private(set) var queueRetryTask: Task<Void, Never>? {
        didSet { noteQueueFilling() }
    }
    @ObservationIgnored private(set) var prefetchTask: Task<Void, Never>?

    // Song analysis and the track cache (tier 2a P3). Nil provider: none of this runs and playback is as in tier 1.
    private let analysis: (any MusicAnalysisProviding)?
    /// The analysis job for the next song (fetch, analyse, keep the file); nil when none runs. Read by the tests.
    @ObservationIgnored private(set) var analysisTask: Task<Void, Never>?
    /// The releases and discards sent to the provider, in order, one after another. Read by the tests.
    @ObservationIgnored private(set) var analysisCleanupTask: Task<Void, Never>?
    /// The song `analysisTask` works for.
    @ObservationIgnored private var analysisTarget: String?
    /// The job number of `analysisTarget`'s job.
    @ObservationIgnored private var analysisTargetJob = 0
    /// Jobs whose analysis is running now (job number to song). A job whose song stopped being next is left to finish.
    @ObservationIgnored private var analysisRunning: [Int: String] = [:]
    /// Every job that has not landed yet, running or waiting its turn, so sign-out can cancel the ones left running.
    @ObservationIgnored private var analysisJobs: [Int: (id: String, task: Task<Void, Never>)] = [:]
    /// The last job started: the next one waits behind it. A drop never clears it, so two fetches never overlap.
    @ObservationIgnored private var analysisTail: Task<Void, Never>?
    /// The song that has been next since `since`, for the settle before it is resolved and analysed early.
    @ObservationIgnored private var nextSeen: (id: String, since: Date)?
    /// Songs whose cache file this service asked for and has not released or discarded yet.
    @ObservationIgnored private var heldCacheJobs: [String: Int] = [:]
    /// Counts the analysis jobs started; a job's number tells it apart from an older one for the same song.
    @ObservationIgnored private var analysisJobCounter = 0
    /// The next song's cache file once its analysis is stored, so the preload can play from it.
    @ObservationIgnored private var cachedFile: (videoId: String, url: URL)?
    /// The song the player is on, as far as the cache is concerned.
    @ObservationIgnored private var analysisCurrentID: String?
    /// The analysis job for the song that is playing (it had no fresh entry); nil when none runs. Read by the tests.
    @ObservationIgnored private(set) var currentAnalysisTask: Task<Void, Never>?
    /// The song `currentAnalysisTask` was started for, and the last one asked: a song is asked for once.
    @ObservationIgnored private var currentAnalysisAsked: String?

    // Transition plans (tier 2b P3). Nil reader: every transition is planned from no analysis, as in tier 1.
    private let analysisReader: (any MusicAnalysisReading)?
    /// The stored rows of the song that plays and the next one (raw: freshness is judged against each song's stream when
    /// a plan is built). Filled by async reads, evicted when the song changes. Read by the tests.
    @ObservationIgnored private(set) var transitionAnalyses: [String: MusicAnalysis] = [:]
    /// The read of the playing song's row. Read by the tests.
    @ObservationIgnored private(set) var transitionReadTask: Task<Void, Never>?
    /// The song whose analysis job has finished and whose row was read (so nothing is left to wait for).
    @ObservationIgnored private var nextRowSettled: String?
    /// The plan handed to the engine for the current preload, with the inputs it was built from (frozen: a late row never
    /// changes them) and the songs whose fresh row was part of it.
    @ObservationIgnored private var offeredPlan: OfferedPlan?
    /// The transition log lines the service wrote, newest last (ids only). Read by the tests.
    @ObservationIgnored private(set) var transitionLines: [String] = []

    private struct OfferedPlan {
        var inputs: MusicTransitionInputs
        var plan: TransitionPlan
        var plannedWithRows: Set<String>
        var late = false
    }

    // The remembered session (see `MusicSessionSnapshot`). Nil store: the service remembers nothing.
    @ObservationIgnored private let sessionStore: MusicSessionStore?
    /// The signed-in channel's key, the owner of every snapshot written; nil until `backend.sessionIdentity()` answers
    /// and while signed out. Nothing is written without it.
    @ObservationIgnored private var sessionChannelKey: String?
    @ObservationIgnored private(set) var sessionKeyTask: Task<Void, Never>?
    @ObservationIgnored private(set) var restoreTask: Task<Void, Never>?
    /// The auth check started at creation, so a restore at launch waits for it instead of asking twice.
    @ObservationIgnored private var authRefreshTask: Task<Void, Never>?
    /// The song the last launch left, from the restore until the listener first touches a control. While set nothing is
    /// saved: a session that was only put back has not been listened to, and must not run its hour again.
    @ObservationIgnored private var restoredVideoId: String?
    /// The last snapshot handed to the store, so a tick that changes nothing writes nothing.
    @ObservationIgnored private var lastSavedSession: MusicSessionSnapshot?
    /// Set when the app quits: the file stays as the quit left it, whatever the shutdown does to the queue.
    @ObservationIgnored private var sessionClosed = false
    @ObservationIgnored private var lastPeriodicSave = Date.distantPast
    @ObservationIgnored private var wasPlaying = false

    @ObservationIgnored private var searchGeneration = 0
    /// The search that was asked for while offline, or cut by the network going: it runs once, when the network returns.
    /// Clearing the query forgets it.
    @ObservationIgnored private var deferredSearch: String?
    @ObservationIgnored private var playGeneration = 0
    /// Each account fetch names itself with the next number and only lands while it is still the latest,
    /// so a slower earlier one, or one that left before a sign-out, can never fill in the wrong account.
    @ObservationIgnored private var accountGeneration = 0
    /// Names the current "use another account" window; a pick from an older one is ignored.
    @ObservationIgnored private var addAccountGeneration = 0
    #if DEBUG
    @ObservationIgnored private var memoryProbe: Task<Void, Never>?
    #endif

    init(
        backend: any MusicBackend,
        player: MusicPlayer = MusicPlayer(),
        presentSignIn: @escaping SignInPresenter = { MusicSignInWindowController.present(completion: $0) },
        presentChannelPicker: @escaping ChannelPickerPresenter = {
            MusicSignInWindowController.presentChannelPicker(session: $0, completion: $1)
        },
        closeSignInWindow: @escaping @MainActor () -> Void = { MusicSignInWindowController.cancelActive() },
        raiseSignInWindow: @escaping @MainActor () -> Void = { MusicSignInWindowController.bringToFront() },
        nowPlaying: NowPlayingController = NowPlayingController(),
        // Offline unless the caller says otherwise: only the app's own wiring (MusicServiceHost) passes
        // `MusicLyricsStore.live()`, so a service built by a test or a preview never reaches a lyrics server.
        lyrics: MusicLyricsStore = MusicLyricsStore(provider: NoLyricsProvider()),
        now: @escaping () -> Date = Date.init,
        listenerLevel: @escaping @MainActor () -> (volume: Int, muted: Bool) = { (WatchtimeTracker.fullVolume, false) },
        preferences: MusicPlaybackPreferences = MusicPlaybackPreferences(),
        savePreferences: @escaping @MainActor (MusicPlaybackPreferences) -> Void = { _ in },
        crossfadeSeconds: (@MainActor () -> Double)? = nil,
        beatMix: (@MainActor () -> Bool)? = nil,
        vocalGuard: (@MainActor () -> Bool)? = nil,
        djLength: (@MainActor () -> Bool)? = nil,
        pinnedItems: [MusicPinnedItem] = [],
        savePinnedItems: @escaping @MainActor ([MusicPinnedItem]) -> Void = { _ in },
        // A fixed seed makes every shuffle repeatable; without one each launch shuffles differently.
        shuffleSeed: UInt64? = nil,
        artistGrace: Duration = .milliseconds(1500),
        queueRetryDelay: Duration = .seconds(2),
        sleep: @escaping Sleep = { seconds in try? await Task.sleep(for: .seconds(seconds)) },
        // Where the session is remembered between launches; nil (a test's default) remembers nothing.
        sessionStore: MusicSessionStore? = nil,
        downloads: MusicDownloadService? = nil,
        connectivity: MusicConnectivity? = nil,
        refreshOnCreate: Bool = true,
        analysis: (any MusicAnalysisProviding)? = nil,
        analysisReader: (any MusicAnalysisReading)? = nil,
        // The listener's "do not mix" flags; nil (a test's default) means nothing is flagged.
        mixFlags: MusicMixFlagStore? = nil,
        listening: (any MusicListeningRecording)? = nil,
        // 3d-4: sung intervals from synced lyrics for the vocal guard; nil (a test's default) keeps the structural proxy.
        vocalLookahead: MusicVocalLookahead? = nil
    ) {
        self.vocalLookahead = vocalLookahead
        self.mixFlags = mixFlags
        self.listening = listening
        self.analysis = analysis
        self.analysisReader = analysisReader
        self.backend = backend
        self.connectivity = connectivity
        let browse = MusicBrowseStore(backend: backend, connectivity: connectivity, downloads: downloads)
        self.browse = browse
        self.trackActions = MusicTrackActionsStore(backend: backend, browse: browse)
        self.likes = MusicLikeStore(backend: backend)
        self.related = MusicRelatedStore(backend: backend, browse: browse)
        self.songData = MusicSongDataStore(backend: backend)
        self.lyrics = lyrics
        self.pinnedItems = MusicPinnedItems(items: pinnedItems, save: savePinnedItems)
        self.downloads = downloads
        self.player = player
        self.presentSignIn = presentSignIn
        self.presentChannelPicker = presentChannelPicker
        self.closeSignInWindow = closeSignInWindow
        self.raiseSignInWindow = raiseSignInWindow
        self.nowPlaying = nowPlaying
        self.now = now
        self.artistGrace = artistGrace
        self.queueRetryDelay = queueRetryDelay
        self.sleep = sleep
        self.sessionStore = sessionStore
        self.listenerLevel = listenerLevel
        self.isShuffleOn = preferences.shuffle
        self.isMixOn = preferences.shuffle && preferences.mixShuffle
        self.loopMode = preferences.loop
        self.isAutoplayOn = preferences.autoplay
        self.isCrossfadeOn = preferences.crossfade
        self.startingCrossfadeSeconds = preferences.crossfadeSeconds
        self.liveCrossfadeSeconds = crossfadeSeconds
        self.startingBeatMix = preferences.beatMix
        self.liveBeatMix = beatMix
        self.startingVocalGuard = preferences.vocalGuard
        self.liveVocalGuard = vocalGuard
        self.startingDJLength = preferences.djLength
        self.liveDJLength = djLength
        self.savePreferences = savePreferences
        self.shuffleGenerator = MusicShuffleGenerator(seed: shuffleSeed ?? UInt64.random(in: .min ... .max))
        self.lastActivity = now()
        // The lyrics panel ignores ticks while it is hidden, so it asks for one fresh reading when it comes back.
        lyrics.playbackSampler = { [player] in (player.currentTime, player.isPlaying) }
        // The ticks come every half second; while the lyrics are on screen they follow the engine's own clock.
        lyrics.livePosition = { [player] in player.livePosition() }
        player.onTick = { [weak self] position, isPlaying in
            self?.handlePlaybackTick(position: position, isPlaying: isPlaying)
        }
        player.onNeedsFreshStream = { [weak self] track in
            guard let self else { throw CancellationError() }
            return try await self.resolveFreshStream(for: track)
        }
        player.onEnded = { [weak self] in self?.handleTrackEnded() }
        player.onFailed = { [weak self] in self?.handlePlayerFailure() }
        player.onAdvanced = { [weak self] track in self?.handleAdvanced(to: track) ?? false }
        player.onStateChange = { [weak self] in self?.playerStateChanged() }
        player.onLocalFileChange = { [weak self] videoId in self?.downloads?.noteLocalPlayback(of: videoId) }
        nowPlaying.onCommand = { [weak self] command in self?.handleRemote(command) }
        browse.onSessionExpired = { [weak self] in self?.browseSessionExpired() }
        trackActions.onSessionExpired = { [weak self] in self?.browseSessionExpired() }
        likes.onSessionExpired = { [weak self] in self?.browseSessionExpired() }
        related.onSessionExpired = { [weak self] in self?.browseSessionExpired() }
        songData.onSessionExpired = { [weak self] in self?.browseSessionExpired() }
        songData.sources = MusicSongDataStore.Sources(
            heldStream: { [weak self] id in self?.heldStream(for: id) },
            analysis: { [weak self] id in await self?.storedAnalysis(for: id) },
            isOffline: { [weak self] in self?.isOffline ?? false },
            listening: { [weak self] id in await self?.listening?.entry(for: id) }
        )
        likes.onRatingShown = { [weak self] videoId, status, previous in
            self?.ratingShown(videoId: videoId, status: status, previous: previous)
        }
        likes.onRatingRolledBack = { [weak self] videoId, shown in
            self?.ratingRolledBack(videoId: videoId, shown: shown)
        }
        browse.onPageLoaded = { [weak self] page, opener in self?.pageLoaded(page, opener: opener) }
        // Signed out the store shows the downloads only, like it does with the network down.
        browse.accountGone = { [weak self] in self?.authState == .signedOut }
        connectivity?.observe { [weak self] online in self?.connectivityChanged(online) }
        if refreshOnCreate {
            authRefreshTask = Task { [weak self] in await self?.refreshAuth() }
        }
    }

    isolated deinit {
        restoreTask?.cancel()
        sessionKeyTask?.cancel()
        searchTask?.cancel()
        playTask?.cancel()
        signInTask?.cancel()
        identityTask?.cancel()
        channelSwitchTask?.cancel()
        accountTask?.cancel()
        addAccountTask?.cancel()
        dislikeSkip?.cancel()
        radioTask?.cancel()
        queueRetryTask?.cancel()
        prefetchTask?.cancel()
        analysisTask?.cancel()
        currentAnalysisTask?.cancel()
        cancelPreload()
        trackingTask?.cancel()
        #if DEBUG
        memoryProbe?.cancel()
        #endif
    }

    // MARK: - Auth

    func refreshAuth() async {
        let signedIn = await backend.isSignedIn()
        guard authState != .signingIn else { return }
        authState = signedIn ? .signedIn : .signedOut
        if signedIn { didSignIn() }
        radioScanSoon()
    }

    /// A sign-in is in place: the account's details are read, and so is the state of a song that was already playing,
    /// which was skipped while signed out. The downloaded playlists and albums are synced once per launch, from here.
    private func didSignIn() {
        browse.accountReturned()
        // A Related panel that could not ask without the account asks now.
        related.connectionReturned()
        songData.connectionReturned()
        // Offline the account cannot be read: it is, when the network returns (see `connectivityChanged`).
        if !isOffline { refreshIdentity() }
        loadLikeStatus()
        downloads?.signInKnown()
    }

    /// The network came back (going away needs nothing: what is in flight fails on its own, and the stores hold their
    /// failures for the return). What was held back runs now: the search, the account's details, the like state of the
    /// song playing, and the queue's top-up, which asks the radio or the next page that was never asked for.
    private func connectivityChanged(_ online: Bool) {
        guard online else { return networkLost() }
        queueRetryAttempts = 0
        askForQueueLengths()
        related.connectionReturned()
        songData.connectionReturned()
        if deferredSearch != nil { search() }
        if authState == .signedIn {
            if isBrandChannel == nil { refreshChannelIdentity() }
            if account == nil { refreshAccount() }
            if sessionChannelKey == nil { refreshSessionKey() }
            loadLikeStatus()
        }
        topUpQueue()
    }

    /// The network went. A radio or page fetch that is out is cancelled instead of waited out (it would only fail after
    /// the connection's own timeout), and a Next that was parked behind it settles at once: the song plays on, since
    /// nothing is coming. The fetch is asked for again when the network returns (see `connectivityChanged`).
    private func networkLost() {
        // Offline the next track is not a certain one (songs are stepped over): a preload made for it is withdrawn.
        reconcilePreload()
        guard radioTask != nil || queueRetryTask != nil else { return }
        cancelRadio()
        guard !resumePendingAdvance() else { return }
        settlePendingAdvance()
    }

    func signIn() {
        guard authState != .signingIn else { return }
        authState = .signingIn
        lastError = nil
        // A sign-in window left open by "use another account" is the one this reuses: its old pick no longer applies.
        endAddAccount()
        presentSignIn { [weak self] cookies in
            self?.finishSignIn(with: cookies)
        }
    }

    private func finishSignIn(with cookies: [StoredCookie]?) {
        guard let cookies, !cookies.isEmpty else {
            authState = .signedOut
            return
        }
        signInTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.backend.signIn(with: cookies)
                self.authState = .signedIn
                self.didSignIn()
            } catch {
                logger.error("sign-in failed: \(Self.logDescription(of: error), privacy: .public)")
                self.authState = .signedOut
                self.lastError = Self.message(for: error)
            }
        }
    }

    func signOut() {
        queueLengthTask?.cancel()
        queueLengthTask = nil
        cancelWork()
        cancelReport()
        endQueue()
        player.stop()
        session = nil
        results = []
        artistResults = []
        albumResults = []
        query = ""
        lastError = nil
        authState = .signedOut
        identityTask?.cancel()
        channelSwitchTask?.cancel()
        dropSessionKey()
        isBrandChannel = nil
        isSwitchingChannel = false
        clearAccount()
        endAddAccount()
        // An open picker still holds the old session; it must not sign anyone back in.
        closeSignInWindow()
        browse.reset()
        lyrics.reset()
        trackActions.reset()
        likes.reset()
        related.reset()
        songData.reset()
        signOutTask = Task { [backend] in await backend.signOut() }
    }

    // MARK: - Account

    /// The channel identity (History's target) and the account card's data, read together wherever a session starts.
    private func refreshIdentity() {
        refreshChannelIdentity()
        refreshAccount()
        refreshSessionKey()
    }

    /// Reads the account menu for the card. Nothing about it is worth a banner: a failed read leaves
    /// the card on "Signed in", and whatever was loaded before stays.
    private func refreshAccount() {
        accountTask?.cancel()
        accountGeneration += 1
        let generation = accountGeneration
        accountTask = Task { [weak self, backend] in
            let fetched: MusicAccount?
            do {
                fetched = try await backend.accountInfo()
            } catch {
                if !Self.isCancellation(error) {
                    logger.error("account info failed: \(Self.logDescription(of: error), privacy: .public)")
                }
                return
            }
            guard let self, !Task.isCancelled, generation == self.accountGeneration, self.authState == .signedIn else { return }
            self.account = fetched
        }
    }

    /// Forgets the account and drops any fetch still on its way: it belongs to a session that is gone or replaced.
    private func clearAccount() {
        accountTask?.cancel()
        accountTask = nil
        accountGeneration += 1
        account = nil
    }

    /// Opens the Google sign-in window without signing out first. A closed window changes nothing;
    /// a sign-in replaces the session the way a first sign-in does (see `installNewSession`).
    /// While that window is open, calling it again brings the window forward instead of opening another.
    func useAnotherAccount() {
        guard authState == .signedIn else { return }
        if isAddingAccount {
            raiseSignInWindow()
            return
        }
        guard !isSwitchingChannel else { return }
        isAddingAccount = true
        addAccountGeneration += 1
        let generation = addAccountGeneration
        presentSignIn { [weak self] cookies in
            self?.finishAddAccount(with: cookies, generation: generation)
        }
    }

    private func finishAddAccount(with cookies: [StoredCookie]?, generation: Int) {
        guard isAddingAccount, generation == addAccountGeneration else { return }
        guard let cookies, !cookies.isEmpty else {
            isAddingAccount = false
            return
        }
        addAccountTask = Task { [weak self] in
            // A sign-out or a new sign-in since the pick bumps the generation: the pick must not sign anyone back in.
            guard let self, !Task.isCancelled, generation == self.addAccountGeneration else { return }
            var refusal: (any Error)?
            do {
                try await self.backend.signIn(with: cookies)
                guard !Task.isCancelled, generation == self.addAccountGeneration else { return }
                self.installNewSession()
            } catch {
                guard generation == self.addAccountGeneration else { return }
                logger.error("adding an account failed: \(Self.logDescription(of: error), privacy: .public)")
                refusal = error
            }
            self.isAddingAccount = false
            guard let refusal else { return }
            if self.authState == .signedIn {
                self.onAccountFailure?("Couldn't add the account. Still signed in as before.")
            } else {
                // A dead session keeps the window open (see `handle`), so the pick can land on the signed-out screen:
                // there is no old session to have kept, and that screen shows `lastError`.
                self.lastError = Self.message(for: refusal)
            }
        }
    }

    /// The backend now holds the new account's cookies. Everything that belonged to the old one goes: playback
    /// and its queue (a track left playing would keep filing History under the wrong account), the search,
    /// the pages loaded under it and its channel and account details, which are read again.
    private func installNewSession() {
        cancelWork()
        cancelReport()
        stopPlayback(reportFinal: false)
        results = []
        artistResults = []
        albumResults = []
        query = ""
        lastError = nil
        authState = .signedIn
        identityTask?.cancel()
        dropSessionKey()
        isBrandChannel = nil
        browse.reset()
        lyrics.reset()
        trackActions.reset()
        likes.reset()
        related.reset()
        songData.reset()
        clearAccount()
        refreshIdentity()
    }

    /// Closes the books on "use another account": no pick of the current window counts any more.
    private func endAddAccount() {
        addAccountGeneration += 1
        addAccountTask?.cancel()
        isAddingAccount = false
    }

    // MARK: - Channel

    private func refreshChannelIdentity() {
        identityTask?.cancel()
        identityTask = Task { [weak self, backend] in
            let identity = await backend.channelIdentity()
            guard let self, !Task.isCancelled, self.authState == .signedIn else { return }
            self.isBrandChannel = identity
        }
    }

    /// Opens YouTube's channel picker on the current session, so History lands on the channel
    /// picked there. The session stays as it is when the window is closed without a pick.
    /// While the picker is open, calling it again brings the picker forward instead of opening another;
    /// during "use another account" it does nothing, so the two windows never replace each other.
    func switchChannel() {
        guard authState == .signedIn, !isAddingAccount else { return }
        if isSwitchingChannel {
            raiseSignInWindow()
            return
        }
        isSwitchingChannel = true
        channelSwitchTask = Task { [weak self, backend] in
            let cookies = await backend.sessionCookies()
            // A sign-out cancels this and puts the switch away itself; a newer switch may hold the flag by now.
            guard let self, !Task.isCancelled else { return }
            guard self.authState == .signedIn, !cookies.isEmpty else {
                self.isSwitchingChannel = false
                return
            }
            self.presentChannelPicker(cookies) { [weak self] picked in
                self?.finishChannelSwitch(with: picked)
            }
        }
    }

    private func finishChannelSwitch(with cookies: [StoredCookie]?) {
        guard isSwitchingChannel else { return }
        guard let cookies, !cookies.isEmpty, authState == .signedIn else {
            isSwitchingChannel = false
            return
        }
        channelSwitchTask = Task { [weak self] in
            // A sign-out since the pick cancels this and puts the switch away itself; the picked session must not sign back in.
            guard let self, !Task.isCancelled else { return }
            var failed = false
            do {
                try await self.backend.signIn(with: cookies)
                await self.takeUpPickedChannel()
            } catch {
                logger.error("channel switch failed: \(Self.logDescription(of: error), privacy: .public)")
                failed = true
            }
            // A cancel is a sign-out, which has reset the flag, and a newer switch may hold it now: this one touches nothing.
            guard !Task.isCancelled else { return }
            // Every other end of a started switch frees the flag, a dead session included: else Switch channel would
            // only raise a window that is not there after the next sign-in.
            self.isSwitchingChannel = false
            // A sign-out while the pick was going in leaves no session to have kept: the signed-out screen shows.
            if failed, self.authState == .signedIn {
                self.onAccountFailure?("Couldn't switch the channel. Still playing as before.")
            }
        }
    }

    /// The backend holds the picked channel's session: what belonged to the channel left is dropped and read again.
    /// A session that ended meanwhile, by a sign-out or a dead session, takes up nothing.
    private func takeUpPickedChannel() async {
        guard !Task.isCancelled, authState == .signedIn else { return }
        // Stay in "switching" until the new identity is known.
        identityTask?.cancel()
        // The queue keeps playing under the picked channel: its snapshots take that channel's key once it is read.
        dropSessionKey()
        refreshSessionKey()
        isBrandChannel = nil
        // Home and the library belong to the channel: what is loaded is the old one's.
        browse.reset()
        trackActions.reset()
        // The other channel has its own likes: the song playing is read again.
        likes.reset()
        related.reset()
        songData.reset()
        loadLikeStatus()
        // The card shows the channel that was picked, not the one that was left.
        clearAccount()
        refreshAccount()
        let identity = await backend.channelIdentity()
        guard !Task.isCancelled, authState == .signedIn else { return }
        isBrandChannel = identity
    }

    /// Stops playback and pending work, and writes any cookie change still held back to the Keychain.
    /// Called when the app quits.
    func stop() {
        // The session is written, with a fresh time, before the queue is wound up: from here the file is left as it is.
        restoreTask?.cancel()
        saveSession(force: true)
        sessionStore?.flush()
        mixFlags?.flush()
        sessionClosed = true
        cancelWork()
        endQueue()
        // Before the player resets its position; the quit path does not wait for it, as the ping is fire and forget.
        sendFinalPing()
        player.stop()
        session = nil
        listening?.flushNow()
        // The downloads index is written a moment after each song, so a change may still be waiting for its timer.
        downloads?.flushOnQuit()
        backend.flushCookies()
    }

    /// A history ping belongs to the session that earned it. After a sign-out or a swap it has nowhere to go:
    /// its tracking URL is the old account's, and the backend would send it with the new account's cookies.
    /// The pings still waiting are dropped with it, and the session sends no final one: it would have to leave
    /// before the jar is wiped, and the order between the two is not guaranteed.
    private func cancelReport() {
        reportGeneration += 1
        reportTask?.cancel()
        reportTask = nil
        pendingPings = []
        isSendingPings = false
        // A ping URL still on its way is the old account's too.
        trackingTask?.cancel()
        trackingTask = nil
    }

    private func cancelWork() {
        searchGeneration += 1
        playGeneration += 1
        searchTask?.cancel()
        playTask?.cancel()
        searchTask = nil
        playTask = nil
        trackingTask?.cancel()
        trackingTask = nil
        isSearching = false
        deferredSearch = nil
        #if DEBUG
        memoryProbe?.cancel()
        #endif
    }

    // MARK: - Remembered session

    /// Reads the signed-in channel's key. Every snapshot is written under it, so the first one goes out the moment it is
    /// known. A key that cannot be read leaves the old one in place and writes nothing new.
    private func refreshSessionKey() {
        guard sessionStore != nil else { return }
        sessionKeyTask?.cancel()
        sessionKeyTask = Task { [weak self, backend] in
            let key = await backend.sessionIdentity()
            guard let self, !Task.isCancelled, self.authState == .signedIn, let key else { return }
            self.sessionChannelKey = key
            self.saveSession()
        }
    }

    private func dropSessionKey() {
        sessionKeyTask?.cancel()
        sessionKeyTask = nil
        sessionChannelKey = nil
    }

    /// Hands the session as it stands to the store, which writes at most once a second. Nothing is saved while signed out,
    /// before the account is known, or while a restored session is untouched; and only with a song loaded that the queue
    /// is on, so a tick left over from a queue that ended cannot bring its deleted file back. `force` writes even when
    /// nothing changed since the last save, so the quit starts the hour again.
    private func saveSession(force: Bool = false) {
        guard let sessionStore, restoredVideoId == nil, !sessionClosed, authState == .signedIn,
              let key = sessionChannelKey, let current = queue.current,
              player.nowPlaying?.videoId == current.videoId else { return }
        lastPeriodicSave = now()
        let snapshot = MusicSessionSnapshot(
            savedAt: now(), channelKey: key, position: player.hasEnded ? 0 : player.currentTime, queue: queue
        )
        if !force, let last = lastSavedSession, snapshot.hasSameState(as: last) { return }
        sessionStore.save(snapshot)
        lastSavedSession = snapshot
    }

    /// The listener did something: a restored session is theirs from here and is saved again.
    private func touchSession() {
        guard restoredVideoId != nil else { return }
        restoredVideoId = nil
        lastSavedSession = nil
    }

    /// The queue is gone (it ended, playback was stopped, the account left): the file goes with it. Not at quit, where
    /// the queue is wound up after the file was written.
    private func forgetSession() {
        guard !sessionClosed else { return }
        restoredVideoId = nil
        lastSavedSession = nil
        sessionStore?.delete()
    }

    /// Launch path: puts the last session back, paused, when the store still holds a usable one. Waits for the sign-in
    /// check and the account, then resolves the song's stream, and only then changes anything, all at once, so the chip
    /// never shows a song that cannot play. A song the listener starts meanwhile wins (the play generation moves on).
    func restoreSession() {
        guard sessionStore != nil, restoreTask == nil, queue.isEmpty, player.nowPlaying == nil else { return }
        let generation = playGeneration
        restoreTask = Task { [weak self] in
            await self?.runRestore(generation: generation)
        }
    }

    private func runRestore(generation: Int) async {
        guard let sessionStore else { return }
        if authState == .unknown {
            if let refresh = authRefreshTask { await refresh.value } else { await refreshAuth() }
        }
        guard generation == playGeneration, !Task.isCancelled else { return }
        guard authState == .signedIn else {
            sessionStore.delete()
            return
        }
        // Without the account a session cannot be told to be this one's: left on disk for the next launch. With no
        // network the account cannot be read at all: the one session on disk is taken as this one's, and the key is read
        // when the network returns (see `connectivityChanged`).
        var key: String?
        if !isOffline { key = await backend.sessionIdentity() }
        if key == nil, !isOffline {
            // Before the system's first word on the network the account may be unreadable only because the network is
            // gone: wait for the word, and carry on as the offline launch does when it says so.
            await waitForFirstReport()
            guard generation == playGeneration, !Task.isCancelled else { return }
            if !isOffline {
                logger.info("session not restored: account unknown")
                return
            }
        }
        guard generation == playGeneration, !Task.isCancelled, authState == .signedIn else { return }
        sessionChannelKey = key
        guard let snapshot = sessionStore.load(forChannel: key) else { return }
        guard let track = snapshot.queue.current else {
            sessionStore.delete()
            return
        }
        // Offline, a song that is not downloaded cannot start. The queue is put back all the same, with that song selected
        // and nothing loading: Play moves on to the next downloaded song (see `resume`).
        if isOffline, await downloadedStream(of: track.videoId) == nil {
            guard generation == playGeneration, !Task.isCancelled else { return }
            parkRestoredQueue(snapshot, current: track)
            return
        }
        let stream: ResolvedStream
        do {
            stream = try await streamForSource(of: track.videoId)
        } catch {
            guard generation == playGeneration, !Task.isCancelled, !Self.isCancellation(error) else { return }
            // The network failing is no fault of the session: when the path is unreported the word decides, and with no
            // network the queue is put back as the offline launch does, to play from the files, and the session is kept.
            if MusicConnectivity.isNetworkFailure(error) {
                await waitForFirstReport()
                guard generation == playGeneration, !Task.isCancelled else { return }
                if isOffline {
                    parkRestoredQueue(snapshot, current: track)
                    return
                }
            }
            // Nothing plays and the neighbours are not tried: the session is dropped whole.
            logger.error("session restore failed: \(Self.logDescription(of: error), privacy: .public)")
            sessionStore.delete()
            if Self.isSignedOut(error) { handle(error) }
            return
        }
        guard generation == playGeneration, !Task.isCancelled else { return }
        queue = snapshot.queue
        direction = .forward
        failureStreak = 0
        queueRetryAttempts = 0
        session = Session(
            cpn: CPN.make(),
            startedAt: now(),
            trackingURL: stream.playbackTrackingURL,
            watchtimeURL: stream.watchtimeTrackingURL,
            videoId: stream.videoId,
            durationSeconds: stream.durationSeconds
        )
        restoredVideoId = track.videoId
        lastSavedSession = snapshot
        refreshMixPairsSoon()
        player.loadPaused(
            stream: stream, track: track,
            at: snapshot.clampedPosition(duration: stream.durationSeconds ?? Double(track.durationSeconds ?? 0))
        )
        fetchTrackingURLs(for: stream, generation: generation)
        topUpQueue()
    }

    /// Puts the remembered queue back with its current song selected and nothing loading (a song that cannot start with
    /// no network). Play moves on to the next downloaded song (see `resume`).
    private func parkRestoredQueue(_ snapshot: MusicSessionSnapshot, current track: MusicTrack) {
        queue = snapshot.queue
        direction = .forward
        failureStreak = 0
        queueRetryAttempts = 0
        session = nil
        restoredVideoId = track.videoId
        lastSavedSession = snapshot
        player.beginLoading(track)
        player.failLoading()
    }

    /// Returns at once when the system has said whether there is a network, else when its first word comes.
    private func waitForFirstReport() async {
        await connectivity?.firstReport()
    }

    // MARK: - Search

    /// Searches for `query`: run on Return, and as the owner types. A newer search replaces the one in flight.
    func search() {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deferredSearch = nil
            results = []
            artistResults = []
            albumResults = []
            isSearching = false
            searchTask = nil
            return
        }
        // No network: nothing is asked and nothing spins. The words are kept, and the search runs once when it returns.
        guard !isOffline else {
            deferredSearch = trimmed
            results = []
            artistResults = []
            albumResults = []
            isSearching = false
            lastError = nil
            searchTask = nil
            return
        }
        deferredSearch = nil
        isSearching = true
        lastError = nil
        searchTask = Task { [weak self] in
            await self?.runSearch(trimmed, generation: generation)
        }
    }

    /// What the search asks for besides the songs, as it arrives.
    private enum SearchExtra: Sendable {
        case artists([MusicCollection])
        case albums([MusicCollection])
        case topTrack(MusicTrack?)
        case graceEnded
    }

    /// Songs, artists, albums and the Top result are asked for at the same time. They land together, so a shelf never
    /// pops in above songs the owner is already reading, and the Top result never takes the first place from under them.
    /// Only the songs decide success: if they fail the search fails as before and the rest is dropped; if only the
    /// artists, the albums or the Top result fail, the songs show without them. Once the songs are in, the other three
    /// get `artistGrace` more between them to arrive; a slower request is cancelled and the songs show without it, so
    /// they never wait out its timeout. The owner's matching albums come from the library as it is when the search
    /// lands: nothing is asked of the network for them, and a library not loaded yet adds none.
    private func runSearch(_ term: String, generation: Int) async {
        let backend = self.backend
        // Not `async let`: that is awaited when the scope ends, which would keep the songs back for as long as
        // the extra requests live. These tasks are cancelled instead, and hand over what they found by a stream.
        let (arrivals, arrive) = AsyncStream.makeStream(of: SearchExtra.self)
        let artistsTask = Task { arrive.yield(.artists(await Self.searchArtistsQuietly(term, through: backend))) }
        let albumsTask = Task { arrive.yield(.albums(await Self.searchAlbumsQuietly(term, through: backend))) }
        let topTask = Task { arrive.yield(.topTrack(await Self.searchTopResultQuietly(term, through: backend))) }
        var timer: Task<Void, Never>?
        defer {
            artistsTask.cancel()
            albumsTask.cancel()
            topTask.cancel()
            timer?.cancel()
        }
        do {
            let found = try await backend.search(term)
            let grace = artistGrace
            timer = Task {
                do {
                    try await Task.sleep(for: grace)
                    arrive.yield(.graceEnded)
                } catch {}
            }
            // All three extras, or the end of the grace, whichever comes first. A cancelled search ends the wait.
            var artists: [MusicCollection] = []
            var albums: [MusicCollection] = []
            var topTrack: MusicTrack?
            var waiting = 3
            for await arrived in arrivals {
                switch arrived {
                case .artists(let list):
                    artists = list
                    waiting -= 1
                case .albums(let list):
                    albums = list
                    waiting -= 1
                case .topTrack(let track):
                    topTrack = track
                    waiting -= 1
                case .graceEnded:
                    waiting = 0
                }
                if waiting == 0 { break }
            }
            guard generation == searchGeneration, !Task.isCancelled else { return }
            results = Self.withTopTrack(topTrack, in: found)
            artistResults = Array(artists.prefix(Self.maxArtistResults))
            albumResults = MusicSearchAlbums.resolve(query: term, library: loadedAlbumLibrary(), found: albums)
            isSearching = false
            MusicMemoryLog.log("search")
        } catch {
            guard generation == searchGeneration else { return }
            isSearching = false
            // The network went while the search was on its way: it is not an error, it runs again when the network returns.
            if isOffline, error is URLError {
                deferredSearch = term
                return
            }
            handle(error)
        }
    }

    /// The songs with the Top result first and not repeated: an uploaded video the songs filter leaves out shows where
    /// the owner looks first, and a song the filter did return moves up instead of showing twice.
    private static func withTopTrack(_ top: MusicTrack?, in songs: [MusicTrack]) -> [MusicTrack] {
        guard let top else { return songs }
        return [top] + songs.filter { $0.videoId != top.videoId }
    }

    /// The artists for a search, or none when the request fails: the shelf is a bonus, so it never shows an
    /// error. A real failure leaves one log line with the error kind only, never the query, a name or a URL.
    private static func searchArtistsQuietly(_ term: String, through backend: any MusicBackend) async -> [MusicCollection] {
        do {
            return try await backend.searchArtists(term)
        } catch {
            if !isCancellation(error) {
                logger.info("artist search failed: \(logDescription(of: error), privacy: .public)")
            }
            return []
        }
    }

    /// The albums for a search, or none when the request fails: like the artists they are a bonus, so they never show an
    /// error, and a failure logs the error kind only.
    private static func searchAlbumsQuietly(_ term: String, through backend: any MusicBackend) async -> [MusicCollection] {
        do {
            return try await backend.searchAlbums(term)
        } catch {
            if !isCancellation(error) {
                logger.info("album search failed: \(logDescription(of: error), privacy: .public)")
            }
            return []
        }
    }

    /// The library lists an album search looks in, as far as they have loaded. Opening Library loads them; a search
    /// never does.
    private func loadedAlbumLibrary() -> [MusicLibrarySection: [MusicCollection]] {
        var lists: [MusicLibrarySection: [MusicCollection]] = [:]
        for section in MusicSearchAlbums.librarySections {
            if let items = browse.loadedLibrary(section) { lists[section] = items }
        }
        return lists
    }

    /// The Top result's track for a search, or none when the request fails: like the artists it is a bonus, so it
    /// never shows an error, and a failure logs the error kind only.
    private static func searchTopResultQuietly(_ term: String, through backend: any MusicBackend) async -> MusicTrack? {
        do {
            return try await backend.searchTopResult(term)
        } catch {
            if !isCancellation(error) {
                logger.info("top result search failed: \(logDescription(of: error), privacy: .public)")
            }
            return nil
        }
    }

    // MARK: - Playback

    /// Plays a tapped track. With Autoplay, a radio queue starts behind it; without, the song plays alone and stops.
    func play(_ track: MusicTrack) {
        // Offline a song that is not downloaded does not start, and what is playing is left alone.
        guard canPlayNow(track) else { return }
        noteActivity()
        queue.start(with: track)
        // The radio's pages are mixed in as they land.
        shuffleFreshQueue(mixingEarlier: false)
        direction = .forward
        failureStreak = 0
        queueRetryAttempts = 0
        // The radio is asked for when the network is back (see `connectivityChanged`), and never for a downloaded song
        // played with the account gone.
        if isAutoplayOn, !holdsBackRequests {
            startRadio(seed: track.videoId)
        } else {
            // A radio still loading for the last queue must not land in this one.
            cancelRadio()
        }
        begin(track)
        resetRun()
    }

    /// Plays `track` with the rest of `page`'s songs queued after it in page order. The rest of a long playlist is
    /// loaded at once, so Up next lists all of it. With Autoplay the automix of a playlist or an album follows the page
    /// (the radio of the last song when YouTube names none). A mix page is an endless mix: it is asked for more after its
    /// last song whatever Autoplay and Loop say.
    func play(_ track: MusicTrack, in page: MusicBrowsePage) {
        guard canPlayNow(track) else { return }
        noteActivity()
        // A page is its own order: a radio left over from the last queue must not add to it.
        cancelRadio()
        // Offline, or signed out from a song's file, the page is its downloaded songs: the rest cannot play, its later pages
        // and its mix cannot be asked for.
        let offline = isOffline || (authState == .signedOut && isDownloaded(track))
        queue.start(
            page: offline ? page.tracks.filter(isDownloaded) : page.tracks,
            playing: track,
            browseId: page.browseId,
            continuation: offline ? nil : page.continuation,
            automixPlaylistId: offline ? nil : page.automixPlaylistId,
            mixPlaylistId: offline ? nil : page.mixPlaylistId
        )
        // The row that was tapped plays first; every other row, the ones above it too, is mixed in after it.
        shuffleFreshQueue(mixingEarlier: true)
        direction = .forward
        failureStreak = 0
        queueRetryAttempts = 0
        begin(track)
        resetRun()
    }

    /// A queue that just started is put in the shuffled order: random in Shuffle, the page's own order in Mix until the
    /// rows are read and the songs are ordered (`orderMix`).
    private func shuffleFreshQueue(mixingEarlier: Bool) {
        guard isShuffleOn else { return }
        if isMixOn {
            queue.beginMix(mixingEarlier: mixingEarlier)
            startMixOrdering()
        } else {
            queue.shuffle(mixingEarlier: mixingEarlier, using: &shuffleGenerator)
        }
    }

    /// "Play" on a playlist or album page: starts from its first song that can play. That is its first song, except offline
    /// and signed out, where it is the first one that is downloaded.
    func playFirst(of page: MusicBrowsePage) {
        guard let first = playableTracks(of: page).first else { return }
        play(first, in: page)
    }

    /// The songs of `page` a start can begin from: all of them, minus the ones that cannot play now. Signed out, the
    /// downloaded ones when there are any: they are the ones that can play without an account.
    private func playableTracks(of page: MusicBrowsePage) -> [MusicTrack] {
        let ready = page.tracks.filter(canPlayNow)
        guard authState == .signedOut else { return ready }
        let local = ready.filter(isDownloaded)
        return local.isEmpty ? ready : local
    }

    /// "Shuffle" on a playlist or album page: turns shuffle on and starts from a random track of the page.
    func playShuffled(_ page: MusicBrowsePage) {
        guard let track = playableTracks(of: page).randomElement(using: &shuffleGenerator) else { return }
        if !isShuffleOn {
            // Turned on as plain Shuffle; Mix, when on, stays on.
            isShuffleOn = true
            savePlaybackPreferences()
        }
        play(track, in: page)
    }

    // MARK: - Queue edits

    /// Play next: the song plays right after the current one. With nothing queued it just starts the song, like a tap
    /// on a lone song: with Autoplay, a radio behind it.
    func playNext(_ track: MusicTrack) {
        guard canPlayNow(track) else { return }
        guard !queue.isEmpty else { return play(track) }
        guard queue.playNext(track) else { return }
        noteActivity()
        queueEdited()
        refreshMixPairsSoon()
        saveSession()
        trackActions.post("Playing next")
    }

    /// Add to queue: the song goes after the queue's own songs and before the radio that follows. With nothing queued it
    /// just starts the song, like a tap on a lone song: with Autoplay, a radio behind it.
    func addToQueue(_ track: MusicTrack) {
        guard canPlayNow(track) else { return }
        guard !queue.isEmpty else { return play(track) }
        guard queue.addToQueue(track) else { return }
        noteActivity()
        queueEdited()
        refreshMixPairsSoon()
        saveSession()
        trackActions.post("Added to queue")
    }

    /// Remove from queue: the song leaves the play order. A queue left short is topped up, so Up next with Autoplay
    /// on is never empty.
    func removeFromQueue(_ track: MusicTrack) {
        guard queue.remove(videoId: track.videoId) else { return }
        noteActivity()
        topUpQueue()
        refreshMixPairsSoon()
        saveSession()
        trackActions.post("Removed from queue")
    }

    /// Play next for several songs: they play right after the current one, in the order given. A song that is listed
    /// twice, is the one in the player, or cannot play now is left out. With nothing queued the first starts and the rest
    /// follow it. One top-up, one save and one line for the whole call; with one song left it is the single entry.
    func playNext(_ tracks: [MusicTrack]) {
        editQueue(with: tracks, .playNext)
    }

    /// Add to queue for several songs: they go after the queue's own songs in the order given, with the same skips and the
    /// same single top-up, save and line as `playNext(_:)`.
    func addToQueue(_ tracks: [MusicTrack]) {
        editQueue(with: tracks, .addToQueue)
    }

    /// Remove from queue for several songs. The line counts the songs that were there to remove, and the queue is topped
    /// up once.
    func removeFromQueue(_ tracks: [MusicTrack]) {
        var seen: Set<String> = []
        let songs = tracks.filter { seen.insert($0.videoId).inserted }
        guard songs.count > 1 else {
            if let only = songs.first { removeFromQueue(only) }
            return
        }
        let removed = queue.remove(videoIds: songs.map(\.videoId))
        guard removed > 0 else { return }
        noteActivity()
        topUpQueue()
        saveSession()
        trackActions.post(MusicSelectionAction.removeFromQueue.notice(count: removed))
    }

    /// The shared part of the two bulk puts, for `.playNext` or `.addToQueue`.
    private func editQueue(with tracks: [MusicTrack], _ action: MusicSelectionAction) {
        var seen: Set<String> = []
        if let current = queue.current { seen.insert(current.videoId) }
        let songs = tracks.filter { canPlayNow($0) && seen.insert($0.videoId).inserted }
        guard let first = songs.first else { return }
        guard songs.count > 1 else {
            if action == .playNext { playNext(first) } else { addToQueue(first) }
            return
        }
        // With nothing queued the first song starts, as a tap on a lone song does, and the rest go behind it.
        let startsFirst = queue.isEmpty
        let rest = startsFirst ? Array(songs.dropFirst()) : songs
        if startsFirst { play(first) }
        let placed = action == .playNext ? queue.playNext(rest) : queue.addToQueue(rest)
        guard placed > 0 else { return }
        noteActivity()
        queueEdited()
        saveSession()
        // The line counts every song of the put: the one that started is one of them.
        trackActions.post(action.notice(count: startsFirst ? placed + 1 : placed, startedFirst: startsFirst))
    }

    /// A song was put into the queue. A Next that waited for the radio takes it now, and a queue that had played out
    /// (or stopped after failures) starts it; otherwise the queue is topped up as usual.
    private func queueEdited() {
        if resumePendingAdvance() { return }
        if pendingAdvance == nil, player.hasEnded || player.nowPlaying == nil, let track = advanceQueue() {
            direction = .forward
            failureStreak = 0
            begin(track)
            return
        }
        topUpQueue()
    }

    // MARK: - Playback modes

    /// Turning shuffle on mixes a playlist or album whole, with the current track first, so Up next shows the entire
    /// page in its shuffled order; on a radio only what comes after the current track is mixed. Turning it off puts the
    /// whole queue back in its natural order and carries on from the current track. A page's recommendations follow its
    /// last song in the play order, so when the change moves that song they are asked again for the new one (see
    /// `topUpQueue`).
    func setShuffle(_ on: Bool) {
        guard on != isShuffleOn else { return }
        setShuffleMode(on ? .shuffle : .off)
    }

    /// The shuffle button's three states. Mix keeps the queue in the order Shuffle would have it (the natural order is
    /// remembered the same way, so Off puts it back) and then orders the songs after the playing one by tempo, key and
    /// energy as soon as their analysis rows are read (`orderMix`). Going from Mix to Shuffle leaves the order as it is.
    func setShuffleMode(_ mode: MusicShuffleMode) {
        guard mode != shuffleMode else { return }
        touchSession()
        let wasShuffled = isShuffleOn
        isShuffleOn = mode.isOn
        isMixOn = mode == .mix
        if !isMixOn {
            mixTask?.cancel()
            mixTask = nil
            mixPairs = [:]
            lastAppliedStyle = nil
            mixOrderPending = false
            mixAvoid = []
            mixReplanPending = false
            mixRows = [:]
            mixAsked = []
            stagedRadioTask?.cancel()
            radioPlacedKey = nil
        }
        if !queue.isEmpty {
            switch mode {
            case .off:
                queue.unshuffle()
            case .shuffle:
                if !wasShuffled { queue.shuffle(mixingEarlier: queue.isPage, using: &shuffleGenerator) }
            case .mix:
                if !wasShuffled { queue.beginMix(mixingEarlier: queue.isPage) }
                startMixOrdering()
            }
        }
        savePlaybackPreferences()
        // A parked beat plan or style is Mix's: leaving Mix (or entering it) plans the pair again.
        replanOffered()
        topUpQueue()
        radioScanSoon()
        saveSession()
    }

    /// The shuffle button: Off, Shuffle, Mix, Off.
    func cycleShuffleMode() {
        setShuffleMode(shuffleMode.next)
    }

    // MARK: - Mix

    @ObservationIgnored private(set) var mixTask: Task<Void, Never>?
    /// The analysis rows Mix has read, for the songs it ordered or shows.
    @ObservationIgnored private var mixRows: [String: MusicAnalysis] = [:]

    /// How many songs after the playing one Up next shows tempo and key for.
    private static let mixShownCount = 40

    /// Mix has not laid the queue out yet: the songs were not there, or the playing song changed first.
    @ObservationIgnored private var mixOrderPending = false
    /// Songs played since the window was last ordered; a top-up orders the next window after `MusicMixWindow.topUpAfter`.
    @ObservationIgnored private var mixPlayed = 0
    /// Songs Mix already asked the analyzer for, so a song that cannot be analysed is asked for once.
    @ObservationIgnored private var mixAsked: Set<String> = []
    /// At most this many unanalysed songs of a window are analysed in the foreground per refresh.
    static let mixAnalysesPerRefresh = 4
    /// A top-up leaves the next songs as they are: the listener sees them, and the first of them may be preloading.
    static let mixVisibleKept = 3

    private func startMixOrdering() {
        mixOrderPending = true
        mixTask?.cancel()
        mixTask = Task { [weak self] in await self?.orderMix(keeping: 0) }
    }

    /// The queue gained songs (a radio page landed): a Mix that had nothing to order yet orders them now.
    private func mixQueueGrew() {
        guard isMixOn, mixOrderPending, !queue.unqueuedUpcoming.isEmpty else { return }
        startMixOrdering()
    }

    /// Reads the rows of the playing song and the next window of unqueued songs after it, orders that window and lays it
    /// into the queue's slots (the songs behind the window keep their order), then analyses a few songs that had no row
    /// and works out what Up next shows. A song with no row scores neutral and is never blocked; it joins a later
    /// window once its row is stored. `keeping` songs at the front of the unqueued songs stay where they are, and the
    /// last of them is the song the window mixes out of.
    private func orderMix(keeping fixedCount: Int) async {
        let unqueued = queue.unqueuedUpcoming
        let fixed = Array(unqueued.prefix(fixedCount))
        let window = Array(unqueued.dropFirst(fixedCount).prefix(MusicMixWindow.size))
        let anchor = fixed.last ?? queue.current
        guard !window.isEmpty else {
            await refreshMixPairs()
            return
        }
        await readMixRows(for: window + (anchor.map { [$0] } ?? []))
        guard !Task.isCancelled, isMixOn else { return }
        let profiles = window.map { MusicMixProfile(videoId: $0.videoId, artist: $0.artist, analysis: mixRows[$0.videoId]) }
        let first = anchor.map { MusicMixProfile(videoId: $0.videoId, artist: $0.artist, analysis: mixRows[$0.videoId]) }
        var orderer = MusicMixOrderer(seed: shuffleGenerator.next())
        queue.mixOrder(orderer.order(profiles, first: first))
        // The reorder can move the page's last own song, which the staged radio was asked for.
        if dropStaleRadio() { topUpQueueAfterModeChange() }
        mixOrderPending = false
        mixPlayed = 0
        saveSession()
        radioScanSoon()
        await refreshMixPairs()
        await analyseMissingRows(in: window)
        // Rows that landed show in Up next at once; they change the order at the next top-up.
        await refreshMixPairs()
    }

    /// Analyses, one at a time in play order, up to `mixAnalysesPerRefresh` songs of `window` that have no stored row,
    /// through the foreground path (it shares a run with the playing song's own analysis and sits outside the background
    /// analyzer's hourly cap). Nothing is analysed offline, signed out or under Loop song.
    private func analyseMissingRows(in window: [MusicTrack]) async {
        guard let analysis, let reader = analysisReader, !isOffline, authState != .signedOut, loopMode != .song else { return }
        var asked = 0
        for track in window where mixRows[track.videoId] == nil && !mixAsked.contains(track.videoId) {
            guard asked < Self.mixAnalysesPerRefresh else { return }
            if Task.isCancelled || !isMixOn { return }
            asked += 1
            await MusicCancellableWait.wait(for: radioScanInFlight)
            if Task.isCancelled { return }
            guard let stream = try? await streamForSource(of: track.videoId) else {
                if !Task.isCancelled { mixAsked.insert(track.videoId) }
                continue
            }
            let outcome = await analysis.ensure(stream: stream, wantsFile: false)
            // A run that was cancelled mid-way asks again later; a finished one is not asked twice.
            if Task.isCancelled { return }
            mixAsked.insert(track.videoId)
            if outcome == .rateLimited { return }
            if let row = await reader.analysis(for: track.videoId) { mixRows[track.videoId] = row }
        }
    }

    /// Reads the stored row of every song in `tracks` that Mix has not read yet.
    private func readMixRows(for tracks: [MusicTrack]) async {
        guard let reader = analysisReader else { return }
        for track in tracks where mixRows[track.videoId] == nil {
            if Task.isCancelled { return }
            if let row = await reader.analysis(for: track.videoId) { mixRows[track.videoId] = row }
        }
    }

    /// A refresh of what Up next shows, after the queue or a setting changed. Runs behind the work already going.
    private func refreshMixPairsSoon() {
        guard isMixOn else { return }
        let previous = mixTask
        mixTask = Task { [weak self] in
            await previous?.value
            await self?.refreshMixPairs()
        }
    }

    /// The tempo line of a song's own row ("128"), nil outside Mix or without a row.
    func mixRowText(for id: String) -> String? {
        guard isMixOn else { return nil }
        _ = mixPairs  // reading it makes a view that shows this line update with the pairs
        guard let row = mixRows[id] else { return nil }
        return MusicMixPairInfo(bpm: row.usableGrid.map { Int($0.bpm.rounded()) }, camelot: row.trustedCamelot, mode: .fade).rowText
    }

    /// Records the lengths the app already knows (the exact one of an analysis row read for Mix, or of a stream just
    /// resolved) and gives the queued songs that arrived without one theirs. No network.
    private func fillQueueDurations(resolved: ResolvedStream? = nil) {
        for (id, row) in mixRows where row.format.durationMs > 0 {
            knownLengths[id] = Int((Double(row.format.durationMs) / 1000).rounded())
        }
        if let resolved, let seconds = resolved.durationSeconds, seconds.isFinite, seconds > 0 {
            knownLengths[resolved.videoId] = Int(seconds.rounded())
        }
        fillQueueFromKnownLengths()
    }

    /// Filled on a copy: a mutating call on `queue` fires its didSet and observers even when nothing changed.
    private func fillQueueFromKnownLengths() {
        var filled = queue
        if filled.fillMissingDurations(knownLengths) { queue = filled }
    }

    /// Every length learned this session, by video id: from YouTube's queue answers, analysis rows and resolved streams.
    /// A song that comes back into the queue as a fresh copy without a length (the same page played again, a song added
    /// that is already queued) gets its length from here and is not asked about again.
    @ObservationIgnored private var knownLengths: [String: Int] = [:]
    /// Songs `askForQueueLengths` already asked YouTube about, so one it gives no length for is never asked again.
    @ObservationIgnored private var askedLengthIds: Set<String> = []
    @ObservationIgnored private(set) var queueLengthTask: Task<Void, Never>?
    /// The most ids either memory holds; past it they keep only the songs now queued.
    private static let askedLengthCap = 5000
    /// What `music/get_queue` takes in one call.
    private static let queueLengthBatch = 50

    private var queuedTracks: [MusicTrack] { queue.tracks + queue.autoplay + queue.parked }

    /// The ids in the queue, the staged radio and the parked radio that have no length and were not asked about yet.
    private func unaskedLengthIds() -> [String] {
        var seen = Set<String>()
        return queuedTracks.compactMap { track in
            guard track.durationSeconds == nil, knownLengths[track.videoId] == nil,
                  !askedLengthIds.contains(track.videoId), seen.insert(track.videoId).inserted
            else { return nil }
            return track.videoId
        }
    }

    /// Whether the queue holds a song without a length that is worth a pass: one whose length is already known, or one
    /// not asked about yet.
    private func queueNeedsLengths() -> Bool {
        queuedTracks.contains { track in
            track.durationSeconds == nil && (knownLengths[track.videoId] != nil || !askedLengthIds.contains(track.videoId))
        }
    }

    /// Asks YouTube Music for the length of every queued song that has none (Home tiles, quick picks and some artist rows
    /// carry none), 50 at a time, one call at a time, behind playback. Runs from the queue's `didSet`, the one place every
    /// change to the queue passes, and when the network returns. Each pass first fills the queue from the lengths already
    /// known. A failed call is logged once and the task stops: its songs are asked again on a later queue change after a
    /// network failure, and not after an answer from YouTube that was a refusal or made no sense.
    private func askForQueueLengths() {
        guard queueLengthTask == nil, !isOffline, queueNeedsLengths() else { return }
        if askedLengthIds.count > Self.askedLengthCap || knownLengths.count > Self.askedLengthCap {
            let queued = Set(queuedTracks.map(\.videoId))
            askedLengthIds.formIntersection(queued)
            knownLengths = knownLengths.filter { queued.contains($0.key) }
        }
        queueLengthTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.fillQueueFromKnownLengths()
                let batch = Array(self.unaskedLengthIds().prefix(Self.queueLengthBatch))
                if batch.isEmpty { break }
                self.askedLengthIds.formUnion(batch)
                do {
                    let lengths = try await self.backend.queueDurations(videoIds: batch)
                    if Task.isCancelled { break }
                    for (id, seconds) in lengths where seconds > 0 { self.knownLengths[id] = seconds }
                } catch {
                    if Task.isCancelled { break }
                    if error is URLError { self.askedLengthIds.subtract(batch) }
                    logger.error("queue lengths failed: \(Self.logDescription(of: error), privacy: .public)")
                    break
                }
            }
            // A cancelled task leaves the slot to whoever cancelled it: a newer task may already hold it.
            if !Task.isCancelled { self?.queueLengthTask = nil }
        }
    }

    /// Works out how each of the next songs is reached, from the rows read so far.
    private func refreshMixPairs() async {
        guard isMixOn, let current = queue.current else { return }
        let chain = [current] + Array(queue.upcoming.prefix(Self.mixShownCount))
        await readMixRows(for: chain)
        guard !Task.isCancelled, isMixOn else { return }
        fillQueueDurations()
        var pairs: [String: MusicMixPairInfo] = [:]
        // Each row is planned against the style of the row before it; the first one against the last applied style.
        // A missing analysis row gives a plain fade (a long blend) for that pair.
        let sides: [MusicTransitionSide?] = chain.map { song in mixRows[song.videoId].map { mixSide(song, row: $0) } }
        let infos = MusicMixPairInfo.makeChain(
            sides: sides, lastApplied: lastAppliedStyle, settingSeconds: crossfadeSeconds, beatMixEnabled: isBeatMixOn
        )
        for (index, info) in infos.enumerated() {
            guard let info else { continue }
            pairs[MusicMixPairInfo.key(from: chain[index].videoId, to: chain[index + 1].videoId)] = info
        }
        if pairs != mixPairs { mixPairs = pairs }
        // Keep the rows of what Mix can still use: the shown chain, the next two windows, the staged radio, the avoided.
        var keep = Set(chain.map(\.videoId))
        keep.formUnion(queue.unqueuedUpcoming.prefix(MusicMixWindow.size * 2).map(\.videoId))
        keep.formUnion(queue.autoplay.prefix(MusicMixWindow.size).map(\.videoId))
        keep.formUnion(mixAvoid.map(\.videoId))
        if mixRows.count > keep.count { mixRows = mixRows.filter { keep.contains($0.key) } }
        if mixAsked.count > keep.count { mixAsked = mixAsked.intersection(keep) }
        await placeStagedRadio()
    }

    private func mixSide(_ track: MusicTrack, row: MusicAnalysis) -> MusicTransitionSide {
        MusicTransitionSide(
            videoId: track.videoId,
            durationSeconds: track.durationSeconds.map(Double.init) ?? Double(row.format.durationMs) / 1000,
            analysis: row, youtubeLoudnessDb: row.youtubeLoudnessDb
        )
    }

    /// The song that came after `previousId` in Up next, as Mix reaches it: nil outside Mix.
    func mixInfo(from previousId: String, to id: String) -> MusicMixPairInfo? {
        isMixOn ? mixPairs[MusicMixPairInfo.key(from: previousId, to: id)] : nil
    }

    /// The songs a manual skip left, newest last (at most `mixAvoidKept`): the re-plan after a skip pushes them and their
    /// artists to the back. Memory only; it goes with Mix.
    @ObservationIgnored private var mixAvoid: [MusicMixProfile] = []
    /// A manual skip happened and the next songs have not been re-planned yet.
    @ObservationIgnored private var mixReplanPending = false
    static let mixAvoidKept = 3

    /// Records a manual skip (Next, or a tap in Up next): the song left goes on the avoid list and the next songs are
    /// re-planned once the new song has started. A song that ended by itself never comes here.
    private func noteMixSkip(of leaving: MusicTrack?) {
        guard isMixOn, let leaving else { return }
        mixAvoid.append(MusicMixProfile(videoId: leaving.videoId, artist: leaving.artist, analysis: mixRows[leaving.videoId]))
        if mixAvoid.count > Self.mixAvoidKept { mixAvoid.removeFirst(mixAvoid.count - Self.mixAvoidKept) }
        mixReplanPending = true
    }

    /// Re-orders the next `MusicMixOrderer.tailCount` unqueued songs out of the song that now plays, away from what was
    /// just skipped. A next song that is already offered for preload stays first: the change goes through the queue, so
    /// `reconcilePreload` sees it like any other edit.
    private func replanAfterSkip() async {
        guard isMixOn, let current = queue.current else { return }
        // One read covers the fixed song and the window; what is fixed is decided after it, from the queue as it is then.
        await readMixRows(for: Array(queue.unqueuedUpcoming.prefix(MusicMixOrderer.tailCount + 1)) + [current])
        guard !Task.isCancelled, isMixOn, let current = queue.current else { return }
        let unqueued = queue.unqueuedUpcoming
        let first = unqueued.first?.videoId
        let fixedCount = first != nil && (first == preloadOffered || first == prefetchAttempt) ? 1 : 0
        let window = Array(unqueued.dropFirst(fixedCount).prefix(MusicMixOrderer.tailCount))
        guard window.count > 1 else { return }
        let anchor = unqueued.prefix(fixedCount).last ?? current
        func profile(_ track: MusicTrack) -> MusicMixProfile {
            MusicMixProfile(videoId: track.videoId, artist: track.artist, analysis: mixRows[track.videoId])
        }
        var orderer = MusicMixOrderer(seed: shuffleGenerator.next())
        let order = orderer.reorderTail(
            anchor: profile(anchor), upcoming: window.map(profile), avoid: mixAvoid, count: MusicMixOrderer.tailCount,
            // Only the playing song is held at a rate; a preloaded anchor has not started yet.
            anchorRate: fixedCount == 0 ? activeDeckRate : 1
        )
        queue.mixOrder(order)
        if dropStaleRadio() { topUpQueueAfterModeChange() }
        saveSession()
    }

    /// The first pick of a placed radio is analysed in the foreground once it plays, so the songs after it can be scored.
    @ObservationIgnored private var mixAnalyseCurrent = false

    /// Test hooks: the re-plan on its own, and a preload offer without a player in the window.
    func replanAfterSkipForTesting() async { await replanAfterSkip() }
    func offerPreloadForTesting(_ id: String?) { preloadOffered = id }

    /// The staged radio was placed for this hand-over song and this order; a different one places it again.
    @ObservationIgnored private var radioPlacedKey: String?
    @ObservationIgnored private(set) var stagedRadioTask: Task<Void, Never>?
    /// The last radio scan (see `scanRadio`); kept after it ends so a test can wait for it.
    @ObservationIgnored private(set) var radioScanTask: Task<Void, Never>?

    /// Reads the stored rows of the staged radio's first songs and places it. Its own task: a skip or a track change
    /// that cancels `mixTask` leaves it alone, and a newer staging replaces it.
    private func placeStagedRadioSoon() {
        stagedRadioTask?.cancel()
        stagedRadioTask = Task { [weak self] in await self?.placeStagedRadio() }
    }

    /// Under Mix the staged radio is laid out when it is staged, out of the song it hands over from (the queue's last
    /// song): the song that mixes best first (a seeded random one when nothing is known), the known songs in the slots
    /// that cost their neighbours least, and the songs with no row after them in the radio's order. It reorders
    /// `queue.autoplay` itself, so the hand-over takes it as it is. Nothing is analysed for the radio: only the first
    /// pick is, once it plays.
    private func placeStagedRadio() async {
        guard isMixOn, let anchor = queue.tracks.last, queue.autoplay.count > 1 else { return }
        func orderKey(_ staged: [MusicTrack]) -> String {
            anchor.videoId + "|" + staged.prefix(MusicMixWindow.size).map(\.videoId).joined(separator: ",")
        }
        // A row that landed since (the radio scan stores them) places the radio again, with the real tempo and key.
        func placedKey(_ staged: [MusicTrack]) -> String {
            orderKey(staged) + "|" + staged.prefix(MusicMixWindow.size).filter { mixRows[$0.videoId] != nil }.map(\.videoId).joined(separator: ",")
        }
        let staged = queue.autoplay
        guard placedKey(staged) != radioPlacedKey else { return }
        // The next song is locked once it is being prepared: a late row never moves it.
        guard !isNextSongLocked(staged.first) else { return }
        await readMixRows(for: Array(staged.prefix(MusicMixWindow.size)) + [anchor])
        guard !Task.isCancelled, isMixOn, queue.tracks.last?.videoId == anchor.videoId,
              orderKey(queue.autoplay) == orderKey(staged), !isNextSongLocked(queue.autoplay.first) else { return }
        let placed = Self.placement(
            of: staged, after: anchor, rows: mixRows, seed: shuffleGenerator.next(), pickFromFirst: MusicRadioPick.candidateCount
        )
        reorderStaged(placed.map(\.videoId))
        radioPlacedKey = placedKey(queue.autoplay)
    }

    /// `pickFromFirst` limits the choice of the first song to that many of the radio's first songs; the others are still
    /// laid into the slots that cost their neighbours least. Among them only songs with a row are judged once one has.
    static func placement(
        of fresh: [MusicTrack], after anchor: MusicTrack, rows: [String: MusicAnalysis], seed: UInt64,
        pickFromFirst: Int = MusicMixWindow.size
    ) -> [MusicTrack] {
        let head = Array(fresh.prefix(MusicMixWindow.size))
        let rest = Array(fresh.dropFirst(head.count))
        func profile(_ track: MusicTrack) -> MusicMixProfile {
            MusicMixProfile(videoId: track.videoId, artist: track.artist, analysis: rows[track.videoId])
        }
        func isKnown(_ p: MusicMixProfile) -> Bool { p.bpm != nil || p.camelot != nil || p.energy != nil }
        let profiles = head.map(profile)
        let anchorProfile = profile(anchor)
        var orderer = MusicMixOrderer(seed: seed)
        let pool = Array(profiles.prefix(pickFromFirst))
        let knownPool = pool.filter(isKnown)
        guard let pick = orderer.pickBest(from: knownPool.isEmpty ? pool : knownPool, after: anchorProfile) else { return fresh }
        var window = [pick]
        for candidate in profiles where candidate.videoId != pick.videoId && isKnown(candidate) {
            window.insert(candidate, at: orderer.bestInsertion(of: candidate, into: window, after: anchorProfile, minIndex: 1))
        }
        let unknown = profiles.filter { $0.videoId != pick.videoId && !isKnown($0) }
        let byId = Dictionary(head.map { ($0.videoId, $0) }) { first, _ in first }
        return (window + unknown).compactMap { byId[$0.videoId] } + rest
    }

    // MARK: - Radio pick

    /// While songs blend (Crossfade or Mix), the radio's first `MusicRadioPick.candidateCount` songs are analysed one at a
    /// time behind the playing song, and the one that mixes best out of it becomes the next song. It goes into the first
    /// radio slot, the other radio songs keep their order, and the songs the listener queued stay ahead of all of them.
    /// Without a blend the radio's order is never touched.

    /// A scan is planned or running: the early prefetch of the next song waits for it.
    @ObservationIgnored private(set) var radioScanRunning = false
    /// Counts the scans started, so only the last one clears `radioScanRunning`.
    @ObservationIgnored private var radioScanGeneration = 0
    /// What the scan's one analysis came to: the stream could not be resolved, it was not run (cancelled, or the next song
    /// got locked while the stream was resolved), or it ran.
    private enum RadioJobResult {
        case noStream
        case skipped
        case ran(MusicAnalysisCoordinator.Outcome)
    }
    /// The analysis the scan has under way (its stream resolve included), the only one it ever has. It is reserved in the
    /// same step as the last check that nothing else analyses, so the next song's job and Mix's own analyses (which wait
    /// for it) never run beside it. The job clears it itself when it ends.
    @ObservationIgnored private var radioScanInFlight: Task<RadioJobResult, Never>?
    @ObservationIgnored private var radioScanJobToken = 0
    /// Songs the scan already asked the analyzer for (done or failed), so none is asked twice in a session.
    @ObservationIgnored private var radioScanAsked: Set<String> = []
    /// Songs whose stored row was looked up while this song plays (a miss is not looked up again by the next scan).
    @ObservationIgnored private var radioScanLooked: Set<String> = []
    private static let radioScanKept = 200

    /// The radio songs a scan looks at: the first ones still ahead, and the song they follow.
    private struct RadioScanPlan {
        var tracks: [MusicTrack]
        var anchor: MusicTrack
        /// They are the staged radio of a page (not in the queue yet).
        var staged: Bool
    }

    /// The scan's plan for the queue as it is now; nil when no scan is wanted: songs do not blend, nothing can be analysed
    /// (no provider, offline, signed out, Loop song), the playing song has not loaded, or the next song is not a radio song.
    private func radioScanPlan() -> RadioScanPlan? {
        guard mixesTransitions, analysis != nil, analysisReader != nil, !isOffline, authState != .signedOut, loopMode != .song,
              let current = queue.current, player.currentStream?.videoId == current.videoId else { return nil }
        // Mix has not laid out the songs ahead yet: the first ten are not known until it has (it asks for a scan after).
        guard !(isMixOn && mixOrderPending && !queue.upcoming.isEmpty) else { return nil }
        let count = MusicRadioPick.candidateCount
        if queue.upcoming.isEmpty {
            guard playsAutoplay, !queue.autoplay.isEmpty else { return nil }
            return RadioScanPlan(tracks: Array(queue.autoplay.prefix(count)), anchor: current, staged: true)
        }
        let head = queue.radioHead
        guard !head.isEmpty else { return nil }
        return RadioScanPlan(tracks: Array(head.prefix(count)), anchor: current, staged: false)
    }

    /// The next song is being prepared (its preload is offered or its prefetch started): the pick is frozen from here, so
    /// the song the player was given is the song the queue hands over to.
    private func isNextSongLocked(_ next: MusicTrack?) -> Bool {
        guard let id = next?.videoId else { return false }
        return preloadOffered != nil || prefetchAttempt == id
    }

    /// Ends the scan before it (its waits and its analysis stop at once) and starts a new one when one is wanted. A scan
    /// that is no longer wanted (signed out, songs no longer blend, Loop song) just ends, and stops holding the prefetch.
    private func radioScanSoon() {
        radioScanTask?.cancel()
        radioScanGeneration += 1
        guard radioScanPlan() != nil else {
            radioScanRunning = false
            return
        }
        let generation = radioScanGeneration
        radioScanRunning = true
        radioScanTask = Task { [weak self] in
            guard let self else { return }
            await self.scanRadio()
            if generation == self.radioScanGeneration { self.radioScanRunning = false }
        }
    }

    /// The scan is over for good (a new song starts): nothing holds the prefetch any more.
    private func radioScanStop() {
        radioScanLooked = []
        radioScanTask?.cancel()
        radioScanGeneration += 1
        radioScanRunning = false
    }

    /// Reads the rows of the candidates, puts the best one first, and analyses the next candidate that has no row, until
    /// all have one, the next song is locked, the analyzer says to back off, or the queue no longer wants it. The pick is
    /// made again after every row, so the best so far is always in the first slot. A playing song with no row yet is
    /// waited for (its own analysis is under way) before the scan gives up on scoring.
    private func scanRadio() async {
        guard let analysis, let reader = analysisReader else { return }
        var analysed = 0
        var anchorWaited = false
        while !Task.isCancelled {
            guard let first = radioScanPlan() else { return }
            // The playing song's row first: with none, nothing can be scored and the candidates' rows are not looked up.
            var unread = [first.anchor].filter { !radioScanLooked.contains($0.videoId) }
            await readMixRows(for: unread)
            radioScanLooked.formUnion(unread.map(\.videoId))
            if mixRows[first.anchor.videoId] != nil {
                unread = first.tracks.filter { !radioScanLooked.contains($0.videoId) }
                await readMixRows(for: unread)
                radioScanLooked.formUnion(unread.map(\.videoId))
            }
            guard !Task.isCancelled, let plan = radioScanPlan(), plan.anchor.videoId == first.anchor.videoId else { return }
            if radioScanAsked.count > Self.radioScanKept { radioScanAsked = radioScanAsked.intersection(plan.tracks.map(\.videoId)) }
            if isNextSongLocked(plan.tracks.first) { return finishRadioScan(plan, analysed: analysed, locked: true) }
            await pickRadioNext(plan, analysed: analysed)
            guard !Task.isCancelled else { return }
            // Nothing to score from without a row for the song the radio follows: its own analysis is waited for once.
            guard mixRows[plan.anchor.videoId] != nil else {
                if anchorWaited { return finishRadioScan(plan, analysed: analysed, locked: false) }
                anchorWaited = true
                await MusicCancellableWait.wait(for: currentAnalysisTask)
                await MusicCancellableWait.wait(for: analysisTail)
                radioScanLooked.remove(plan.anchor.videoId)
                continue
            }
            guard let target = plan.tracks.first(where: { mixRows[$0.videoId] == nil && !radioScanAsked.contains($0.videoId) })
            else { return finishRadioScan(plan, analysed: analysed, locked: false) }
            // Behind the analyses already going (the playing song's, the next song's, Mix's own), then a fresh look.
            // The slot is taken in the same step as the last check, with no suspension between them.
            while true {
                let current = currentAnalysisTask, tail = analysisTail, mix = mixTask
                await MusicCancellableWait.wait(for: current)
                await MusicCancellableWait.wait(for: tail)
                await MusicCancellableWait.wait(for: mix)
                await MusicCancellableWait.wait(for: radioScanInFlight)
                if Task.isCancelled { return }
                if current == currentAnalysisTask, tail == analysisTail, mix == mixTask, radioScanInFlight == nil { break }
            }
            guard let now = radioScanPlan(), now.anchor.videoId == plan.anchor.videoId, !isNextSongLocked(now.tracks.first),
                  mixRows[plan.anchor.videoId] != nil, mixRows[target.videoId] == nil,
                  now.tracks.contains(where: { $0.videoId == target.videoId }) else { continue }
            radioScanJobToken += 1
            let token = radioScanJobToken
            let id = target.videoId
            let job = Task { () -> RadioJobResult in
                var result = RadioJobResult.noStream
                if let stream = try? await self.streamForSource(of: id) {
                    // The next song may have been locked while the stream was resolved: no new analysis then.
                    if !Task.isCancelled, let now = self.radioScanPlan(), !self.isNextSongLocked(now.tracks.first) {
                        result = .ran(await analysis.ensure(stream: stream, wantsFile: false))
                    } else {
                        result = .skipped
                    }
                } else if Task.isCancelled {
                    result = .skipped
                }
                if self.radioScanJobToken == token { self.radioScanInFlight = nil }
                return result
            }
            radioScanInFlight = job
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            // A run that was cancelled mid-way asks again later; a finished one is not asked twice.
            if Task.isCancelled { return }
            switch result {
            case .noStream:
                radioScanAsked.insert(id)
            case .skipped:
                break
            case .ran(let outcome):
                radioScanAsked.insert(id)
                analysed += 1
                if outcome == .rateLimited {
                    if let now = radioScanPlan() { finishRadioScan(now, analysed: analysed, locked: false) }
                    return
                }
                if let row = await reader.analysis(for: id) { mixRows[id] = row }
            }
        }
    }

    /// Puts the best candidate in the first radio slot, from the rows known now. Mix places a page's staged radio the way
    /// it always does (the best first and the other known songs by cost); a radio queue in Mix is re-ordered once the scan
    /// has stored a row (the best first, the others by Mix's own orderer out of it); under Crossfade only the best song
    /// moves. A radio with nothing to score keeps the order it had. The queue is only assigned when the order changed.
    private func pickRadioNext(_ plan: RadioScanPlan, analysed: Int) async {
        func profile(_ track: MusicTrack) -> MusicMixProfile {
            MusicMixProfile(videoId: track.videoId, artist: track.artist, analysis: mixRows[track.videoId])
        }
        if plan.staged, isMixOn {
            guard plan.tracks.contains(where: { MusicRadioPick.isKnown(profile($0)) }) else { return }
            await placeStagedRadio()
            return
        }
        guard let choice = MusicRadioPick.best(of: plan.tracks.map(profile), after: profile(plan.anchor)),
              choice.videoId != plan.tracks.first?.videoId else { return }
        if plan.staged {
            let others = queue.autoplay.map(\.videoId).filter { $0 != choice.videoId }
            guard reorderStaged([choice.videoId] + others) else { return }
        } else if isMixOn {
            // Rows that were there when Mix ordered the songs are in its order already; the ones this scan stored are not.
            guard analysed > 0 else { return }
            let rest = plan.tracks.filter { $0.videoId != choice.videoId }.map(profile)
            var orderer = MusicMixOrderer(seed: shuffleGenerator.next())
            let chosen = plan.tracks.first { $0.videoId == choice.videoId }.map(profile)
            let order = [choice.videoId] + orderer.order(rest, first: chosen)
            var copy = queue
            copy.mixOrder(order)
            guard copy.tracks.map(\.videoId) != queue.tracks.map(\.videoId) else { return }
            queue = copy
            refreshMixPairsSoon()
        } else {
            var copy = queue
            guard copy.promoteRadio(choice.videoId) else { return }
            queue = copy
        }
        saveSession()
    }

    /// The staged radio in `ids` order; false, and the queue untouched, when that is the order it already has (a
    /// reassignment would run the queue's observers again).
    @discardableResult
    private func reorderStaged(_ ids: [String]) -> Bool {
        var copy = queue
        copy.reorderAutoplay(ids)
        guard copy.autoplay.map(\.videoId) != queue.autoplay.map(\.videoId) else { return false }
        queue = copy
        return true
    }

    /// The scan is over for this next song: one log line with what it found.
    private func finishRadioScan(_ plan: RadioScanPlan, analysed: Int, locked: Bool) {
        let next = plan.staged ? queue.autoplay.first : queue.upcoming.first
        guard let next else { return }
        let known = plan.tracks.filter { mixRows[$0.videoId] != nil }.count
        func profile(_ track: MusicTrack) -> MusicMixProfile {
            MusicMixProfile(videoId: track.videoId, artist: track.artist, analysis: mixRows[track.videoId])
        }
        let scorable = MusicRadioPick.isKnown(profile(plan.anchor)) && MusicRadioPick.isKnown(profile(next))
        let reason = locked ? "locked" : (scorable ? "best" : "order")
        log(MusicTransitionLog.radioPickLine(
            candidates: plan.tracks.count, analysed: analysed, known: known, picked: next.videoId,
            score: scorable ? MusicRadioPick.score(of: profile(next), after: profile(plan.anchor)) : nil, reason: reason
        ))
    }

    /// The playing song changed: in Mix, what Up next shows is worked out again for the songs after it.
    /// After `MusicMixWindow.topUpAfter` songs the next window is ordered too, behind the songs the listener can see.
    private func mixTrackChanged() {
        guard isMixOn else { return }
        mixPlayed += 1
        let order = mixOrderPending || MusicMixWindow.needsTopUp(playedSinceOrdering: mixPlayed)
        let kept = mixOrderPending ? 0 : Self.mixVisibleKept
        let analyseCurrent = mixAnalyseCurrent
        mixAnalyseCurrent = false
        let replan = mixReplanPending
        mixReplanPending = false
        mixTask?.cancel()
        mixTask = Task { [weak self] in
            // The re-plan after a skip comes first: it is the part the listener hears next.
            if replan { await self?.replanAfterSkip() }
            if order { await self?.orderMix(keeping: kept) }
            if !order || replan { await self?.refreshMixPairs() }
            if analyseCurrent, let self, let current = self.queue.current {
                await self.analyseMissingRows(in: [current])
                await self.refreshMixPairs()
            }
        }
    }

    func setLoopMode(_ mode: MusicLoopMode) {
        guard mode != loopMode else { return }
        touchSession()
        loopMode = mode
        savePlaybackPreferences()
        // A queue standing at the end of its page may now hand over to the radio.
        topUpQueueAfterModeChange()
        saveSession()
    }

    /// The loop button: Off, Loop playlist, Loop song, Off.
    func cycleLoopMode() {
        setLoopMode(loopMode.next)
    }

    /// Autoplay on or off; the queue is topped up under the new setting at once. Turning it off on a radio queue (a
    /// tapped song's, or what a page handed over to; not a mix) parks the radio songs the listener has not reached and the
    /// radio's next page: Up next no longer lists them, so the current song plays and stops, after the songs added with
    /// Play next or Add to queue, and no page is asked for. A radio still in flight lands in the parking place, and a
    /// radio waiting on a retry is dropped. Turning it on again brings the same songs back behind the queued ones, and
    /// the top-up goes on from there. A queue that ended while Autoplay was off is not started again.
    func setAutoplay(_ on: Bool) {
        guard on != isAutoplayOn else { return }
        touchSession()
        isAutoplayOn = on
        savePlaybackPreferences()
        if on { queue.restoreRadio(using: &shuffleGenerator) } else { queue.parkRadio() }
        topUpQueueAfterModeChange()
        noteQueueFilling()
        saveSession()
    }

    /// The Crossfade toggle in Up next. Off is the gapless switch; a fade already running finishes, and the next
    /// transition follows the new setting.
    func setCrossfade(_ on: Bool) {
        guard on != isCrossfadeOn else { return }
        isCrossfadeOn = on
        savePlaybackPreferences()
        radioScanSoon()
    }

    /// How long a crossfade lasts, 1 to 12 seconds: Settings' value when the service reads it live.
    var crossfadeSeconds: Double {
        MusicPlaybackPreferences.clampedCrossfade(liveCrossfadeSeconds?() ?? startingCrossfadeSeconds)
    }

    /// Beat-matched transitions and the style picker are on. They apply only in Mix (a plain Crossfade is a plain fade), and
    /// also need Crossfade or Mix to mix at all, which the planner checks.
    var isBeatMixOn: Bool { isMixOn && beatMixSetting }
    /// The Settings switch itself, whatever the shuffle mode is (what is saved).
    private var beatMixSetting: Bool { liveBeatMix?() ?? startingBeatMix }
    var isVocalGuardOn: Bool { liveVocalGuard?() ?? startingVocalGuard }
    /// DJ-length songs is on (it only acts in Mix with Crossfade and Beat mix on, which the planner checks).
    var isDJLengthOn: Bool { isMixOn && (liveDJLength?() ?? startingDJLength) }

    /// A song that was heard long enough (the play-count point) joins the run; a skipped or failed one never does.
    private func noteRunSong(_ videoId: String, heard: TimeInterval, duration: TimeInterval?) {
        guard MusicListeningRules.countsAsPlay(heardSeconds: heard, durationSeconds: duration) else { return }
        playedRun.removeAll { $0 == videoId }
        playedRun.append(videoId)
        if playedRun.count > MusicDJLength.runSongs - 1 { playedRun.removeFirst(playedRun.count - (MusicDJLength.runSongs - 1)) }
    }

    /// A new queue starts a new run. Called after the first song began, so the song that was left has been counted already.
    private func resetRun() {
        playedRun = []
        songEnergy = songEnergy.filter { $0.key == analysisCurrentID }
    }

    /// The mean energy rating of the songs that played before this one and of this one once it has played long enough, nil
    /// when none is known.
    var runEnergy: Float? {
        var ids = playedRun
        if let current = player.currentStream, let session, session.videoId == current.videoId,
           MusicListeningRules.countsAsPlay(heardSeconds: session.accumulator.playedSeconds, durationSeconds: session.durationSeconds) {
            ids.removeAll { $0 == current.videoId }
            ids.append(current.videoId)
        }
        return MusicDJLength.runEnergy(ids.map { songEnergy[$0] })
    }

    /// An album page played in its own order: it stays gapless, whatever Crossfade says (an album is mixed to run on).
    private var playsAlbumInOrder: Bool {
        guard !queue.isShuffled, case .page(let browseId)? = queue.source else { return false }
        return browseId.hasPrefix("MPRE") || browseId.contains("OLAK")
    }

    /// Songs are handed over with a fade: Crossfade is on, or Mix is (Mix mixes whatever the Crossfade toggle says, with
    /// the length from Settings). Off and plain Shuffle follow Crossfade alone.
    var mixesTransitions: Bool { isCrossfadeOn || isMixOn }

    /// The fade the next transition gets: 0 (gapless) with Crossfade off, under Loop song (a track does not fade into
    /// itself) and on an album in order.
    var effectiveCrossfadeSeconds: Double {
        guard mixesTransitions, loopMode != .song, !playsAlbumInOrder else { return 0 }
        return crossfadeSeconds
    }

    /// Hands the player the fade the next transition gets, so the engine plans it.
    private func syncCrossfade() {
        player.crossfadeSeconds = effectiveCrossfadeSeconds
        // The parked plan is built again only when a setting it depends on changed (a tick that changes nothing costs
        // nothing); a flag change re-plans through `performMix`.
        let settings = ReplanSettings(
            crossfadeOn: mixesTransitions, seconds: crossfadeSeconds, albumInOrder: playsAlbumInOrder,
            loopSong: loopMode == .song, beatMix: isBeatMixOn, vocalGuard: isVocalGuardOn, djLength: isDJLengthOn
        )
        guard settings != syncedSettings else { return }
        syncedSettings = settings
        replanOffered()
        refreshMixPairsSoon()
    }

    private struct ReplanSettings: Equatable {
        var crossfadeOn: Bool
        var seconds: Double
        var albumInOrder: Bool
        var loopSong: Bool
        var beatMix: Bool
        var vocalGuard: Bool
        var djLength: Bool
    }

    private func savePlaybackPreferences() {
        guard !holdsPreferences else { return }
        savePreferences(MusicPlaybackPreferences(
            shuffle: isShuffleOn, loop: loopMode, autoplay: isAutoplayOn,
            crossfade: isCrossfadeOn, crossfadeSeconds: crossfadeSeconds, beatMix: beatMixSetting,
            vocalGuard: isVocalGuardOn, mixShuffle: isMixOn, djLength: liveDJLength?() ?? startingDJLength
        ))
    }

    /// Everything went back to its default. The settings were cleared already, so nothing is written here: the
    /// playback options go back to theirs the way the buttons change them, and the pins are dropped, so the next
    /// change cannot write the old ones back.
    func settingsDidReset() {
        let defaults = MusicPlaybackPreferences()
        holdsPreferences = true
        defer { holdsPreferences = false }
        setShuffleMode(defaults.shuffleMode)
        setLoopMode(defaults.loop)
        setAutoplay(defaults.autoplay)
        setCrossfade(defaults.crossfade)
        pinnedItems.settingsDidReset()
    }

    /// Play/pause for the transport and media keys. A track whose stream never resolved has nothing
    /// to resume, so Play tries it again instead.
    func togglePlayback() {
        noteActivity()
        if player.isPlaying || player.isLoading { player.toggle() } else { resume() }
    }

    func resume() {
        noteActivity()
        guard let track = player.nowPlaying else { return }
        guard !player.hasStream, !player.isLoading else { return player.play() }
        failureStreak = 0
        // Offline the selected song may be one that cannot start (a session restored without the network): the next
        // downloaded song plays in its place, or nothing does when there is none.
        if !canPlayNow(track) {
            direction = .forward
            guard let next = queue.advance(where: canPlayNow) else { return }
            begin(next)
            return
        }
        begin(track)
    }

    func next() {
        noteActivity()
        direction = .forward
        failureStreak = 0
        let leaving = queue.current
        guard let track = movingQueue(advanceQueue) else {
            // The radio may still be loading: keep playing and move on when its page lands. Offline there is no radio and
            // the queue ends at its last downloaded song: Next leaves it playing.
            if awaitRadio(for: .skipped) {
                // The skip waits for the radio to land: it counts as a skip all the same.
                noteMixSkip(of: leaving)
                return
            }
            if !wrapAround(), !isOffline { stopPlayback() }
            return
        }
        noteMixSkip(of: leaving)
        if crossfadeSkip(to: track) { return }
        reconcilePreload()
        begin(track)
    }

    /// Restarts the track once it has played a few seconds (or when it is the first); otherwise goes back one.
    func previous() {
        noteActivity()
        guard player.nowPlaying != nil else { return }
        let hasPrevious = isOffline ? queue.hasPrevious(where: canPlayNow) : queue.hasPrevious
        // Measured from where the song began: a song that starts at its trim offset has not played 3 s at 3 s of item time.
        if player.currentTime - player.playbackStartOffset > Self.restartThreshold || !hasPrevious {
            // A track that ended replays through play(), which also rewinds it.
            if player.hasEnded { player.play() } else { seek(to: 0) }
            return
        }
        direction = .backward
        failureStreak = 0
        guard let track = movingQueue(retreatQueue) else { return }
        if crossfadeSkip(to: track) { return }
        reconcilePreload()
        begin(track)
    }

    /// Plays a track that is already in the queue.
    func jump(to track: MusicTrack) {
        guard canPlayNow(track) else { return }
        noteActivity()
        let leaving = queue.current
        guard let target = queue.jump(to: track.videoId) else { return }
        noteMixSkip(of: leaving)
        direction = .forward
        failureStreak = 0
        begin(target)
    }

    func seek(to seconds: TimeInterval) {
        guard player.nowPlaying != nil else { return }
        noteActivity()
        player.seek(to: seconds)
        // A seek out of the last stretch of the track: the preload would only sit there, and the window offers it again.
        if preloadOffered != nil, !isInPreloadWindow(position: player.currentTime) { cancelPreload() }
        // A seek past a DJ-length cut: the parked plan mixes out where the playhead already is, so it is withdrawn and the next
        // tick plans the song's usual end (or the next cut) from here.
        if let dj = offeredPlan?.plan, dj.djSection != nil, let out = dj.mixOutSec, out < player.currentTime + Self.beatPrerollLead * activeDeckRate {
            cancelPreload()
        }
        // The jump is not listening time, however short: restart the count from where it landed.
        _ = session?.accumulator.record(position: player.currentTime, isPlaying: false, canFire: false)
        // The stretch heard before it and the one after are two stretches of the watchtime ping.
        session?.watchtime.seek(to: player.currentTime)
        saveSession()
    }

    /// Starts one queue item as its own playback session.
    private func begin(_ track: MusicTrack) {
        touchSession()
        playTask?.cancel()
        playGeneration += 1
        let generation = playGeneration
        cancelPrefetch()
        // The scan was for the song that is left; the new one starts its own once it has loaded.
        radioScanStop()
        trackChangedForAnalysis(to: track.videoId)
        mixTrackChanged()
        trackingTask?.cancel()
        trackingTask = nil
        pendingAdvance = nil
        refreshError = nil
        lastError = nil
        // The track that was playing is over, however it got here: its session closes with its final ping.
        sendFinalPing()
        session = nil
        player.beginLoading(track)
        playTask = Task { [weak self] in
            await self?.resolveAndLoad(track, generation: generation)
        }
        topUpQueue()
        saveSession()
    }

    private func resolveAndLoad(_ track: MusicTrack, generation: Int) async {
        do {
            let stream = try await streamForPlayback(of: track)
            guard generation == playGeneration, !Task.isCancelled else { return }
            session = makeSession(for: stream)
            fillQueueDurations(resolved: stream)
            player.load(stream: stream, track: track)
            fetchTrackingURLs(for: stream, generation: generation)
            analyseCurrent(stream)
            radioScanSoon()
            scheduleMemoryProbe()
        } catch {
            guard generation == playGeneration else { return }
            handleResolveFailure(error)
        }
    }

    private func makeSession(for stream: ResolvedStream) -> Session {
        Session(
            cpn: CPN.make(),
            startedAt: now(),
            trackingURL: stream.playbackTrackingURL,
            watchtimeURL: stream.watchtimeTrackingURL,
            videoId: stream.videoId,
            durationSeconds: stream.durationSeconds
        )
    }

    /// A session ended: what it heard goes to the local listening history, as a play when it was enough. The heard
    /// seconds are the accumulator's, so paused time and seek jumps are not in them. Local only, nothing is sent.
    private func noteListening(of ended: Session) {
        guard let id = ended.videoId else { return }
        let heard = ended.accumulator.playedSeconds
        noteRunSong(id, heard: heard, duration: ended.durationSeconds)
        guard let listening else { return }
        listening.note(
            videoId: id, seconds: heard,
            countsAsPlay: MusicListeningRules.countsAsPlay(heardSeconds: heard, durationSeconds: ended.durationSeconds),
            at: now()
        )
    }

    /// The stream resolved ahead of time when it is still good, otherwise a fresh one.
    private func streamForPlayback(of track: MusicTrack) async throws -> ResolvedStream {
        // A downloaded song plays from its file, whatever was prefetched for it before the download finished.
        if let local = await downloadedStream(of: track.videoId) {
            if prefetched?.videoId == track.videoId { prefetched = nil }
            return local
        }
        // A prefetched file is not used once its download is gone: it would only fail and take the retry.
        if let ready = prefetched, ready.videoId == track.videoId, ready.origin == .network,
           ready.expiresAt > Date().addingTimeInterval(60) {
            prefetched = nil
            return ready
        }
        return try await streamForSource(of: track.videoId)
    }

    /// The song's file as a stream when it is downloaded and on disk, otherwise a fresh stream from the backend. The
    /// restore, playback and prefetch sites all start here. A refresh after a failure does not: it goes to the network.
    private func streamForSource(of videoId: String) async throws -> ResolvedStream {
        if let local = await downloadedStream(of: videoId) { return local }
        // No network: a song with no file has nowhere to play from, and nothing is asked.
        if isOffline { throw URLError(.notConnectedToInternet) }
        return try await backend.resolve(videoId: videoId)
    }

    /// The song can start now: it is downloaded, or the network is there for a stream.
    private func canPlayNow(_ track: MusicTrack) -> Bool {
        !isOffline || isDownloaded(track)
    }

    private func isDownloaded(_ track: MusicTrack) -> Bool {
        downloads?.state(for: track.videoId) == .downloaded
    }

    /// The queue asks the network for no radio, mix or page: there is none, or the account is gone and the song that
    /// plays comes from its file (a request for the account's radio would only end in a sign-out that clears the pages).
    /// A song that streams while signed out is not held back: it behaves as it always did.
    private var holdsBackRequests: Bool {
        if isOffline { return true }
        guard authState == .signedOut, let id = queue.current?.videoId else { return false }
        return downloads?.state(for: id) == .downloaded
    }

    /// The downloaded file, waiting first for the downloads of earlier launches to be read from disk.
    private func downloadedStream(of videoId: String) async -> ResolvedStream? {
        guard let downloads else { return nil }
        await downloads.waitUntilLoaded()
        return downloads.localStream(for: videoId)
    }

    /// Used by the player to replace a dead or expired stream. The playback session carries on.
    private func resolveFreshStream(for track: MusicTrack) async throws -> ResolvedStream {
        // The stream under the player is being replaced: the standby's item is not worth keeping while it settles.
        cancelPreload()
        let generation = playGeneration
        // With no network, or no account to ask with, a file that fails has nowhere to retry: the song stays failed, and
        // nothing is asked (an answer of "signed out" would clear the pages the listener is looking at).
        if isOffline || (authState == .signedOut && player.isPlayingLocalFile) {
            let error = URLError(.notConnectedToInternet)
            refreshError = error
            throw error
        }
        // A downloaded file that fails gets the network stream as its one retry. No id or path in the line.
        if player.isPlayingLocalFile { logger.error("downloaded file failed to play, retrying through the network") }
        do {
            let stream = try await backend.resolve(videoId: track.videoId)
            // Another track may have started meanwhile: its session and error line are not this refresh's to touch.
            guard generation == playGeneration, !Task.isCancelled else { throw CancellationError() }
            refreshError = nil
            attachTrackingURLs(from: stream)
            return stream
        } catch {
            guard generation == playGeneration, !Task.isCancelled else { throw error }
            refreshError = error
            handle(error)
            throw error
        }
    }

    /// Gives the session the ping URLs of `stream` that it does not have yet. The 30 s may have passed while there was
    /// nowhere to send the playback ping: then it goes now.
    private func attachTrackingURLs(from stream: ResolvedStream) {
        guard session?.pingsDropped != true else { return }
        if session?.watchtimeURL == nil { session?.watchtimeURL = stream.watchtimeTrackingURL }
        if session?.trackingURL == nil, let url = stream.playbackTrackingURL {
            session?.trackingURL = url
            if session?.accumulator.claim() == true {
                sendOpeningPings(playback: url, mediaTime: player.currentTime)
            }
        }
    }

    /// A song that plays from its file has no ping URLs, so its listening would never reach History. The file starts at
    /// once; this asks the backend for the song's stream in the background and takes only the ping URLs from it. Offline,
    /// or when the answer fails, the song plays on without pings: nothing is shown, and the file is not touched. An answer
    /// that arrives after another song began, or after the session was cancelled, is dropped.
    private func fetchTrackingURLs(for stream: ResolvedStream, generation: Int) {
        trackingTask?.cancel()
        trackingTask = nil
        // Offline the pings have nowhere to go, and signed out there is no History: a song from its file asks nothing.
        guard stream.origin == .download, !isOffline, authState != .signedOut else { return }
        let videoId = stream.videoId
        trackingTask = Task { [weak self, backend] in
            let fresh: ResolvedStream
            do {
                fresh = try await backend.resolve(videoId: videoId)
            } catch {
                // No id in the line.
                logger.info("tracking URLs for a downloaded song unavailable")
                return
            }
            guard let self, generation == self.playGeneration, !Task.isCancelled else { return }
            self.attachTrackingURLs(from: fresh)
        }
    }

    // MARK: - Queue

    private func handleTrackEnded() {
        // The session stays (a replay is the same session, with nothing left to send); only its final ping goes.
        sendFinalPing()
        direction = .forward
        // Loop song: the same track again, as a fresh playback with its own session. A Next that is waiting for the
        // radio is not lost to the replay: the listener asked to move on, so the track that ended stays ended.
        if loopMode == .song, pendingAdvance != .skipped, let track = queue.current {
            begin(track)
            return
        }
        guard let track = advanceQueue() else {
            // At the end of the queue the player stays on the finished track, as with a single song,
            // unless the radio is still loading (then the next track starts when its page lands)
            // or the queue loops.
            if !awaitRadio(for: .ended) { _ = wrapAround() }
            return
        }
        begin(track)
    }

    /// The engine played the old track to its end and the preloaded one plays on without a gap. Does what `handleTrackEnded`
    /// and `begin` do for the next track, minus the teardown and the load: the engine already has the audio. False when the
    /// preloaded track is not the one the queue would start (the player then treats it as an ordinary end).
    private func handleAdvanced(to track: MusicTrack) -> Bool {
        guard let expected = preloadTarget, expected.videoId == track.videoId,
              let stream = player.preloadedStream, stream.videoId == track.videoId else { return false }
        // Everything is checked above and nothing has changed yet: a refusal leaves the queue and the session to the
        // ordinary end of the track, which advances the queue once and sends the one final ping.
        // Consumed, not withdrawn: the queue moving on below must not take it back from the player.
        preloadOffered = nil
        // What the engine really ran: a plan it downgraded (late, given up, off the grid, no echo path) was a plain fade.
        let planned = offeredPlan?.plan.style
        let ran = player.lastTransitionStyle ?? planned ?? .longBlend
        lastAppliedStyle = isBeatMixOn ? ran : nil
        if let applied = offeredPlan {
            let reason = ran == planned ? applied.plan.fallbackReason : "engineDowngrade"
            if let section = applied.plan.djSection, ran == planned, player.lastTransitionOnGrid != false, let out = applied.plan.mixOutSec {
                log(MusicTransitionLog.djLine(
                    from: applied.inputs.outgoing.videoId, to: applied.inputs.incoming.videoId, section: section, outAt: out
                ))
            }
            if ran != .longBlend || planned != .longBlend || reason == MusicTransitionStylePicker.noAlternative {
                log(MusicTransitionLog.styleLine(
                    from: applied.inputs.outgoing.videoId, to: applied.inputs.incoming.videoId, style: ran,
                    reason: reason, previous: applied.inputs.previousStyle
                ))
            }
        }
        offeredPlan = nil
        // The old session closes with its final ping (it reads the player's position, still the old track's end).
        sendFinalPing()
        direction = .forward
        let replay = loopMode == .song
        if !replay {
            guard let next = advanceQueue(), next.videoId == track.videoId else {
                // The queue disagreed after all (it was edited between the check and here): the ordinary path starts it.
                return false
            }
        }
        startAdvancedSession(stream: stream, adopting: { self.player.adoptPreloaded() })
        return true
    }

    /// The listener skipped onto the preloaded track while Crossfade is on: the engine fades it in over a short crossfade
    /// (`quickFadeSeconds`) instead of loading it. The queue has already moved to `track`. False when the track is not
    /// the one held ready, or the engine cannot fade (then the caller starts the track the ordinary way).
    /// Set while a manual skip moves the queue: the move changes the preload's target, and the preload is exactly what a
    /// crossfading skip plays, so it must not be withdrawn until the skip has decided.
    @ObservationIgnored private var holdsPreloadForSkip = false

    /// Runs a queue move for a manual skip. With Crossfade on and a ready preload the preload survives the move (the skip
    /// takes it or `begin` drops it); in every other case the move is the plain one.
    private func movingQueue(_ move: () -> MusicTrack?) -> MusicTrack? {
        holdsPreloadForSkip = mixesTransitions && preloadOffered != nil && player.preloadIsReady
        let track = move()
        holdsPreloadForSkip = false
        if track == nil { reconcilePreload() }
        return track
    }

    /// A drop swap whose mix-in is more than a bar from where the song would normally start.
    nonisolated static func parksDeepForDropSwap(_ plan: TransitionPlan) -> Bool {
        guard plan.style == .dropSwap, let mixIn = plan.mixInSec else { return false }
        let normal = plan.fallbackIncomingStartSec ?? 0
        return mixIn - normal > max(plan.barSec, 0.5)
    }

    private func crossfadeSkip(to track: MusicTrack) -> Bool {
        guard mixesTransitions, !isOffline, player.isPlaying, !player.hasEnded, pendingAdvance == nil,
              player.preloadedTrack?.videoId == track.videoId, player.preloadIsReady,
              let stream = player.preloadedStream, stream.videoId == track.videoId else { return false }
        // The engine may still refuse (decks without a lease, a fade already running): ask before anything is sent.
        guard player.canCrossfadeToPreloaded else { return false }
        // A drop swap's standby is parked deep in the song (its drop less the lead). A skip would start the song there, so it
        // takes the ordinary load, which starts the song at its normal start.
        if let offered = offeredPlan, offered.inputs.incoming.videoId == track.videoId,
           Self.parksDeepForDropSwap(offered.plan) { return false }
        // A loop extend's standby plays a composition of the song with its intro repeated: a skip takes the ordinary load.
        if let offered = offeredPlan, offered.inputs.incoming.videoId == track.videoId,
           offered.plan.style == .loopExtend { return false }
        // The old track's final ping reads the player's position, so it goes before the engine moves on.
        sendFinalPing()
        // The skip is a quick fade with the incoming loudness match only; the park offset is the plan's own.
        if let offered = offeredPlan, offered.inputs.incoming.videoId == track.videoId {
            var skipInputs = offered.inputs
            skipInputs.manualSkip = true
            var skipPlan = MusicTransitionPlanner.plan(skipInputs)
            skipPlan.incomingStartSec = offered.plan.incomingStartSec
            player.updateTransitionPlan(skipPlan)
        }
        guard player.crossfadeToPreloaded(seconds: Self.quickFadeSeconds) else { return false }
        // The skip played a quick plain fade.
        lastAppliedStyle = player.lastTransitionStyle ?? .longBlend
        preloadOffered = nil
        offeredPlan = nil
        startAdvancedSession(stream: stream, adopting: { self.player.adoptPreloaded() })
        return true
    }

    /// The new track's session, once the engine plays it already: what `begin` does minus the teardown and the load.
    private func startAdvancedSession(stream: ResolvedStream, adopting adopt: () -> Void) {
        let track = stream.videoId
        touchSession()
        playTask?.cancel()
        playGeneration += 1
        let generation = playGeneration
        // The preload is consumed: the prefetch bookkeeping starts over for the track after this one.
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchAttempt = nil
        resetPrefetchRetries()
        if prefetched?.videoId == track { prefetched = nil }
        trackChangedForAnalysis(to: track)
        mixTrackChanged()
        trackingTask?.cancel()
        trackingTask = nil
        pendingAdvance = nil
        refreshError = nil
        lastError = nil
        session = makeSession(for: stream)
        adopt()
        fetchTrackingURLs(for: stream, generation: generation)
        radioScanSoon()
        scheduleMemoryProbe()
        topUpQueue()
        saveSession()
    }

    /// Autoplay plays after a page that has run out, unless Loop playlist starts the page over instead.
    var playsAutoplay: Bool {
        isAutoplayOn && loopMode != .playlist
    }

    /// Autoplay is off on a radio queue: what the radio answers is parked, so nothing waits for it and Up next shows no
    /// loading row for it.
    private var parksRadio: Bool {
        !isAutoplayOn && queue.isPlainRadio
    }

    /// Up next lists the next lap after the last track: Loop playlist is on and the queue loads no further page.
    var listsNextLap: Bool {
        // A tapped song waiting for its first radio has no lap yet: Up next shows the loading rows. Without Autoplay no
        // radio is coming (it is parked, with its next page), so a lone song is its own lap. A mix that can still grow has
        // no lap either: it goes on.
        guard loopMode == .playlist, !(queue.awaitsFirstRadioPage && isAutoplayOn), !queue.mixHasMore else { return false }
        return queue.continuation == nil
    }

    /// The next track of the queue. At the end of a page, with Autoplay, the staged radio joins the queue and its first
    /// track plays.
    private func advanceQueue() -> MusicTrack? {
        // Offline the songs that are not downloaded are stepped over, and no staged radio joins the queue: the queue ends
        // at the last downloaded song.
        if isOffline { return queue.advance(where: canPlayNow) }
        if let track = queue.advance() { return track }
        // Under Mix the staged radio was already placed when it was staged (see `placeStagedRadio`), so Up next, the
        // prefetch, the preload and this hand-over all name the same first song.
        guard playsAutoplay, queue.takeAutoplay() else { return nil }
        if isMixOn { mixAnalyseCurrent = true }
        return queue.advance()
    }

    /// The song before the current one, stepping over the ones that cannot play offline.
    private func retreatQueue() -> MusicTrack? {
        isOffline ? queue.retreat(where: canPlayNow) : queue.retreat()
    }

    /// Loop playlist: starts the queue over from the first track of its play order (a shuffled queue from its shuffled
    /// start; offline the first one that can play). False when the queue does not loop.
    private func wrapAround() -> Bool {
        guard loopMode == .playlist else { return false }
        guard let first = isOffline ? queue.wrapToStart(where: canPlayNow) : queue.wrapToStart() else { return false }
        direction = .forward
        begin(first)
        return true
    }

    /// Only a track that cannot be played at all is skipped; a dropped connection or a server hiccup says nothing about it.
    private static func skipsTrack(_ error: any Error) -> Bool {
        switch error as? MusicError {
        case .unplayable, .noAudioFormat: true
        default: false
        }
    }

    /// A track that cannot be played is skipped; the third failure in a row stops playback but keeps the queue.
    /// A failure that says nothing about the track keeps it selected with the error line and does not skip.
    private func handleResolveFailure(_ error: any Error) {
        if Self.isCancellation(error) || Self.isSignedOut(error) {
            player.stop()
            if Self.isSignedOut(error) { endQueue() }
            handle(error)
            return
        }
        failureStreak += 1
        logger.error("track failed: \(Self.logDescription(of: error), privacy: .public)")
        let exhausted = failureStreak >= Self.maxFailures
        // Offline a song with no file (it vanished from disk) is as good as unplayable: the next downloaded song is tried.
        if Self.skipsTrack(error) || (isOffline && (error as? URLError)?.code == .notConnectedToInternet) {
            if skipToNeighbour() { return }
            // The last song of a page whose mix or radio is still on its way: wait for it (it parks as `.skipped`, a
            // resolve failure leaves no player error) and keep the song selected, as a player failure does.
            if !exhausted, direction == .forward, awaitRadio(for: .skipped) {
                player.failLoading()
            } else {
                player.stop()
                // At the end of the queue there is nothing to keep; after three failures Next must still work.
                if !exhausted { endQueue() }
            }
        } else if exhausted {
            player.stop()
        } else {
            player.failLoading()
        }
        handle(error)
    }

    /// The player gave up on the current stream (recovery failed or was already spent).
    private func handlePlayerFailure() {
        guard player.nowPlaying != nil else { return }
        let cause = refreshError
        refreshError = nil
        if restoredVideoId != nil {
            // The song the last launch left cannot be played: nothing is started in its place, and the session is dropped.
            logger.error("restored session failed: \(cause.map(Self.logDescription(of:)) ?? "engine", privacy: .public)")
            player.stop()
            endQueue()
            return
        }
        // A downloaded song that fails to play signed out stays failed like any other: the queue is the listener's.
        if authState == .signedOut, downloads?.state(for: player.nowPlaying?.videoId ?? "") != .downloaded {
            player.stop()
            endQueue()
            return
        }
        failureStreak += 1
        // The refresh failed for a reason that says nothing about the track: keep it and the queue, as it is.
        if let cause, !Self.skipsTrack(cause) { return }
        if skipToNeighbour() { return }
        // Nothing left to skip to: the failure stays on the player, as it did for a single song.
        // The radio may still add a track; three failures in a row keep the queue so Next still works.
        if failureStreak >= Self.maxFailures { return }
        if direction == .forward, awaitRadio(for: .failed) { return }
        endQueue()
    }

    /// Moves past a failed track in the direction the listener was going. False when it cannot.
    /// Going forward off the end of a Loop playlist wraps to the next lap, unless a mix is still to add songs; the
    /// failure cap still stops a queue in which nothing plays.
    private func skipToNeighbour() -> Bool {
        guard failureStreak < Self.maxFailures else { return false }
        let atEnd = isOffline ? !queue.hasNext(where: canPlayNow) : queue.upcomingCount == 0
        if direction == .forward, atEnd, loopMode == .playlist, !queue.isEmpty, !queue.mixHasMore {
            return wrapAround()
        }
        guard let neighbour = direction == .forward ? advanceQueue() : retreatQueue() else { return false }
        begin(neighbour)
        return true
    }

    /// Ends playback and the queue. The session's final ping goes first (it reads the player's position),
    /// unless the account it belongs to is gone.
    private func stopPlayback(reportFinal: Bool = true) {
        playTask?.cancel()
        playGeneration += 1
        playTask = nil
        endQueue()
        if reportFinal { sendFinalPing() }
        player.stop()
        session = nil
    }

    private func endQueue() {
        trackChangedForAnalysis(to: nil)
        cancelRadio()
        cancelPrefetch()
        pendingAdvance = nil
        prefetched = nil
        queue.clear()
        forgetSession()
    }

    /// Parks `advance` until the radio's next page lands. False when no page is on its way, so the caller ends as before.
    /// A radio parked by Autoplay off is never waited for: whatever lands is out of sight.
    /// A top-up that stopped on the empty-page cap gets a fresh attempt: this one starts with an empty count.
    /// A skip that is already parked stays one: the listener asked to move on, whatever happens to the track meanwhile.
    private func awaitRadio(for advance: PendingAdvance) -> Bool {
        guard !parksRadio else { return false }
        topUpQueue()
        guard radioTask != nil || queueRetryTask != nil else { return false }
        if pendingAdvance != .skipped { pendingAdvance = advance }
        return true
    }

    /// Starts the next track when the parked advance still applies. False when there is nothing to start.
    private func resumePendingAdvance() -> Bool {
        guard let advance = pendingAdvance else { return false }
        let applies: Bool = switch advance {
        case .ended: player.hasEnded
        case .failed: player.error != nil
        case .skipped: true
        }
        // The listener may have replayed the track or retried it since: then the wait is over.
        guard applies, let track = advanceQueue() else {
            if !applies { pendingAdvance = nil }
            return false
        }
        begin(track)
        return true
    }

    /// The radio has nothing more: finish the way the advance would have without it.
    private func settlePendingAdvance() {
        guard let advance = pendingAdvance else { return }
        pendingAdvance = nil
        switch advance {
        case .ended:
            // The track is still the finished one unless the listener replayed it meanwhile.
            if player.hasEnded { _ = wrapAround() }
        case .skipped:
            // A radio that Autoplay off parked is not coming, but the song is not cut short: it plays on and stops at its
            // end, and the radio comes back with Autoplay.
            // Offline it is the same: nothing is coming, and the song plays on to its end.
            if !wrapAround(), !parksRadio, !isOffline { stopPlayback() }
        case .failed:
            endQueue()
        }
    }

    // MARK: - Radio and page paging

    private func startRadio(seed: String, emptyPages: Int = 0) {
        cancelRadio()
        let generation = radioGeneration
        // The mix of a mix page's first ask: read now, the queue may be another one by the time the task runs.
        let mixId = queue.pendingMixPlaylistId
        // The radio that follows a page is for the page's last own song: a change of that song makes the answer stale.
        pageRadioSeed = queue.isPage && queue.mixPlaylistId == nil ? seed : nil
        radioTask = Task { [weak self] in
            await self?.fetchQueuePage(
                source: .radio(seedVideoId: seed), continuation: nil, generation: generation, mixId: mixId,
                emptyPages: emptyPages
            )
        }
    }

    /// Drops the radio of a playlist or album page that was asked for a song other than the page's last own song in the
    /// play order, which a shuffle, its undoing and the listener's edits move: the staged one, and a request still
    /// loading, whose answer is then ignored. The caller asks again for the new last song by the usual rules. True when
    /// something was dropped.
    @discardableResult
    private func dropStaleRadio() -> Bool {
        var dropped = false
        if let seed = pageRadioSeed, queue.isStaleRadioSeed(seed) {
            cancelRadio()
            dropped = true
        }
        if queue.dropStaleAutoplay() { dropped = true }
        return dropped
    }

    /// Asks for the next page of the radio or of the playlist page, or for a radio to follow, when the queue needs it.
    /// One fetch at a time; a fetch that starts replaces a retry that was waiting. `emptyPages` counts pages in a row
    /// that added nothing after de-duplication. A page's radio that no longer fits its last song is dropped first.
    private func topUpQueue(emptyPages: Int = 0) {
        // No network (or no account, for a song from its file): no radio, mix or page is asked for. The ask that was held
        // back is made when the network returns (see `connectivityChanged`).
        guard !holdsBackRequests, emptyPages < Self.maxEmptyPages else { return }
        // A Next parked behind the radio that was dropped goes on to the song that is now next (a reshuffle can give it
        // one); with none it waits for the new radio, or settles if none is asked.
        let droppedStale = dropStaleRadio()
        defer {
            if droppedStale, !resumePendingAdvance(), radioTask == nil, queueRetryTask == nil { settlePendingAdvance() }
        }
        guard radioTask == nil else { return }
        // A queue running out with nothing left to page asks for a radio: the first radio of a tapped song with
        // Autoplay (Loop playlist or not), then with Autoplay and Loop playlist off the radio of the last track. A
        // playlist or album page stages it as soon as it has loaded in full, whatever the number of songs left, so
        // Up next shows the recommendations from the start and the hand-over is gapless (it is for the page's last own
        // song in the play order, so under a shuffle for the song that plays right before it); it asks for at most
        // `MusicQueue.eagerAskLimit` songs that way, so a radio that answers nothing is not asked for every song. A mix
        // page, a tapped-song radio and a radio that has run out ask when `MusicQueue.refillThreshold` songs are left;
        // a radio that has run out carries on from a new seed. A radio that could not be reached is asked for again by
        // the next top-up.
        // A mix page is the exception: its mix is the playlist, so it is asked for its songs whatever Autoplay and Loop
        // playlist say, and what it answers joins the queue itself (see `fetchQueuePage`).
        if let seed = queue.refillSeed, queue.mixHasMore || (queue.awaitsFirstRadioPage && isAutoplayOn) || playsAutoplay {
            startRadio(seed: seed, emptyPages: emptyPages)
            return
        }
        // Without Autoplay a radio queue asks for nothing (its radio and next page are parked, see `setAutoplay`), unless
        // a mix still has pages to load; a page still loads its own later pages.
        if case .radio = queue.source, !isAutoplayOn, !queue.mixHasMore { return }
        guard queue.needsMore, let source = queue.source, let continuation = queue.continuation else { return }
        cancelQueueRetry()
        let generation = radioGeneration
        radioTask = Task { [weak self] in
            await self?.fetchQueuePage(source: source, continuation: continuation, generation: generation, emptyPages: emptyPages)
        }
    }

    /// `mixPlaylistId` is the mix to ask for its first songs after the seed, when the queue is a mix page still waiting for
    /// them.
    private func requestQueuePage(
        source: MusicQueue.Source, continuation: String?, mixPlaylistId: String? = nil
    ) async throws -> MusicQueuePage {
        switch (source, continuation) {
        case (.radio(let seed), nil):
            // A mix page asks its mix; the backend does not fall back, so a mix YouTube refuses comes back as an error.
            if let mixPlaylistId { return try await backend.mix(playlistId: mixPlaylistId, afterVideoId: seed) }
            // The radio that follows a playlist or an album is its automix, when the page has one (the backend falls
            // back to the song's radio if YouTube offers none); every other radio is the song's own.
            if queue.isPage, let playlistId = queue.automixPlaylistId {
                return try await backend.autoplay(afterVideoId: seed, playlistId: playlistId)
            }
            return try await backend.radio(seedVideoId: seed)
        case (.radio(let seed), let token?):
            return try await backend.moreRadio(seedVideoId: seed, continuation: token)
        case (.page(let browseId), let token?):
            return try await backend.moreTracks(browseId: browseId, continuation: token)
        case (.page, nil):
            return MusicQueuePage(tracks: [], continuation: nil)
        }
    }

    /// `mixId` is the mix the first ask of a mix page goes to, fixed when the ask was started (see `startRadio`).
    private func fetchQueuePage(
        source: MusicQueue.Source, continuation: String?, generation: Int, mixId: String? = nil, emptyPages: Int = 0
    ) async {
        // Whatever the page did to the queue (songs added, staged or parked, a continuation dropped) is remembered.
        defer { saveSession() }
        let page: MusicQueuePage
        do {
            page = try await requestQueuePage(source: source, continuation: continuation, mixPlaylistId: mixId)
        } catch {
            // No more tracks is not an error: the song keeps playing, the queue just does not grow.
            guard generation == radioGeneration else { return }
            radioTask = nil
            logger.info("queue page unavailable: \(Self.logDescription(of: error), privacy: .public)")
            if Self.isSignedOut(error) {
                if case .radio(let seed) = source, continuation == nil { queue.noteAsked(seed) }
                if mixId != nil { queue.forgetMix() }
                queue.clearContinuation()
                handle(error)
                settlePendingAdvance()
                return
            }
            if MusicError.endsPaging(error), mixId != nil {
                // A mix that is turned down or cannot be read is not a mix: the page follows the Autoplay rules like any
                // playlist, so the radio of the same last song is still to ask. Forgetting the mix is the progress, so
                // this is not counted as an empty page.
                queue.forgetMix()
                topUpQueue(emptyPages: emptyPages)
            } else if MusicError.endsPaging(error) {
                // A page that cannot be read or that the server rejects would fail the same way again: stop paging,
                // and never ask that radio again. The queue then refills from the next seed, counted as an empty
                // page so a server that rejects every request cannot keep it asking.
                if case .radio(let seed) = source, continuation == nil { queue.noteAsked(seed) }
                if continuation != nil { queue.clearContinuation() }
                topUpQueue(emptyPages: emptyPages + 1)
            } else {
                // Anything else (network, 5xx) may pass: the same request is asked for again after a wait, unless the
                // radio is parked: the next top-up under Autoplay on asks for it. With the network gone there is no use in
                // waiting: the top-up that follows its return asks for it, and the waits are not spent.
                if !parksRadio, !holdsBackRequests { scheduleQueueRetry(emptyPages: emptyPages) }
            }
            if radioTask == nil, queueRetryTask == nil { settlePendingAdvance() }
            return
        }
        guard generation == radioGeneration, !Task.isCancelled else { return }
        radioTask = nil
        queueRetryAttempts = 0
        if mixId != nil, page.continuation == nil, queue.addableCount(of: page.tracks) == 0 {
            // A mix with nothing new to play (no songs, or only ones the queue has) is as good as turned down. The seed is
            // not marked asked, so the page's own rules ask the radio of the same last song.
            queue.forgetMix()
            topUpQueue(emptyPages: emptyPages)
            if radioTask == nil, queueRetryTask == nil { settlePendingAdvance() }
            return
        }
        if case .radio = source, continuation == nil, mixId == nil, queue.mixPlaylistId != nil, !isAutoplayOn {
            // The radio a dry mix hands over to was asked for with Autoplay on, and Autoplay went off while it was on its
            // way. Without Autoplay the mix stays a mix and plays out its own songs, so the answer is dropped and its seed
            // is not marked asked: Autoplay on asks for it again.
            if radioTask == nil, queueRetryTask == nil { settlePendingAdvance() }
            return
        }
        let added: Int
        if case .radio(let seed) = source, continuation == nil, queue.isPage, mixId == nil {
            // The radio that follows a page waits beside it until the page runs out.
            added = queue.stageAutoplay(page.tracks, continuation: page.continuation, seed: seed)
            if added > 0, isMixOn { placeStagedRadioSoon() }
            if added > 0 { radioScanSoon() }
        } else {
            // The radio has answered: from here the queue is the radio's, even if it had nothing new to add. A mix's
            // answer joins the queue itself and the queue stays the mix's; a plain radio asked once the mix has run dry
            // makes it the radio's.
            if case .radio(let seed) = source {
                queue.adoptRadio(seedVideoId: seed)
                if mixId == nil, continuation == nil { queue.forgetMix() }
            }
            if parksRadio {
                // Autoplay went off while this was on its way: the songs wait out of sight for Autoplay to come back,
                // and nothing is waiting for them.
                queue.parkAnswer(page.tracks, continuation: page.continuation)
                if radioTask == nil, queueRetryTask == nil { settlePendingAdvance() }
                return
            }
            added = queue.append(page.tracks, continuation: page.continuation, using: &shuffleGenerator, inOrder: isMixOn)
            if added > 0 { mixQueueGrew() }
            if added > 0 { radioScanSoon() }
        }
        if added > 0, resumePendingAdvance() { return }
        // Pages overlap heavily: one that adds nothing still has a continuation, so ask again at once,
        // up to `maxEmptyPages` in a row. The next track change starts a fresh attempt.
        topUpQueue(emptyPages: added > 0 ? 0 : emptyPages + 1)
        if radioTask == nil, queueRetryTask == nil { settlePendingAdvance() }
    }

    /// Asks the top-up again after a wait that doubles each time, so a queue page or radio lost to the network still
    /// arrives. After `maxQueueRetries` the queue waits for the next track change.
    private func scheduleQueueRetry(emptyPages: Int) {
        guard queueRetryAttempts < Self.maxQueueRetries else { return }
        let delay = queueRetryDelay * (1 << queueRetryAttempts)
        queueRetryAttempts += 1
        let generation = radioGeneration
        queueRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, generation == self.radioGeneration else { return }
            self.queueRetryTask = nil
            self.topUpQueue(emptyPages: emptyPages)
            if self.radioTask == nil { self.settlePendingAdvance() }
        }
    }

    private func cancelQueueRetry() {
        queueRetryTask?.cancel()
        queueRetryTask = nil
    }

    /// Loop or Autoplay changed: the top-up is decided again now. A retry still waiting would hold a parked Next back
    /// for a refill the new mode may not want, so it is dropped, and a Next with nothing left to wait for goes ahead. A
    /// radio still loading for a queue that now parks it is not waited for either: it lands out of sight.
    private func topUpQueueAfterModeChange() {
        cancelQueueRetry()
        topUpQueue()
        guard radioTask == nil || parksRadio, queueRetryTask == nil, !resumePendingAdvance() else { return }
        settlePendingAdvance()
    }

    private func noteQueueFilling() {
        let filling = (radioTask != nil && !parksRadio) || queueRetryTask != nil
        if filling != isFillingQueue { isFillingQueue = filling }
    }

    private func cancelRadio() {
        radioGeneration += 1
        radioTask?.cancel()
        radioTask = nil
        cancelQueueRetry()
    }

    // MARK: - Prefetch

    private func prefetchNextIfNeeded(position: TimeInterval) {
        // Offline the next song is a file or it does not play: there is no stream to resolve ahead.
        guard !isOffline else { return }
        let duration = player.duration
        let target = prefetchTarget
        let lead = leadTime
        // DJ-length songs: the song is cut earlier than its end, so the next one is resolved and analysed that much earlier too.
        let djEarly = target.map { djShift(toward: $0.videoId) } ?? 0
        // Measured to the trimmed end like the preload window. With analysis on the window opens `beatLead` early, so a
        // song that is not resolved early (signed out) is still resolved before its smart or beat window.
        let resolveLead = analysis != nil && loopMode != .song ? max(lead, Self.beatLead) : lead
        let inWindow = duration > lead * 2 && preloadLead(for: nil).end - position <= resolveLead + djEarly
        if inWindow, let next = target, resolveFailed == next.videoId, prefetchAttempt == next.videoId, prefetched == nil {
            resolveFailed = nil
            resolveRetried = next.videoId
            prefetchAttempt = nil
        }
        // With analysis on, the next song is resolved and analysed as soon as it has settled as next, whatever the
        // current song's length; the preload keeps its own window.
        // While the radio scan still looks for the best next song, the early prefetch waits: it would fetch and analyse a
        // song that the scan may replace. The window's own prefetch is the backstop and freezes the best pick so far.
        let scanHolds = radioScanRunning && !inWindow && duration > lead * 2
        let early = analysisWantsNext && !scanHolds && nextSongSettled(target?.videoId)
        guard early || inWindow, let next = target, prefetchAttempt != next.videoId else { return }
        prefetchAttempt = next.videoId
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            guard let stream = try? await self.streamForSource(of: next.videoId) else {
                // One more try at the preload window; after that the playback path deals with it.
                if !Task.isCancelled, self.prefetchAttempt == next.videoId, self.resolveRetried != next.videoId {
                    self.resolveFailed = next.videoId
                }
                return
            }
            guard !Task.isCancelled, self.prefetchAttempt == next.videoId else { return }
            self.prefetched = stream
            self.startAnalysis(for: stream)
            self.offerPreload(position: self.player.currentTime)
        }
    }

    /// The next song is worth analysing: a provider is there, and it is neither offline, signed out nor Loop song.
    private var analysisWantsNext: Bool {
        analysis != nil && !isOffline && authState != .signedOut && loopMode != .song
    }

    /// True once `id` has been the next song for `analysisSettle` seconds; a different next song starts the count again.
    private func nextSongSettled(_ id: String?) -> Bool {
        guard let id else {
            nextSeen = nil
            return false
        }
        if nextSeen?.id != id { nextSeen = (id, now()) }
        guard let since = nextSeen?.since else { return false }
        return now().timeIntervalSince(since) >= Self.analysisSettle
    }

    // MARK: - Analysis and the track cache

    /// Hands the next song to the analysis side: a network song is fetched whole into the track cache (its file is kept
    /// for the preload), a downloaded one is analysed from its own file. Not offline, not signed out, not Loop song, and
    /// one job at a time: a job for a song that is no longer next is not cancelled when it is already running (its row
    /// is still stored, only its file goes), and the new job waits behind it.
    private func startAnalysis(for stream: ResolvedStream) {
        guard let analysis, !isOffline, authState != .signedOut, loopMode != .song,
              stream.videoId != analysisCurrentID, analysisTarget != stream.videoId else { return }
        let id = stream.videoId
        let previous = analysisTail
        if let old = analysisTarget { retireSpeculativeAnalysis(old) }
        analysisTarget = id
        nextRowSettled = nil
        let wantsFile = stream.origin == .network
        // The song is next again while its own job still runs: that job is taken back, it keeps the file it is fetching.
        if let running = analysisRunning.first(where: { $0.value == id })?.key, let job = analysisJobs[running] {
            analysisTargetJob = running
            if wantsFile { heldCacheJobs[id] = running }
            analysisTask = job.task
            return
        }
        analysisJobCounter += 1
        let job = analysisJobCounter
        analysisTargetJob = job
        if wantsFile { heldCacheJobs[id] = job }
        // Behind the cleanup of earlier jobs, so a late cancel or discard for this song cannot hit this fetch, and behind
        // the job before it, so only one analysis runs at a time.
        let cleanup = analysisCleanupTask
        let task = Task { [weak self] in
            await previous?.value
            await cleanup?.value
            guard let self else { return }
            // Only one analysis runs at a time: the one the radio scan has under way lands first.
            _ = await self.radioScanInFlight?.value
            defer {
                self.analysisJobs[job] = nil
                self.analysisRunning[job] = nil
            }
            guard !Task.isCancelled else { return }
            // Running until it has landed, row read and file settled, so a song that is next again can take it back.
            self.analysisRunning[job] = id
            let outcome = await analysis.ensure(stream: stream, wantsFile: wantsFile)
            // The row the job stored is read before the preload is offered again, so a plan can use it.
            if !Task.isCancelled, self.analysisTarget == id {
                await self.readTransitionRow(id)
                if self.analysisTarget == id { self.nextRowSettled = id }
            }
            guard self.heldCacheJobs[id] == job, !Task.isCancelled else {
                // The song stopped being next while the file was coming: nobody will play it. A newer job for the same
                // song owns the file now and keeps it.
                if wantsFile, self.heldCacheJobs[id] == nil, case .analysed(file: .some) = outcome {
                    self.queueAnalysisCall { await $0.discard(videoId: id) }
                }
                return
            }
            if case .analysed(file: let file?) = outcome {
                self.cachedFile = (id, file)
            }
            // A row that landed lets a waiting offer go ahead (a file alone did before; the offer is the same call).
            self.offerPreload(position: self.player.currentTime)
        }
        analysisJobs[job] = (id, task)
        analysisTask = task
        analysisTail = task
    }

    /// The song that starts playing gets its analysis asked for once, when it has no fresh entry (the coordinator checks
    /// the store). A downloaded song is analysed from its file by the coordinator, so nothing is fetched for it; a song
    /// that plays from the cache was analysed before it was offered. Not offline, not signed out. Playback is untouched.
    private func analyseCurrent(_ stream: ResolvedStream) {
        guard let analysis, !isOffline, authState != .signedOut, stream.origin != .trackCache,
              currentAnalysisAsked != stream.videoId, analysisCurrentID == stream.videoId else { return }
        currentAnalysisAsked = stream.videoId
        currentAnalysisTask = Task { [weak self] in
            _ = await analysis.ensure(stream: stream, wantsFile: false)
            await self?.readTransitionRow(stream.videoId)
        }
    }

    /// The song was next but is not any more. A job that is analysing now is left to finish so its row is stored (its
    /// file is discarded when it lands, nobody will play it); one still waiting or already done is dropped.
    private func retireSpeculativeAnalysis(_ id: String) {
        guard analysisTarget == id else { return }
        guard analysisRunning[analysisTargetJob] == id else { return dropSpeculativeAnalysis(id) }
        analysisTarget = nil
        analysisTargetJob = 0
        if cachedFile?.videoId == id { cachedFile = nil }
        heldCacheJobs.removeValue(forKey: id)
    }

    /// The song was going to be next but is not: its job stops and its file goes now.
    private func dropSpeculativeAnalysis(_ id: String) {
        guard analysisTarget == id else { return }
        analysisTask?.cancel()
        analysisTask = nil
        analysisTarget = nil
        analysisTargetJob = 0
        if cachedFile?.videoId == id { cachedFile = nil }
        let held = heldCacheJobs.removeValue(forKey: id) != nil
        queueAnalysisCall { provider in
            await provider.cancel(videoId: id)
            if held { await provider.discard(videoId: id) }
        }
    }

    /// The player is on `id` now (nil: on nothing). The song that was playing releases its file; a song fetched for next
    /// that was passed over is dropped; a job for any other song stops.
    private func trackChangedForAnalysis(to id: String?) {
        guard analysis != nil else { return }
        let leaving = analysisCurrentID
        analysisCurrentID = id
        beatFallbackFor = nil
        // The mirror keeps the playing song and the one being fetched for next, nothing older.
        transitionAnalyses = transitionAnalyses.filter { $0.key == id || $0.key == analysisTarget }
        if let id, analysisReader != nil {
            transitionReadTask = Task { [weak self] in await self?.readTransitionRow(id) }
        }
        // The job for the song that was playing is not worth finishing once the player left it.
        if let asked = currentAnalysisAsked, asked != id {
            currentAnalysisTask?.cancel()
            currentAnalysisTask = nil
            currentAnalysisAsked = nil
            queueAnalysisCall { await $0.cancel(videoId: asked) }
        }
        // Nothing is playing any more (sign-out, end of queue): every job left stops too. Cancelling the task is what
        // reaches the coordinator, which ignores a plain cancel while a job that wants the file is waiting.
        if id == nil {
            for (_, job) in analysisJobs {
                job.task.cancel()
                let running = job.id
                queueAnalysisCall { await $0.cancel(videoId: running) }
            }
        }
        if let target = analysisTarget, target != id {
            if id == nil { dropSpeculativeAnalysis(target) } else { retireSpeculativeAnalysis(target) }
        }
        if let id, analysisTarget == id {
            analysisTarget = nil
            analysisTargetJob = 0
        }
        if cachedFile != nil, cachedFile?.videoId != id { cachedFile = nil }
        if let leaving, leaving != id {
            heldCacheJobs.removeValue(forKey: leaving)
            queueAnalysisCall { await $0.release(videoId: leaving) }
        }
    }

    /// Provider calls go out one after another in the order they were made, so a release never overtakes a cancel.
    private func queueAnalysisCall(_ call: @escaping @Sendable (any MusicAnalysisProviding) async -> Void) {
        guard let analysis else { return }
        let previous = analysisCleanupTask
        analysisCleanupTask = Task {
            await previous?.value
            await call(analysis)
        }
    }

    /// The track that plays after this one. Loop song replays the same track, so that is the stream worth resolving
    /// ahead. At the end of the queue it is the staged radio's first track, or the first track again under Loop playlist
    /// (not while a mix can still grow: its next song is not known yet).
    private var prefetchTarget: MusicTrack? {
        if loopMode == .song { return queue.current }
        if let next = queue.upcoming.first { return next }
        if playsAutoplay { return queue.autoplay.first }
        if loopMode == .playlist, queue.continuation == nil, !queue.mixHasMore { return queue.tracks.first }
        return nil
    }

    private func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchAttempt = nil
        resetPrefetchRetries()
        cancelPreload()
    }

    private func resetPrefetchRetries() {
        resolveFailed = nil
        resolveRetried = nil
        expiryRefreshed = nil
    }

    // MARK: - Preload (gapless)

    /// The track the engine may be given to start the moment this one ends, only when it is certain: Loop song replays the
    /// track, otherwise it is the next queued track, or the staged autoplay's first one when the page has run out. Not
    /// offline (songs are stepped over there), not while a Next waits for the radio, and not for a wrapped lap or a mix
    /// that can still grow (their next song is not known yet).
    private var preloadTarget: MusicTrack? {
        guard !isOffline, pendingAdvance == nil else { return nil }
        if loopMode == .song { return queue.current }
        if let next = queue.upcoming.first { return next }
        if playsAutoplay { return queue.autoplay.first }
        return nil
    }

    private func isInPreloadWindow(position: TimeInterval) -> Bool {
        let duration = player.duration
        let (lead, end) = preloadLead(for: prefetched)
        return duration > lead * 2 && end - position <= lead
    }

    /// How long before the end the next track is resolved and preloaded: a crossfade starts that much earlier, so its
    /// length is added.
    private var leadTime: TimeInterval { Self.prefetchLead + effectiveCrossfadeSeconds }

    /// Trims and smart fades only apply to a normal transition: not Loop song, not an album in order.
    private var plansTransitions: Bool { loopMode != .song && !playsAlbumInOrder }

    /// The stored row of the song when it is fresh for exactly this stream (version, format, duration, usable span).
    private func freshRow(for stream: ResolvedStream?) -> MusicAnalysis? {
        guard let stream, let row = transitionAnalyses[stream.videoId],
              MusicTransitionPlanner.isFresh(row, for: stream) else { return nil }
        return row
    }

    /// The preload lead and the item time it is measured to. The audible end of a song with a fresh row is its trimmed
    /// end. A pair that can fade smartly (the playing song analysed, the next one analysed or about to be) starts its
    /// fade up to `maxLead` seconds earlier, so its window opens that much earlier: 15 + 22 = 37 s.
    private func preloadLead(for next: ResolvedStream?) -> (lead: TimeInterval, end: TimeInterval) {
        let duration = player.duration
        guard plansTransitions, let row = freshRow(for: player.currentStream) else { return (leadTime, duration) }
        let end = MusicTransitionPlanner.trimmedEnd(of: row, duration: duration) ?? duration
        let smart = Self.prefetchLead + MusicTransitionPlanner.maxLead
        if isBeatMixOn, mixesTransitions, let next, beatFallbackFor != next.videoId, row.usableGrid != nil,
           freshRow(for: next)?.usableGrid != nil || isAwaitingRow(for: next), duration > Self.beatLead * 2 {
            return (Self.beatLead, end - djShift(toward: next.videoId))
        }
        guard mixesTransitions, isMixOn, let next, freshRow(for: next) != nil || isAwaitingRow(for: next), duration > smart * 2 else {
            return (leadTime, end)
        }
        return (smart, end)
    }

    /// Tier 4b P3: how many seconds earlier than the usual mix-out the DJ-length cut falls for the playing song, 0 when the rule
    /// does not apply to it. The preload window is measured from the song's end moved back by this much, so the next song is
    /// parked in time for the early mix-out.
    private func djShift(toward nextId: String) -> TimeInterval {
        guard isDJLengthOn, let current = player.currentStream, let row = freshRow(for: current),
              let end = MusicTransitionPlanner.trimmedEnd(of: row, duration: player.duration) else { return 0 }
        let flags = transitionFlags(from: current.videoId, to: nextId)
        let inputs = MusicTransitionInputs(
            outgoing: MusicTransitionSide(
                videoId: current.videoId, durationSeconds: current.durationSeconds, analysis: row,
                vocalIntervals: vocalLookahead?.intervals(for: current.videoId)
            ),
            incoming: MusicTransitionSide(videoId: nextId, durationSeconds: nil, analysis: nil),
            crossfadeOn: mixesTransitions, settingSeconds: crossfadeSeconds, albumInOrder: playsAlbumInOrder,
            loopSong: loopMode == .song, cleanStartFlag: flags.startsClean, cleanPairFlag: flags.pairIsClean,
            beatMixEnabled: isBeatMixOn && beatFallbackFor != nextId, bassSwapAvailable: true, vocalGuardEnabled: isVocalGuardOn,
            djLength: true, runEnergy: runEnergy
        )
        guard let cut = MusicDJLength.cut(inputs, smartEnd: end), cut.point > player.currentTime else { return 0 }
        return max(0, cut.normal - cut.point)
    }

    /// A job for the song is running and has not stored its row yet.
    private func isAwaitingRow(for stream: ResolvedStream) -> Bool {
        analysisReader != nil && analysis != nil && analysisTarget == stream.videoId && analysisTask != nil
            && nextRowSettled != stream.videoId && freshRow(for: stream) == nil
    }

    /// Hands the player the prefetched stream of the next track when it is certain and the window has opened. Waits for
    /// the next song's analysis while its job runs, until `analysisDeadline` seconds are left to the trimmed end.
    private func offerPreload(position: TimeInterval) {
        syncCrossfade()
        guard let stream = prefetched, let target = preloadTarget, stream.videoId == target.videoId,
              preloadOffered != target.videoId, player.isPlaying, !player.hasEnded,
              isInPreloadWindow(position: position) else { return }
        let (_, end) = preloadLead(for: stream)
        if isAwaitingRow(for: stream), end - position > Self.analysisDeadline { return }
        // A stream resolved early may be about to expire by now: it is replaced once before it is offered, unless the
        // preload plays from the cache file anyway.
        if stream.origin == .network, cachedFile?.videoId != stream.videoId, expiryRefreshed != stream.videoId,
           stream.expiresAt <= Date().addingTimeInterval(60) {
            expiryRefreshed = stream.videoId
            prefetched = nil
            prefetchAttempt = nil
            return
        }
        preloadOffered = target.videoId
        let plan = transitionPlan(for: stream)
        player.preload(stream: preloadStream(for: stream), track: target, plan: plan?.plan)
        guard let plan, player.preloadedTrack?.videoId == target.videoId else { return }
        offeredPlan = plan.offered
        log(MusicTransitionLog.planLine(
            from: plan.offered.inputs.outgoing.videoId, to: stream.videoId, plan: plan.plan,
            outgoingDuration: plan.offered.inputs.outgoing.durationSeconds,
            vocal: (plan.offered.inputs.outgoing.vocalIntervals != nil, plan.offered.inputs.incoming.vocalIntervals != nil)
        ))
        if let line = MusicTransitionLog.vocalGuardLine(
            from: plan.offered.inputs.outgoing.videoId, to: stream.videoId, plan: plan.plan
        ) { log(line) }
        logBeat(plan.offered)
    }

    /// Starts the lyrics lookup for the playing song and the next one (once each). Called on every playing tick, so it
    /// begins when the track starts and as soon as the next song is known, never tied to the prefetch. Only with beat mix,
    /// the vocal guard and the crossfade on and a transition to plan (not album in order, not Loop song). The network part
    /// (YouTube Music only) is skipped offline. Never awaited by the plan.
    func startVocalLookahead() {
        guard let lookahead = vocalLookahead, isVocalGuardOn, isBeatMixOn, mixesTransitions, plansTransitions,
              let current = player.currentStream else { return }
        let network = !isOffline
        let next = preloadTarget
        let nextDuration = prefetched?.videoId == next?.videoId ? prefetched?.durationSeconds : nil
        let sides: [(id: String, duration: Double?, track: MusicTrack?)] = [
            (current.videoId, current.durationSeconds, player.nowPlaying),
            (next?.videoId ?? "", nextDuration ?? next?.durationSeconds.map(Double.init), next),
        ]
        for side in sides where !lookahead.hasRequested(side.id) {
            guard let track = side.track, track.videoId == side.id, let duration = side.duration else { continue }
            let query = LyricsQuery(
                videoId: track.videoId, title: track.title, artist: track.artist, album: track.album, duration: duration
            )
            Task { await lookahead.prepare(query, duration: duration, allowNetwork: network) }
        }
    }

    /// The beat line of an offered plan: the beat plan, or why a pair that could have beat-mixed did not.
    private func logBeat(_ offered: OfferedPlan) {
        let outgoing = offered.inputs.outgoing
        let incoming = offered.inputs.incoming
        let bpmA = (outgoing.grid ?? outgoing.analysis?.usableGrid)?.bpm
        let bpmB = (incoming.grid ?? incoming.analysis?.usableGrid)?.bpm
        if offered.plan.mode == .beat {
            log(MusicTransitionLog.beatPlanLine(
                from: outgoing.videoId, to: incoming.videoId, plan: offered.plan, bpmA: bpmA, bpmB: bpmB
            ))
        } else if offered.inputs.beatMixEnabled, offered.inputs.crossfadeOn, let reason = offered.plan.fallbackReason {
            log(MusicTransitionLog.beatFallbackLine(
                from: outgoing.videoId, to: incoming.videoId, reason: reason, bpmA: bpmA, bpmB: bpmB,
                gridFail: offered.plan.gridFail
            ))
        }
    }

    /// A beat mix whose song is not parked and prerolled by `beatPrerollLead` before the mix point cannot start on its
    /// grid: it is given up for the smart plan of the same pair (the preload is offered again, planned without beats).
    private func giveUpBeatMixIfNotReady(position: TimeInterval) {
        guard let offered = offeredPlan, offered.plan.mode == .beat, let mixOut = offered.plan.mixOutSec,
              preloadOffered == offered.inputs.incoming.videoId, !player.preloadIsReady,
              position >= mixOut - Self.beatPrerollLead * activeDeckRate else { return }
        let outgoing = offered.inputs.outgoing
        let incoming = offered.inputs.incoming
        log(MusicTransitionLog.beatFallbackLine(
            from: outgoing.videoId, to: incoming.videoId, reason: "notReady",
            bpmA: (outgoing.grid ?? outgoing.analysis?.usableGrid)?.bpm,
            bpmB: (incoming.grid ?? incoming.analysis?.usableGrid)?.bpm
        ))
        beatFallbackFor = incoming.videoId
        cancelPreload()
    }

    /// The plan for the transition from the playing song into `next`, with the inputs it came from. Nil when the player
    /// holds no current stream.
    private func transitionPlan(for next: ResolvedStream) -> (plan: TransitionPlan, offered: OfferedPlan)? {
        guard let current = player.currentStream else { return nil }
        let outgoing = freshRow(for: current)
        let incoming = freshRow(for: next)
        let flags = transitionFlags(from: current.videoId, to: next.videoId)
        var inputs = MusicTransitionInputs(
            outgoing: MusicTransitionSide(
                videoId: current.videoId, durationSeconds: current.durationSeconds, analysis: outgoing,
                youtubeLoudnessDb: current.loudnessDb, vocalIntervals: vocalLookahead?.intervals(for: current.videoId),
                deckRate: activeDeckRate
            ),
            incoming: MusicTransitionSide(
                videoId: next.videoId, durationSeconds: next.durationSeconds, analysis: incoming,
                youtubeLoudnessDb: next.loudnessDb, vocalIntervals: vocalLookahead?.intervals(for: next.videoId)
            ),
            crossfadeOn: mixesTransitions, settingSeconds: crossfadeSeconds, albumInOrder: playsAlbumInOrder,
            loopSong: loopMode == .song, cleanStartFlag: flags.startsClean, cleanPairFlag: flags.pairIsClean,
            manualSkip: false, beatMixEnabled: isBeatMixOn && beatFallbackFor != next.videoId,
            bassSwapAvailable: true, vocalGuardEnabled: isVocalGuardOn, previousStyle: lastAppliedStyle,
            incomingLocal: MusicLoopExtend.isLocal(preloadStream(for: next).origin),
            djLength: isDJLengthOn, runEnergy: runEnergy
        )
        inputs.plainFade = !isMixOn
        // A mix point the engine cannot reach in time is not offered: the playhead plus the preroll is the earliest.
        inputs.earliestMixOutSec = player.currentTime + Self.beatPrerollLead * activeDeckRate
        let plan = MusicTransitionPlanner.plan(inputs)
        let rows = Set([outgoing, incoming].compactMap { $0?.videoId })
        return (plan, OfferedPlan(inputs: inputs, plan: plan, plannedWithRows: rows))
    }

    /// The no-mix flags for a transition: whether the incoming song is flagged "always start clean", and whether this
    /// pair (outgoing into incoming) is. Both false with no flag store.
    private func transitionFlags(from outgoingId: String, to incomingId: String) -> (startsClean: Bool, pairIsClean: Bool) {
        guard let mixFlags else { return (false, false) }
        return (mixFlags.startsClean(incomingId), mixFlags.pairIsClean(from: outgoingId, to: incomingId))
    }

    /// The song before the playing one in the queue, when `track` is the playing song.
    private func previousTrack(of track: MusicTrack) -> MusicTrack? {
        guard queue.current?.videoId == track.videoId, let index = queue.currentIndex, index > 0 else { return nil }
        return queue.tracks[index - 1]
    }

    /// The no-mix entries for a song's menu: its own, and, with `includingPrevious` for the song playing now, the pair
    /// with the song before it. Empty when there is no flag store.
    func mixItems(for track: MusicTrack, includingPrevious: Bool) -> [MusicMixMenuItem] {
        _ = mixRevision
        guard let mixFlags else { return [] }
        var pairIsClean: Bool?
        if includingPrevious, let previous = previousTrack(of: track) {
            pairIsClean = mixFlags.pairIsClean(from: previous.videoId, to: track.videoId)
        }
        return MusicMixMenuItem.items(startsClean: mixFlags.startsClean(track.videoId), pairIsClean: pairIsClean)
    }

    /// A pick of a no-mix entry: flips the flag it names. A transition already parked is planned again at once.
    func performMix(_ item: MusicMixMenuItem, for track: MusicTrack) {
        guard let mixFlags else { return }
        switch item {
        case .startClean(let on):
            mixFlags.setStartsClean(!on, videoId: track.videoId)
        case .cleanAfterPrevious(let on):
            guard let previous = previousTrack(of: track) else { return }
            mixFlags.setPairClean(!on, from: previous.videoId, to: track.videoId)
        }
        mixRevision += 1
        replanOffered()
    }

    /// Crossfade (or the album/loop rules, or its length) changed while a preload is parked: the plan is built again from
    /// the same frozen inputs and handed to the engine, which takes it only with the same park offset. No re-preload.
    private func replanOffered() {
        guard var offered = offeredPlan, preloadOffered == offered.inputs.incoming.videoId,
              player.preloadedTrack?.videoId == offered.inputs.incoming.videoId else { return }
        var inputs = offered.inputs
        inputs.crossfadeOn = mixesTransitions
        inputs.settingSeconds = crossfadeSeconds
        inputs.albumInOrder = playsAlbumInOrder
        inputs.loopSong = loopMode == .song
        inputs.beatMixEnabled = isBeatMixOn && beatFallbackFor != inputs.incoming.videoId
        inputs.vocalGuardEnabled = isVocalGuardOn
        inputs.djLength = isDJLengthOn
        inputs.plainFade = !isMixOn
        // earliestMixOutSec stays what it was at the offer: moving it with the playhead would turn a ready beat plan
        // into a smart one inside the last seconds.
        let flags = transitionFlags(from: inputs.outgoing.videoId, to: inputs.incoming.videoId)
        inputs.cleanStartFlag = flags.startsClean
        inputs.cleanPairFlag = flags.pairIsClean
        var plan = MusicTransitionPlanner.plan(inputs)
        // A loop extend's standby is a composition of the song: a replan that changes the loop (or adds or removes one) is the
        // preload withdrawn and offered again on the next tick, ready or not: a setting that was turned off (Crossfade, Beat mix,
        // Vocal guard) or a pair marked clean must not be held back by a loop that is already built.
        if MusicLoopExtend.spec(from: plan) != MusicLoopExtend.spec(from: offered.plan) {
            cancelPreload()
            return
        }
        // A DJ-length cut that appeared or went away (the switch, or the run) is the preload withdrawn and offered again: the
        // standby is parked for the old mix-out and a ready one would otherwise keep it.
        if plan.djSection != offered.plan.djSection {
            cancelPreload()
            return
        }
        // Outside Mix the incoming song starts at its plain trim-in. A standby parked anywhere else (a beat plan's mix-in, a drop
        // swap's drop) would start mid-song under the plain fade: it is withdrawn and offered again, parked at the trim-in.
        if inputs.plainFade, offered.plan.incomingStartSec != plan.incomingStartSec {
            cancelPreload()
            return
        }
        // The standby is parked on a beat plan's mix-in and starts at its rate (and one parked for another plan cannot take
        // a beat mix): a replan that changes either is the preload withdrawn and offered again with the new plan.
        let wasBeat = offered.plan.mode == .beat
        // A ready preload whose beat mix-out is still ahead is kept: withdrawing it this late drops the next song.
        let readyAhead = wasBeat && player.preloadIsReady && (offered.plan.mixOutSec ?? 0) > player.currentTime
        if wasBeat != (plan.mode == .beat) {
            if !readyAhead { cancelPreload(); return }
        } else if wasBeat, plan.incomingRate != offered.plan.incomingRate || plan.mixInSec != offered.plan.mixInSec {
            if !readyAhead { cancelPreload() }
            return
        }
        // An album in order or Loop song takes the trims away, but the standby is parked at the old offset: the preload is
        // withdrawn and offered again on a later tick, with a plan that starts at 0.
        if offered.plan.incomingStartSec != 0, plan.reason == .albumInOrder || plan.reason == .loopSong {
            cancelPreload()
            return
        }
        plan.incomingStartSec = offered.plan.incomingStartSec
        guard plan != offered.plan else { return }
        offered.inputs = inputs
        offered.plan = plan
        offeredPlan = offered
        player.updateTransitionPlan(plan)
    }

    /// Reads a song's stored row into the mirror (only for the playing song and the next one). A row that lands for a
    /// song the offered plan did not have changes nothing: it is logged as late.
    private func readTransitionRow(_ id: String) async {
        guard let reader = analysisReader, let row = await reader.analysis(for: id),
              id == analysisCurrentID || id == analysisTarget else { return }
        transitionAnalyses[id] = row
        if let energy = row.keyInfoValue?.energy, energy.isFinite {
            songEnergy[id] = energy
            let keep = Set(playedRun + [analysisCurrentID, analysisTarget].compactMap { $0 })
            songEnergy = songEnergy.filter { keep.contains($0.key) }
        }
        let stream = id == player.currentStream?.videoId ? player.currentStream : prefetched
        guard var offered = offeredPlan, !offered.late, !offered.plannedWithRows.contains(id),
              id == offered.inputs.outgoing.videoId || id == offered.inputs.incoming.videoId,
              freshRow(for: stream?.videoId == id ? stream : nil) != nil else { return }
        offered.late = true
        offeredPlan = offered
        log(MusicTransitionLog.lateLine(
            from: offered.inputs.outgoing.videoId, to: offered.inputs.incoming.videoId, late: id
        ))
    }

    private func log(_ line: String) {
        transitionLines.append(line)
        if transitionLines.count > 50 { transitionLines.removeFirst(transitionLines.count - 50) }
        MusicTransitionLog.logger.notice("\(line, privacy: .public)")
    }

    /// The cache file's stream when the file is ready, else the network stream as it is. Decided once: the offer is made
    /// once per track, so a file that lands later never swaps the standby deck.
    private func preloadStream(for stream: ResolvedStream) -> ResolvedStream {
        guard stream.origin == .network, let cached = cachedFile, cached.videoId == stream.videoId,
              FileManager.default.fileExists(atPath: cached.url.path) else { return stream }
        return stream.playingFrom(file: cached.url)
    }

    /// Withdraws a preload the queue or a mode no longer agrees with.
    private func reconcilePreload() {
        syncCrossfade()
        guard !holdsPreloadForSkip else { return }
        guard let offered = preloadOffered, preloadTarget?.videoId != offered else { return }
        cancelPreload()
    }

    private func cancelPreload() {
        preloadOffered = nil
        offeredPlan = nil
        player.cancelPreload()
    }

    // MARK: - Player state, Now Playing and media keys

    private func playerStateChanged() {
        if player.isPlaying { failureStreak = 0 }
        // Play and pause are saved as they happen: the engine has just reported the exact place a pause stopped at. Sound
        // from a restored song means the listener started it, whatever the way.
        if player.isPlaying != wasPlaying {
            wasPlaying = player.isPlaying
            if wasPlaying { touchSession() }
            saveSession()
        }
        let active = player.isActive
        if active != nativePlaying {
            nativePlaying = active
            onNativePlayingChange?(active)
        }
        // The lyrics follow the loaded track. Its length is the stream's exact one once that has loaded.
        lyrics.trackChanged(player.nowPlaying, duration: player.duration)
        // The Related panel moves to the song that plays, when it follows the player.
        related.nowPlayingChanged(player.nowPlaying)
        lyrics.observePlayback(position: player.currentTime, isPlaying: player.isPlaying)
        loadLikeStatus()
        syncNowPlaying()
    }

    // MARK: - Likes

    /// The player column shows a song and its transport: signed in, or signed out with a downloaded song in the player (it
    /// plays from its file, so the account is not needed to pause it or skip to the next).
    var showsPlayerControls: Bool {
        authState == .signedIn || (authState == .signedOut && player.nowPlaying != nil)
    }

    /// The like buttons are on offer: signed in, with a song loaded in the player.
    var canRate: Bool {
        authState == .signedIn && player.nowPlaying != nil
    }

    /// Whether the song playing now is liked, disliked or neither; nil while that is not known (not read yet, or it could not be).
    var likeStatus: MusicLikeStatus? {
        guard let track = player.nowPlaying else { return nil }
        return likes.status(of: track.videoId)
    }

    /// The stream the player holds for a song: the one that plays, or the one prefetched to follow it. Nil for any other.
    /// The Song data panel reads it so these two open without a call.
    func heldStream(for videoId: String) -> ResolvedStream? {
        if let current = player.currentStream, current.videoId == videoId { return current }
        if let next = prefetched, next.videoId == videoId { return next }
        return nil
    }

    /// The stored analysis row of a song, if it was ever analysed. Nil with no analysis store, and for a song with no row.
    func storedAnalysis(for videoId: String) async -> MusicAnalysis? {
        await analysisReader?.analysis(for: videoId)
    }

    /// Reads the state of the song playing now, once per song (`MusicLikeStore.load` remembers what it has asked).
    private func loadLikeStatus() {
        guard let track = player.nowPlaying else { return }
        loadLikeStatus(of: track)
    }

    /// Reads the state of any song, once (`MusicLikeStore.load` remembers what it has asked): the rows' menus call it
    /// when the user shows interest in a song, so the menu can word Like and Dislike for it. Signed out there is no
    /// state to read, and nothing is asked.
    func loadLikeStatus(of track: MusicTrack) {
        guard authState == .signedIn, !isOffline else { return }
        likes.load(videoId: track.videoId)
    }

    /// Likes the song playing now, or takes its like back. The state shows at once; the result is what the call came to.
    func toggleLike() async -> MusicActionOutcome {
        guard let track = player.nowPlaying else { return .nothingPlaying }
        guard authState == .signedIn else { return .signedOut }
        return await likes.toggleLike(videoId: track.videoId)
    }

    /// Dislikes the song playing now and skips it once the dislike animation has played (see `scheduleDislikeSkip`), or
    /// takes the dislike back and plays on. With no next song the dislike is still sent and the song keeps playing.
    func dislike() async -> MusicActionOutcome {
        guard let track = player.nowPlaying else { return .nothingPlaying }
        guard authState == .signedIn else { return .signedOut }
        return await likes.dislike(videoId: track.videoId) { [weak self] in
            self?.scheduleDislikeSkip(of: track.videoId)
        }
    }

    /// Makes any song `status`, as the song menus do: not only the one playing, and nothing need be playing. Disliking the
    /// song that plays skips it once the dislike animation has played, as the shortcut does; disliking any other song
    /// leaves the player and the queue alone.
    func setLike(_ status: MusicLikeStatus, of track: MusicTrack) async -> MusicActionOutcome {
        guard authState == .signedIn else { return .signedOut }
        let isPlaying = track.videoId == player.nowPlaying?.videoId
        return await likes.set(status, videoId: track.videoId) { [weak self] in
            if isPlaying { self?.scheduleDislikeSkip(of: track.videoId) }
        }
    }

    /// The like animation plays for the song on screen: a rating of any other song (from a row's menu) shows only in its
    /// own state. The store tells this before a dislike skips, so the song is still the one that was rated. A Like or
    /// Dislike taken back asks for its removal, which also replaces the burst, so the thumb does not show a rating the
    /// song no longer has.
    private func ratingShown(videoId: String, status: MusicLikeStatus, previous: MusicLikeStatus?) {
        guard videoId == player.nowPlaying?.videoId else { return }
        if let kind = MusicRateBurst.kind(from: previous, to: status) {
            onRatingBurst?(kind)
        } else if let kind = MusicRateBurst.kindTakenBack(from: previous, to: status) {
            onRatingRemoval?(kind)
        }
    }

    /// A rating YouTube Music did not take cuts its animation short as the song goes back, so the thumb does not stay
    /// filled for a rating the song never got. When it was a Like or Dislike taken back that did not go through, the
    /// rating is back and the removal is cut short in the same way.
    private func ratingRolledBack(videoId: String, shown: MusicLikeStatus?) {
        guard videoId == player.nowPlaying?.videoId, let shown else { return }
        let kind = shown == .indifferent
            ? MusicRateBurst.kindTakenBack(from: likes.status(of: videoId), to: .indifferent)
            : MusicRateBurst.kind(from: nil, to: shown)
        if let kind { onRatingBurstCancel?(kind) }
    }

    /// Skips the song `videoId` that was just disliked, after `MusicRateBurst.Metrics.dislikeSkipDelay`: the dislike pop
    /// plays on the song it rates and settles for a beat before the song changes. A newer dislike replaces a skip that is
    /// still waiting. When the wait is over the skip happens only if all of these hold, and otherwise nothing happens:
    /// the song is still playing (the listener may have pressed Next, or another song may have started), it is still
    /// disliked (the dislike may have been taken back, been rolled back after a call that failed, or been forgotten by a
    /// sign-out), and a next song can follow. With no next song the song keeps playing.
    private func scheduleDislikeSkip(of videoId: String) {
        dislikeSkip?.cancel()
        dislikeSkip = Task { @MainActor [weak self, sleep] in
            await sleep(MusicRateBurst.Metrics.dislikeSkipDelay)
            guard !Task.isCancelled, let self else { return }
            guard player.nowPlaying?.videoId == videoId, likes.status(of: videoId) == .dislike, canGoNext else { return }
            next()
        }
    }

    private func syncNowPlaying() {
        guard let track = player.nowPlaying, !player.hasEnded else {
            nowPlaying.update(nil)
            return
        }
        nowPlaying.update(NowPlayingState(
            track: track,
            elapsed: player.currentTime,
            duration: player.duration,
            isPlaying: player.isPlaying,
            rate: player.deckRate
        ))
    }

    /// What a transport command does: from the Now Playing controls, and from the keyboard's play/pause, next and
    /// previous keys.
    func handleRemote(_ command: NowPlayingCommand) {
        switch command {
        case .play: resume()
        case .pause:
            noteActivity()
            player.pause()
        case .toggle: togglePlayback()
        case .next: next()
        case .previous: previous()
        case .seek(let seconds): seek(to: seconds)
        }
    }

    // MARK: - History

    /// Fed by the player every 0.5 s. Pings YouTube's history once after 30 s of real listening, and from then on
    /// reports the listening to the watchtime schedule.
    func handlePlaybackTick(position: TimeInterval, isPlaying: Bool) {
        // Before the session guard: the lyrics highlight needs the position whether or not History is tracking.
        lyrics.observePlayback(position: position, isPlaying: isPlaying, rate: player.deckRate)
        // Before it as well: the remembered place moves on whether or not History is tracking.
        if isPlaying, sessionStore != nil, now().timeIntervalSince(lastPeriodicSave) >= Self.sessionSaveInterval {
            lastPeriodicSave = now()
            saveSession()
        }
        guard session != nil else { return }
        // A session whose account expired only counts listening: the next song is not prepared under the dead account.
        if isPlaying, session?.pingsDropped != true {
            startVocalLookahead()
            prefetchNextIfNeeded(position: position)
            offerPreload(position: position)
            giveUpBeatMixIfNotReady(position: position)
        }
        let url = session?.trackingURL
        let earned = session?.accumulator.record(position: position, isPlaying: isPlaying, canFire: url != nil) == true
        // Every tick, so a stretch heard before the playback ping is in the opening watchtime ping. The clock is read
        // first: reading `session` inside the mutating call would overlap its access.
        let clock = sessionClock
        let level = listenerLevel()
        let due = session?.watchtime.record(
            position: position, isPlaying: isPlaying, now: clock, volume: level.volume, muted: level.muted
        )
        if earned, let url {
            sendOpeningPings(playback: url, mediaTime: position)
        } else if let due {
            sendWatchtimePing(due, mediaTime: position)
        }
    }

    // MARK: - Watchtime

    /// The listener touched a control: `lact` counts from now, and a restored session becomes theirs.
    private func noteActivity() {
        lastActivity = now()
        touchSession()
    }

    /// Seconds since the session began, on the injected clock: the `rt` of its watchtime pings.
    private var sessionClock: TimeInterval {
        session.map { now().timeIntervalSince($0.startedAt) } ?? 0
    }

    /// The 30 s are up: the playback ping, then, when the stream has a watchtime URL, the watchtime ping that opens
    /// the schedule. Watchtime pings wait for the playback ping, so a song under 30 s never touches YouTube.
    private func sendOpeningPings(playback: URL, mediaTime: TimeInterval) {
        guard let cpn = session?.cpn else { return }
        var pings = [HistoryPing(kind: .playback, url: playback, cpn: cpn, mediaTime: mediaTime)]
        let clock = sessionClock
        if let url = session?.watchtimeURL,
           let details = session?.watchtime.open(position: mediaTime, now: clock) {
            pings.append(HistoryPing(kind: .watchtime, url: url, cpn: cpn, mediaTime: mediaTime, details: stamped(details)))
        }
        enqueue(pings)
    }

    /// A scheduled ping or a pause flush that the tracker says is due.
    private func sendWatchtimePing(_ details: WatchtimeDetails, mediaTime: TimeInterval) {
        guard let cpn = session?.cpn, let url = session?.watchtimeURL else { return }
        enqueue([HistoryPing(kind: .watchtime, url: url, cpn: cpn, mediaTime: mediaTime, details: stamped(details))])
    }

    /// Closes the session with its one final ping (`final=1`), when it got as far as the playback ping: a session that
    /// never sent one has told YouTube nothing to close, as in the web player. The position comes from the player,
    /// so this goes before anything that resets it. Never sent twice for one session.
    private func sendFinalPing() {
        guard let cpn = session?.cpn, let url = session?.watchtimeURL else { return }
        // A song cut at its trimmed end stopped there, whatever length the player reports for it (no cap once a seek
        // brought its natural end back: the player's snapshot of the engine's plan has none then).
        var position = player.currentTime
        if let end = player.outgoingEndSnapshot, end.isFinite { position = min(position, end) }
        let clock = sessionClock
        guard let details = session?.watchtime.finish(position: position, now: clock) else { return }
        enqueue([HistoryPing(kind: .watchtime, url: url, cpn: cpn, mediaTime: position, details: stamped(details))])
    }

    /// The details with `lact`, the time since the listener last touched a control.
    private func stamped(_ details: WatchtimeDetails) -> WatchtimeDetails {
        var stamped = details
        stamped.idleMilliseconds = max(0, Int((now().timeIntervalSince(lastActivity) * 1000).rounded()))
        return stamped
    }

    /// Sends `pings` after any still waiting. They leave one at a time, in the order they were earned. A failed one is
    /// not retried and does not stop the ones behind it; one that has not left when the session is cancelled never does.
    private func enqueue(_ pings: [HistoryPing]) {
        // Offline a ping has nowhere to go, and one kept for later would reach History as a listen of another hour: it is
        // dropped.
        guard !isOffline else { return }
        pendingPings += pings
        guard !isSendingPings else { return }
        isSendingPings = true
        let generation = reportGeneration
        reportTask = Task { [weak self, backend] in
            while let ping = self?.nextPendingPing(generation: generation) {
                await Self.send(ping, through: backend)
            }
        }
    }

    /// The next ping for the drain of `generation`, or nil when it is empty or was cancelled.
    private func nextPendingPing(generation: Int) -> HistoryPing? {
        guard generation == reportGeneration else { return nil }
        guard !pendingPings.isEmpty else {
            isSendingPings = false
            return nil
        }
        return pendingPings.removeFirst()
    }

    /// Logs the outcome at a level that persists. Only the status code or the error kind is public:
    /// never the URL, its query or any cookie.
    private static func send(_ ping: HistoryPing, through backend: any MusicBackend) async {
        let name = ping.kind == .playback ? "history" : "watchtime"
        do {
            let status = try await backend.reportHistory(ping)
            logger.notice("\(name, privacy: .public) ping ok \(status, privacy: .public)")
        } catch {
            // A ping cut short by a sign-out or a swap is not a failure.
            guard !isCancellation(error) else { return }
            logger.error("\(name, privacy: .public) ping failed: \(logDescription(of: error), privacy: .public)")
        }
    }

    private func scheduleMemoryProbe() {
        #if DEBUG
        memoryProbe?.cancel()
        memoryProbe = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            MusicMemoryLog.log("playing")
        }
        #endif
    }

    // MARK: - Errors

    private func handle(_ error: any Error) {
        guard !Self.isCancellation(error) else { return }
        if let musicError = error as? MusicError, case .signedOut = musicError {
            // The session is dead: forget its cookies so the next launch does not start from them,
            // and what was loaded under it, so the next account never sees the old library.
            authState = .signedOut
            lastError = nil
            // What is playing keeps playing, but its pings carry the dead session's tracking URL: they are dropped
            // and the session ends without a final one, as in `signOut`, so a later sign-in never sends them.
            cancelReport()
            // The local listening count is the listener's own and goes on to the song's end: only the pings stop.
            session?.trackingURL = nil
            session?.watchtimeURL = nil
            session?.pingsDropped = true
            // The next track's stream was resolved under the account that is gone: neither the prefetch nor the preload
            // may start from it.
            cancelPrefetch()
            prefetched = nil
            trackChangedForAnalysis(to: nil)
            // The remembered session belonged to the account that is gone.
            dropSessionKey()
            forgetSession()
            browse.reset()
            trackActions.reset()
            likes.reset()
            related.reset()
            songData.reset()
            clearAccount()
            signOutTask = Task { [backend] in await backend.signOut() }
            return
        }
        logger.error("music request failed: \(Self.logDescription(of: error), privacy: .public)")
        lastError = Self.message(for: error)
    }

    /// A Home, Library, History or page request found the session gone: the same sign-out as a dead search.
    private func browseSessionExpired() {
        handle(MusicError.signedOut)
    }

    /// A page landed: the tile of a pinned artist, playlist or album takes the name and photo it shows now.
    private func pageLoaded(_ page: MusicBrowsePage, opener: MusicCollection?) {
        guard let opener, let latest = MusicPinnedItem(page: page, opener: opener) else { return }
        pinnedItems.refresh(latest)
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func isSignedOut(_ error: any Error) -> Bool {
        (error as? MusicError) == .signedOut
    }

    /// The short line shown in the UI.
    static func message(for error: any Error) -> String {
        if let musicError = error as? MusicError {
            switch musicError {
            case .signedOut:
                return "Signed out. Sign in again."
            case .http(let status):
                return "YouTube Music returned an error (\(status))."
            case .parse:
                return "Couldn't read YouTube Music's response."
            case .unplayable(let reason):
                let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "This track can't be played." : String(trimmed.prefix(80))
            case .noAudioFormat:
                return "No audio stream for this track."
            case .solver:
                return "Couldn't prepare the stream. Try again."
            case .rejected:
                return "YouTube Music didn't accept that. Try again."
            case .forbidden:
                return "YouTube Music refused that request (403)."
            }
        }
        if error is URLError {
            return "Network problem. Check your connection."
        }
        return "Something went wrong. Try again."
    }

    /// Safe for logs: error kind and status only, never a URL, cookie or response text.
    static func logDescription(of error: any Error) -> String {
        if let musicError = error as? MusicError {
            switch musicError {
            case .signedOut: return "signedOut"
            case .http(let status): return "http \(status)"
            case .parse: return "parse"
            case .unplayable: return "unplayable"
            case .noAudioFormat: return "noAudioFormat"
            case .solver: return "solver"
            case .rejected: return "rejected"
            case .forbidden: return "forbidden"
            }
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}
