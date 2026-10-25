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
    private(set) var queue = MusicQueue()
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
    /// The artists, playlists, albums and songs pinned to the top of Home. Remembered across launches, and kept
    /// through sign-out and account switches: they belong to the app, not to an account.
    let pinnedItems: MusicPinnedItems
    /// The downloaded songs, which play from their files. Nil in a service built without them (a preview, most tests).
    let downloads: MusicDownloadService?
    /// Next is on while a track follows. At the last track it stays on when something can still follow: Loop playlist
    /// wraps to the first track, a page waits for its next page or the radio that is loading, and Autoplay (with Loop
    /// playlist off) plays the staged radio or asks for a new one. A mix that can still grow always has more. With Autoplay
    /// off a radio queue has only the songs the listener queued: its radio is parked.
    var canGoNext: Bool {
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
    private(set) var isShuffleOn: Bool
    /// What happens when a track or the queue ends. Remembered across launches.
    private(set) var loopMode: MusicLoopMode
    /// Keep playing recommended songs after a playlist or an album has finished. Remembered across launches.
    private(set) var isAutoplayOn: Bool
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
    /// True while a settings reset puts the options back: the file was cleared already, so nothing is written.
    @ObservationIgnored private var holdsPreferences = false
    @ObservationIgnored private var shuffleGenerator: MusicShuffleGenerator
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var direction = Direction.forward
    @ObservationIgnored private var failureStreak = 0
    @ObservationIgnored private var pendingAdvance: PendingAdvance?
    /// Why the last stream refresh failed; read when the player then gives up on the track.
    @ObservationIgnored private var refreshError: (any Error)?
    @ObservationIgnored private var nativePlaying = false
    @ObservationIgnored private var radioGeneration = 0
    @ObservationIgnored private var prefetchAttempt: String?
    @ObservationIgnored private var prefetched: ResolvedStream?
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
        didSet { noteQueueFilling() }
    }
    /// The wait before a failed queue page is asked for again; nil when no retry is due.
    @ObservationIgnored private(set) var queueRetryTask: Task<Void, Never>? {
        didSet { noteQueueFilling() }
    }
    @ObservationIgnored private(set) var prefetchTask: Task<Void, Never>?

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
        refreshOnCreate: Bool = true
    ) {
        self.backend = backend
        let browse = MusicBrowseStore(backend: backend)
        self.browse = browse
        self.trackActions = MusicTrackActionsStore(backend: backend, browse: browse)
        self.likes = MusicLikeStore(backend: backend)
        self.related = MusicRelatedStore(backend: backend, browse: browse)
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
        self.loopMode = preferences.loop
        self.isAutoplayOn = preferences.autoplay
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
        player.onStateChange = { [weak self] in self?.playerStateChanged() }
        player.onLocalFileChange = { [weak self] videoId in self?.downloads?.noteLocalPlayback(of: videoId) }
        nowPlaying.onCommand = { [weak self] command in self?.handleRemote(command) }
        browse.onSessionExpired = { [weak self] in self?.browseSessionExpired() }
        trackActions.onSessionExpired = { [weak self] in self?.browseSessionExpired() }
        likes.onSessionExpired = { [weak self] in self?.browseSessionExpired() }
        related.onSessionExpired = { [weak self] in self?.browseSessionExpired() }
        likes.onRatingShown = { [weak self] videoId, status, previous in
            self?.ratingShown(videoId: videoId, status: status, previous: previous)
        }
        likes.onRatingRolledBack = { [weak self] videoId, shown in
            self?.ratingRolledBack(videoId: videoId, shown: shown)
        }
        browse.onPageLoaded = { [weak self] page, opener in self?.pageLoaded(page, opener: opener) }
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
    }

    /// A sign-in is in place: the account's details are read, and so is the state of a song that was already playing,
    /// which was skipped while signed out. The downloaded playlists and albums are synced once per launch, from here.
    private func didSignIn() {
        refreshIdentity()
        loadLikeStatus()
        downloads?.signInKnown()
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
        lastError = nil
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
            do {
                try await self.backend.signIn(with: cookies)
                guard !Task.isCancelled, generation == self.addAccountGeneration else { return }
                self.installNewSession()
            } catch {
                guard generation == self.addAccountGeneration else { return }
                logger.error("adding an account failed: \(Self.logDescription(of: error), privacy: .public)")
                self.lastError = "Couldn't add the account. Still signed in as before."
            }
            self.isAddingAccount = false
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
        lastError = nil
        channelSwitchTask = Task { [weak self, backend] in
            let cookies = await backend.sessionCookies()
            guard let self, !Task.isCancelled, self.authState == .signedIn, !cookies.isEmpty else {
                self?.isSwitchingChannel = false
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
            // A sign-out since the pick cancels this; the picked session must not sign back in.
            guard let self, !Task.isCancelled else { return }
            do {
                try await self.backend.signIn(with: cookies)
                guard self.authState == .signedIn else { return }
                // Stay in "switching" until the new identity is known.
                self.identityTask?.cancel()
                // The queue keeps playing under the picked channel: its snapshots take that channel's key once it is read.
                self.dropSessionKey()
                self.refreshSessionKey()
                self.isBrandChannel = nil
                // Home and the library belong to the channel: what is loaded is the old one's.
                self.browse.reset()
                self.trackActions.reset()
                // The other channel has its own likes: the song playing is read again.
                self.likes.reset()
                self.related.reset()
                self.loadLikeStatus()
                // The card shows the channel that was picked, not the one that was left.
                self.clearAccount()
                self.refreshAccount()
                let identity = await self.backend.channelIdentity()
                guard !Task.isCancelled, self.authState == .signedIn else { return }
                self.isBrandChannel = identity
            } catch {
                logger.error("channel switch failed: \(Self.logDescription(of: error), privacy: .public)")
                self.lastError = "Couldn't switch the channel. Still playing as before."
            }
            self.isSwitchingChannel = false
        }
    }

    /// Stops playback and pending work, and writes any cookie change still held back to the Keychain.
    /// Called when the app quits.
    func stop() {
        // The session is written, with a fresh time, before the queue is wound up: from here the file is left as it is.
        restoreTask?.cancel()
        saveSession(force: true)
        sessionStore?.flush()
        sessionClosed = true
        cancelWork()
        endQueue()
        // Before the player resets its position; the quit path does not wait for it, as the ping is fire and forget.
        sendFinalPing()
        player.stop()
        session = nil
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
        // Without the account a session cannot be told to be this one's: left on disk for the next launch.
        guard let key = await backend.sessionIdentity() else {
            logger.info("session not restored: account unknown")
            return
        }
        guard generation == playGeneration, !Task.isCancelled, authState == .signedIn else { return }
        sessionChannelKey = key
        guard let snapshot = sessionStore.load(forChannel: key) else { return }
        guard let track = snapshot.queue.current else {
            sessionStore.delete()
            return
        }
        let stream: ResolvedStream
        do {
            stream = try await streamForSource(of: track.videoId)
        } catch {
            guard generation == playGeneration, !Task.isCancelled, !Self.isCancellation(error) else { return }
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
            watchtimeURL: stream.watchtimeTrackingURL
        )
        restoredVideoId = track.videoId
        lastSavedSession = snapshot
        player.loadPaused(
            stream: stream, track: track,
            at: snapshot.clampedPosition(duration: stream.durationSeconds ?? Double(track.durationSeconds ?? 0))
        )
        fetchTrackingURLs(for: stream, generation: generation)
        topUpQueue()
    }

    // MARK: - Search

    /// Searches for `query`: run on Return, and as the owner types. A newer search replaces the one in flight.
    func search() {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            artistResults = []
            albumResults = []
            isSearching = false
            searchTask = nil
            return
        }
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
        noteActivity()
        queue.start(with: track)
        // The radio's pages are mixed in as they land.
        if isShuffleOn { queue.shuffle(using: &shuffleGenerator) }
        direction = .forward
        failureStreak = 0
        queueRetryAttempts = 0
        if isAutoplayOn {
            startRadio(seed: track.videoId)
        } else {
            // A radio still loading for the last queue must not land in this one.
            cancelRadio()
        }
        begin(track)
    }

    /// Plays `track` with the rest of `page`'s songs queued after it in page order. The rest of a long playlist is
    /// loaded at once, so Up next lists all of it. With Autoplay the automix of a playlist or an album follows the page
    /// (the radio of the last song when YouTube names none). A mix page is an endless mix: it is asked for more after its
    /// last song whatever Autoplay and Loop say.
    func play(_ track: MusicTrack, in page: MusicBrowsePage) {
        noteActivity()
        // A page is its own order: a radio left over from the last queue must not add to it.
        cancelRadio()
        queue.start(
            page: page.tracks,
            playing: track,
            browseId: page.browseId,
            continuation: page.continuation,
            automixPlaylistId: page.automixPlaylistId,
            mixPlaylistId: page.mixPlaylistId
        )
        // The row that was tapped plays first; every other row, the ones above it too, is mixed in after it.
        if isShuffleOn { queue.shuffle(mixingEarlier: true, using: &shuffleGenerator) }
        direction = .forward
        failureStreak = 0
        queueRetryAttempts = 0
        begin(track)
    }

    /// "Shuffle" on a playlist or album page: turns shuffle on and starts from a random track of the page.
    func playShuffled(_ page: MusicBrowsePage) {
        guard let track = page.tracks.randomElement(using: &shuffleGenerator) else { return }
        if !isShuffleOn {
            isShuffleOn = true
            savePlaybackPreferences()
        }
        play(track, in: page)
    }

    // MARK: - Queue edits

    /// Play next: the song plays right after the current one. With nothing queued it just starts the song, like a tap
    /// on a lone song: with Autoplay, a radio behind it.
    func playNext(_ track: MusicTrack) {
        guard !queue.isEmpty else { return play(track) }
        guard queue.playNext(track) else { return }
        noteActivity()
        queueEdited()
        saveSession()
        trackActions.post("Playing next")
    }

    /// Add to queue: the song goes after the queue's own songs and before the radio that follows. With nothing queued it
    /// just starts the song, like a tap on a lone song: with Autoplay, a radio behind it.
    func addToQueue(_ track: MusicTrack) {
        guard !queue.isEmpty else { return play(track) }
        guard queue.addToQueue(track) else { return }
        noteActivity()
        queueEdited()
        saveSession()
        trackActions.post("Added to queue")
    }

    /// Remove from queue: the song leaves the play order. A queue left short is topped up, so Up next with Autoplay
    /// on is never empty.
    func removeFromQueue(_ track: MusicTrack) {
        guard queue.remove(videoId: track.videoId) else { return }
        noteActivity()
        topUpQueue()
        saveSession()
        trackActions.post("Removed from queue")
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
    /// whole queue back in its natural order and carries on from the current track.
    func setShuffle(_ on: Bool) {
        guard on != isShuffleOn else { return }
        touchSession()
        isShuffleOn = on
        if !queue.isEmpty {
            if on {
                queue.shuffle(mixingEarlier: queue.isPage, using: &shuffleGenerator)
            } else {
                queue.unshuffle()
            }
        }
        savePlaybackPreferences()
        topUpQueue()
        saveSession()
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

    private func savePlaybackPreferences() {
        guard !holdsPreferences else { return }
        savePreferences(MusicPlaybackPreferences(shuffle: isShuffleOn, loop: loopMode, autoplay: isAutoplayOn))
    }

    /// Everything went back to its default. The settings were cleared already, so nothing is written here: the
    /// playback options go back to theirs the way the buttons change them, and the pins are dropped, so the next
    /// change cannot write the old ones back.
    func settingsDidReset() {
        let defaults = MusicPlaybackPreferences()
        holdsPreferences = true
        defer { holdsPreferences = false }
        setShuffle(defaults.shuffle)
        setLoopMode(defaults.loop)
        setAutoplay(defaults.autoplay)
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
        begin(track)
    }

    func next() {
        noteActivity()
        direction = .forward
        failureStreak = 0
        guard let track = advanceQueue() else {
            // The radio may still be loading: keep playing and move on when its page lands.
            if !awaitRadio(for: .skipped), !wrapAround() { stopPlayback() }
            return
        }
        begin(track)
    }

    /// Restarts the track once it has played a few seconds (or when it is the first); otherwise goes back one.
    func previous() {
        noteActivity()
        guard player.nowPlaying != nil else { return }
        if player.currentTime > Self.restartThreshold || !queue.hasPrevious {
            // A track that ended replays through play(), which also rewinds it.
            if player.hasEnded { player.play() } else { seek(to: 0) }
            return
        }
        direction = .backward
        failureStreak = 0
        guard let track = queue.retreat() else { return }
        begin(track)
    }

    /// Plays a track that is already in the queue.
    func jump(to track: MusicTrack) {
        noteActivity()
        guard let target = queue.jump(to: track.videoId) else { return }
        direction = .forward
        failureStreak = 0
        begin(target)
    }

    func seek(to seconds: TimeInterval) {
        guard player.nowPlaying != nil else { return }
        noteActivity()
        player.seek(to: seconds)
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
            session = Session(
                cpn: CPN.make(),
                startedAt: now(),
                trackingURL: stream.playbackTrackingURL,
                watchtimeURL: stream.watchtimeTrackingURL
            )
            player.load(stream: stream, track: track)
            fetchTrackingURLs(for: stream, generation: generation)
            scheduleMemoryProbe()
        } catch {
            guard generation == playGeneration else { return }
            handleResolveFailure(error)
        }
    }

    /// The stream resolved ahead of time when it is still good, otherwise a fresh one.
    private func streamForPlayback(of track: MusicTrack) async throws -> ResolvedStream {
        // A downloaded song plays from its file, whatever was prefetched for it before the download finished.
        if let local = await downloadedStream(of: track.videoId) {
            if prefetched?.videoId == track.videoId { prefetched = nil }
            return local
        }
        // A prefetched file is not used once its download is gone: it would only fail and take the retry.
        if let ready = prefetched, ready.videoId == track.videoId, !ready.url.isFileURL,
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
        return try await backend.resolve(videoId: videoId)
    }

    /// The downloaded file, waiting first for the downloads of earlier launches to be read from disk.
    private func downloadedStream(of videoId: String) async -> ResolvedStream? {
        guard let downloads else { return nil }
        await downloads.waitUntilLoaded()
        return downloads.localStream(for: videoId)
    }

    /// Used by the player to replace a dead or expired stream. The playback session carries on.
    private func resolveFreshStream(for track: MusicTrack) async throws -> ResolvedStream {
        let generation = playGeneration
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
        guard stream.url.isFileURL else { return }
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
        if let track = queue.advance() { return track }
        guard playsAutoplay, queue.takeAutoplay() else { return nil }
        return queue.advance()
    }

    /// Loop playlist: starts the queue over from the first track of its play order (a shuffled queue from its shuffled
    /// start). False when the queue does not loop.
    private func wrapAround() -> Bool {
        guard loopMode == .playlist, let first = queue.wrapToStart() else { return false }
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
        if Self.skipsTrack(error) {
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
        if authState == .signedOut {
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
        if direction == .forward, queue.upcomingCount == 0, loopMode == .playlist, !queue.isEmpty, !queue.mixHasMore {
            return wrapAround()
        }
        guard let neighbour = direction == .forward ? advanceQueue() : queue.retreat() else { return false }
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
            if !wrapAround(), !parksRadio { stopPlayback() }
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
        radioTask = Task { [weak self] in
            await self?.fetchQueuePage(
                source: .radio(seedVideoId: seed), continuation: nil, generation: generation, mixId: mixId,
                emptyPages: emptyPages
            )
        }
    }

    /// Asks for the next page of the radio or of the playlist page, or for a radio to follow, when the queue needs it.
    /// One fetch at a time; a fetch that starts replaces a retry that was waiting. `emptyPages` counts pages in a row
    /// that added nothing after de-duplication.
    private func topUpQueue(emptyPages: Int = 0) {
        guard radioTask == nil, emptyPages < Self.maxEmptyPages else { return }
        // A queue running out with nothing left to page asks for a radio: the first radio of a tapped song with
        // Autoplay (Loop playlist or not), then with Autoplay and Loop playlist off the radio of the last track. A
        // playlist or album page stages it as soon as it has loaded in full, whatever the number of songs left, so
        // Up next shows the recommendations from the start and the hand-over is gapless; it asks for at most
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
                // radio is parked: the next top-up under Autoplay on asks for it.
                if !parksRadio { scheduleQueueRetry(emptyPages: emptyPages) }
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
            added = queue.append(page.tracks, continuation: page.continuation, using: &shuffleGenerator)
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
        let duration = player.duration
        let target = prefetchTarget
        guard duration > Self.prefetchLead * 2, duration - position <= Self.prefetchLead,
              let next = target, prefetchAttempt != next.videoId else { return }
        prefetchAttempt = next.videoId
        prefetchTask = Task { [weak self] in
            guard let self, let stream = try? await self.streamForSource(of: next.videoId) else { return }
            guard !Task.isCancelled, self.prefetchAttempt == next.videoId else { return }
            self.prefetched = stream
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

    /// The like buttons are on offer: signed in, with a song loaded in the player.
    var canRate: Bool {
        authState == .signedIn && player.nowPlaying != nil
    }

    /// Whether the song playing now is liked, disliked or neither; nil while that is not known (not read yet, or it could not be).
    var likeStatus: MusicLikeStatus? {
        guard let track = player.nowPlaying else { return nil }
        return likes.status(of: track.videoId)
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
        guard authState == .signedIn else { return }
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
            isPlaying: player.isPlaying
        ))
    }

    private func handleRemote(_ command: NowPlayingCommand) {
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
        lyrics.observePlayback(position: position, isPlaying: isPlaying)
        // Before it as well: the remembered place moves on whether or not History is tracking.
        if isPlaying, sessionStore != nil, now().timeIntervalSince(lastPeriodicSave) >= Self.sessionSaveInterval {
            lastPeriodicSave = now()
            saveSession()
        }
        guard session != nil else { return }
        if isPlaying { prefetchNextIfNeeded(position: position) }
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
        let position = player.currentTime
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
            session = nil
            // The remembered session belonged to the account that is gone.
            dropSessionKey()
            forgetSession()
            browse.reset()
            trackActions.reset()
            likes.reset()
            related.reset()
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
            }
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}
