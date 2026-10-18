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

    private(set) var authState: AuthState = .unknown
    /// Whether plays (and so History) land on a brand channel; nil until the home page says.
    private(set) var isBrandChannel: Bool?
    private(set) var isSwitchingChannel = false
    /// Who the session is signed in as, for the account card; nil until the account menu answers.
    private(set) var account: MusicAccount?
    /// The sign-in window is open to add another Google account on top of the current session.
    private(set) var isAddingAccount = false
    /// The own-channel notice was closed. Only for this launch and this sign-in.
    var channelNoticeDismissed = false
    var query = ""
    private(set) var results: [MusicTrack] = []
    private(set) var isSearching = false
    /// One short human line for the UI; never contains cookies or URLs.
    private(set) var lastError: String?
    let player: MusicPlayer
    /// What plays next: the tapped track, then the radio's tracks as they arrive, or a page's tracks in page order.
    private(set) var queue = MusicQueue()
    /// Home, Library and the pages opened from them.
    let browse: MusicBrowseStore
    /// Synced lyrics of the playing track, for the lyrics panel.
    let lyrics: MusicLyricsStore
    /// Next is on while a track follows. At the last track it stays on when something can still follow: Loop playlist
    /// wraps to the first track, and Autoplay (with Loop playlist off) waits for the page that is loading or hands the
    /// page over to the radio. A radio that has run out has nothing to go to.
    var canGoNext: Bool {
        if queue.hasNext { return true }
        if queue.isEmpty { return false }
        if loopMode == .playlist { return true }
        return isAutoplayOn && (queue.continuation != nil || queue.hasReachedPageEnd)
    }
    /// The queue plays in a shuffled order. Remembered across launches.
    private(set) var isShuffleOn: Bool
    /// What happens when a track or the queue ends. Remembered across launches.
    private(set) var loopMode: MusicLoopMode
    /// Keep playing recommended songs after a playlist or an album has finished. Remembered across launches.
    private(set) var isAutoplayOn: Bool
    /// Told whenever Deci's own player starts or stops playing (not on every state change).
    @ObservationIgnored var onNativePlayingChange: (@MainActor (Bool) -> Void)?

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

    /// Previous restarts the track instead of going back once it has played this long.
    private static let restartThreshold: TimeInterval = 3
    /// Consecutive tracks that may fail before playback stops with an error.
    private static let maxFailures = 3
    /// The next track's stream is resolved this long before the current one ends.
    private static let prefetchLead: TimeInterval = 15
    /// Radio pages overlap, so a page can add nothing new. This many in a row ends a top-up.
    private static let maxEmptyPages = 3

    @ObservationIgnored private let backend: any MusicBackend
    @ObservationIgnored private let presentSignIn: SignInPresenter
    @ObservationIgnored private let presentChannelPicker: ChannelPickerPresenter
    @ObservationIgnored private let closeSignInWindow: @MainActor () -> Void
    @ObservationIgnored private let raiseSignInWindow: @MainActor () -> Void
    @ObservationIgnored private let nowPlaying: NowPlayingController
    /// The clock the watchtime schedule and `lact` read.
    @ObservationIgnored private let now: () -> Date
    /// When the listener last touched a control: the `lact` of every watchtime ping.
    @ObservationIgnored private var lastActivity: Date
    /// The player volume (0 to 100) and mute the watchtime pings report: the Mixer tab's YouTube Music row.
    @ObservationIgnored private let listenerLevel: @MainActor () -> (volume: Int, muted: Bool)
    /// Told the three playback options whenever one changes, so the app can keep them in settings.
    @ObservationIgnored private let savePreferences: @MainActor (MusicPlaybackPreferences) -> Void
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
    @ObservationIgnored private(set) var signOutTask: Task<Void, Never>?
    @ObservationIgnored private(set) var identityTask: Task<Void, Never>?
    @ObservationIgnored private(set) var channelSwitchTask: Task<Void, Never>?
    @ObservationIgnored private(set) var accountTask: Task<Void, Never>?
    @ObservationIgnored private(set) var addAccountTask: Task<Void, Never>?
    /// The radio or page fetch in flight (first radio page or a continuation); nil when none is running.
    @ObservationIgnored private(set) var radioTask: Task<Void, Never>?
    @ObservationIgnored private(set) var prefetchTask: Task<Void, Never>?
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
        // `MusicLyricsStore.live()`, so a service built by a test or a preview never reaches LRCLIB.
        lyrics: MusicLyricsStore = MusicLyricsStore(provider: NoLyricsProvider()),
        now: @escaping () -> Date = Date.init,
        listenerLevel: @escaping @MainActor () -> (volume: Int, muted: Bool) = { (WatchtimeTracker.fullVolume, false) },
        preferences: MusicPlaybackPreferences = MusicPlaybackPreferences(),
        savePreferences: @escaping @MainActor (MusicPlaybackPreferences) -> Void = { _ in },
        // A fixed seed makes every shuffle repeatable; without one each launch shuffles differently.
        shuffleSeed: UInt64? = nil,
        refreshOnCreate: Bool = true
    ) {
        self.backend = backend
        self.browse = MusicBrowseStore(backend: backend)
        self.lyrics = lyrics
        self.player = player
        self.presentSignIn = presentSignIn
        self.presentChannelPicker = presentChannelPicker
        self.closeSignInWindow = closeSignInWindow
        self.raiseSignInWindow = raiseSignInWindow
        self.nowPlaying = nowPlaying
        self.now = now
        self.listenerLevel = listenerLevel
        self.isShuffleOn = preferences.shuffle
        self.loopMode = preferences.loop
        self.isAutoplayOn = preferences.autoplay
        self.savePreferences = savePreferences
        self.shuffleGenerator = MusicShuffleGenerator(seed: shuffleSeed ?? UInt64.random(in: .min ... .max))
        self.lastActivity = now()
        // The lyrics panel ignores ticks while it is hidden, so it asks for one fresh reading when it comes back.
        lyrics.playbackSampler = { [player] in (player.currentTime, player.isPlaying) }
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
        nowPlaying.onCommand = { [weak self] command in self?.handleRemote(command) }
        browse.onSessionExpired = { [weak self] in self?.browseSessionExpired() }
        if refreshOnCreate {
            Task { [weak self] in await self?.refreshAuth() }
        }
    }

    isolated deinit {
        searchTask?.cancel()
        playTask?.cancel()
        signInTask?.cancel()
        identityTask?.cancel()
        channelSwitchTask?.cancel()
        accountTask?.cancel()
        addAccountTask?.cancel()
        radioTask?.cancel()
        prefetchTask?.cancel()
        #if DEBUG
        memoryProbe?.cancel()
        #endif
    }

    // MARK: - Auth

    func refreshAuth() async {
        let signedIn = await backend.isSignedIn()
        guard authState != .signingIn else { return }
        authState = signedIn ? .signedIn : .signedOut
        if signedIn { refreshIdentity() }
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
                self.refreshIdentity()
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
        query = ""
        lastError = nil
        authState = .signedOut
        identityTask?.cancel()
        channelSwitchTask?.cancel()
        isBrandChannel = nil
        isSwitchingChannel = false
        channelNoticeDismissed = false
        clearAccount()
        endAddAccount()
        // An open picker still holds the old session; it must not sign anyone back in.
        closeSignInWindow()
        browse.reset()
        lyrics.reset()
        signOutTask = Task { [backend] in await backend.signOut() }
    }

    // MARK: - Account

    /// The channel identity (History's target) and the account card's data, read together wherever a session starts.
    private func refreshIdentity() {
        refreshChannelIdentity()
        refreshAccount()
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
        query = ""
        lastError = nil
        authState = .signedIn
        identityTask?.cancel()
        isBrandChannel = nil
        channelNoticeDismissed = false
        browse.reset()
        lyrics.reset()
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
                // Stay in "switching" until the new identity is known, so the old notice doesn't flash back.
                self.identityTask?.cancel()
                self.isBrandChannel = nil
                self.channelNoticeDismissed = false
                // Home and the library belong to the channel: what is loaded is the old one's.
                self.browse.reset()
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
        cancelWork()
        endQueue()
        // Before the player resets its position; the quit path does not wait for it, as the ping is fire and forget.
        sendFinalPing()
        player.stop()
        session = nil
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
    }

    private func cancelWork() {
        searchGeneration += 1
        playGeneration += 1
        searchTask?.cancel()
        playTask?.cancel()
        searchTask = nil
        playTask = nil
        isSearching = false
        #if DEBUG
        memoryProbe?.cancel()
        #endif
    }

    // MARK: - Search

    /// Submit-on-Return search. A newer search replaces the one in flight.
    func search() {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
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

    private func runSearch(_ term: String, generation: Int) async {
        do {
            let found = try await backend.search(term)
            guard generation == searchGeneration, !Task.isCancelled else { return }
            results = found
            isSearching = false
            MusicMemoryLog.log("search")
        } catch {
            guard generation == searchGeneration else { return }
            isSearching = false
            handle(error)
        }
    }

    // MARK: - Playback

    /// Plays a tapped track and starts a radio queue behind it.
    func play(_ track: MusicTrack) {
        noteActivity()
        queue.start(with: track)
        // The radio's pages are mixed in as they land.
        if isShuffleOn { queue.shuffle(using: &shuffleGenerator) }
        direction = .forward
        failureStreak = 0
        startRadio(seed: track.videoId)
        begin(track)
    }

    /// Plays `track` with the rest of `page`'s songs queued after it in page order, with no radio.
    /// More tracks of a long playlist are fetched as the queue runs low; the queue ends with the page.
    func play(_ track: MusicTrack, in page: MusicBrowsePage) {
        noteActivity()
        // A page is its own order: a radio left over from the last queue must not add to it.
        cancelRadio()
        queue.start(page: page.tracks, playing: track, browseId: page.browseId, continuation: page.continuation)
        // The row that was tapped plays first; every other row, the ones above it too, is mixed in after it.
        if isShuffleOn { queue.shuffle(mixingEarlier: true, using: &shuffleGenerator) }
        direction = .forward
        failureStreak = 0
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

    // MARK: - Playback modes

    /// Turning shuffle on mixes what comes after the current track; turning it off puts the whole queue back in
    /// its natural order and carries on from the current track.
    func setShuffle(_ on: Bool) {
        guard on != isShuffleOn else { return }
        isShuffleOn = on
        if !queue.isEmpty {
            if on { queue.shuffle(using: &shuffleGenerator) } else { queue.unshuffle() }
        }
        savePlaybackPreferences()
        topUpQueue()
    }

    func setLoopMode(_ mode: MusicLoopMode) {
        guard mode != loopMode else { return }
        loopMode = mode
        savePlaybackPreferences()
        // A queue standing at the end of its page may now hand over to the radio.
        topUpQueue()
    }

    /// The loop button: Off, Loop playlist, Loop song, Off.
    func cycleLoopMode() {
        setLoopMode(loopMode.next)
    }

    func setAutoplay(_ on: Bool) {
        guard on != isAutoplayOn else { return }
        isAutoplayOn = on
        savePlaybackPreferences()
        topUpQueue()
    }

    private func savePlaybackPreferences() {
        savePreferences(MusicPlaybackPreferences(shuffle: isShuffleOn, loop: loopMode, autoplay: isAutoplayOn))
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
        guard let track = queue.advance() else {
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
    }

    /// Starts one queue item as its own playback session.
    private func begin(_ track: MusicTrack) {
        playTask?.cancel()
        playGeneration += 1
        let generation = playGeneration
        cancelPrefetch()
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
            scheduleMemoryProbe()
        } catch {
            guard generation == playGeneration else { return }
            handleResolveFailure(error)
        }
    }

    /// The stream resolved ahead of time when it is still good, otherwise a fresh one.
    private func streamForPlayback(of track: MusicTrack) async throws -> ResolvedStream {
        if let ready = prefetched, ready.videoId == track.videoId, ready.expiresAt > Date().addingTimeInterval(60) {
            prefetched = nil
            return ready
        }
        return try await backend.resolve(videoId: track.videoId)
    }

    /// Used by the player to replace a dead or expired stream. The playback session carries on.
    private func resolveFreshStream(for track: MusicTrack) async throws -> ResolvedStream {
        let generation = playGeneration
        do {
            let stream = try await backend.resolve(videoId: track.videoId)
            // Another track may have started meanwhile: its session and error line are not this refresh's to touch.
            guard generation == playGeneration, !Task.isCancelled else { throw CancellationError() }
            refreshError = nil
            if session?.watchtimeURL == nil { session?.watchtimeURL = stream.watchtimeTrackingURL }
            if session?.trackingURL == nil, let url = stream.playbackTrackingURL {
                session?.trackingURL = url
                // The 30 s may have passed while there was nowhere to send the ping.
                if session?.accumulator.claim() == true {
                    sendOpeningPings(playback: url, mediaTime: player.currentTime)
                }
            }
            return stream
        } catch {
            guard generation == playGeneration, !Task.isCancelled else { throw error }
            refreshError = error
            handle(error)
            throw error
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
        guard let track = queue.advance() else {
            // At the end of the queue the player stays on the finished track, as with a single song,
            // unless the radio is still loading (then the next track starts when its page lands)
            // or the queue loops.
            if !awaitRadio(for: .ended) { _ = wrapAround() }
            return
        }
        begin(track)
    }

    /// Loop playlist: starts the queue over from the first track of its play order. False when the queue does not loop.
    private func wrapAround() -> Bool {
        guard loopMode == .playlist, let first = queue.wrapToStart(using: &shuffleGenerator) else { return false }
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
            player.stop()
            // At the end of the queue there is nothing to keep; after three failures Next must still work.
            if !exhausted { endQueue() }
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
    /// Going forward off the end of a Loop playlist wraps to the next lap; the failure cap still stops a queue
    /// in which nothing plays.
    private func skipToNeighbour() -> Bool {
        guard failureStreak < Self.maxFailures else { return false }
        if direction == .forward, queue.upcomingCount == 0, loopMode == .playlist, !queue.isEmpty {
            return wrapAround()
        }
        guard let neighbour = direction == .forward ? queue.advance() : queue.retreat() else { return false }
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
    }

    /// Parks `advance` until the radio's next page lands. False when no page is on its way, so the caller ends as before.
    /// A top-up that stopped on the empty-page cap gets a fresh attempt: this one starts with an empty count.
    /// A skip that is already parked stays one: the listener asked to move on, whatever happens to the track meanwhile.
    private func awaitRadio(for advance: PendingAdvance) -> Bool {
        topUpQueue()
        guard radioTask != nil else { return false }
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
        guard applies, let track = queue.advance() else {
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
            if !wrapAround() { stopPlayback() }
        case .failed:
            endQueue()
        }
    }

    // MARK: - Radio and page paging

    private func startRadio(seed: String) {
        cancelRadio()
        let generation = radioGeneration
        radioTask = Task { [weak self] in
            await self?.fetchQueuePage(source: .radio(seedVideoId: seed), continuation: nil, generation: generation)
        }
    }

    /// Asks for the next page of the radio or of the playlist page when the queue is running low.
    /// One fetch at a time. `emptyPages` counts pages in a row that added nothing after de-duplication.
    private func topUpQueue(emptyPages: Int = 0) {
        guard radioTask == nil, emptyPages < Self.maxEmptyPages else { return }
        // Autoplay: a playlist or album on its last track carries on as the radio of that track, unless Loop playlist
        // is on (Loop song does not stop it). The radio is asked for while the last track plays, so the hand-over is
        // gapless. The queue stays a page until the radio has answered, so a radio that could not be reached is
        // asked for again by the next top-up.
        if loopMode != .playlist, isAutoplayOn, let seed = queue.radioHandOverSeed {
            startRadio(seed: seed)
            return
        }
        // Without Autoplay a radio queue stops at the tracks it has; a page still loads its own later pages.
        if case .radio = queue.source, !isAutoplayOn { return }
        guard queue.needsMore, let source = queue.source, let continuation = queue.continuation else { return }
        let generation = radioGeneration
        radioTask = Task { [weak self] in
            await self?.fetchQueuePage(source: source, continuation: continuation, generation: generation, emptyPages: emptyPages)
        }
    }

    private func requestQueuePage(source: MusicQueue.Source, continuation: String?) async throws -> MusicQueuePage {
        switch (source, continuation) {
        case (.radio(let seed), nil):
            return try await backend.radio(seedVideoId: seed)
        case (.radio(let seed), let token?):
            return try await backend.moreRadio(seedVideoId: seed, continuation: token)
        case (.page(let browseId), let token?):
            return try await backend.moreTracks(browseId: browseId, continuation: token)
        case (.page, nil):
            return MusicQueuePage(tracks: [], continuation: nil)
        }
    }

    private func fetchQueuePage(source: MusicQueue.Source, continuation: String?, generation: Int, emptyPages: Int = 0) async {
        let page: MusicQueuePage
        do {
            page = try await requestQueuePage(source: source, continuation: continuation)
        } catch {
            // No more tracks is not an error: the song keeps playing, the queue just does not grow.
            guard generation == radioGeneration else { return }
            radioTask = nil
            logger.info("queue page unavailable: \(Self.logDescription(of: error), privacy: .public)")
            // A page that cannot be read or that the server rejects would fail the same way again: stop paging.
            // A dead session is not retried either. Anything else (network, 5xx) keeps the continuation, and a
            // radio hand-over that failed this way keeps the queue a page, so a later top-up asks again.
            let signedOut = Self.isSignedOut(error)
            let final = Self.endsPaging(error) || signedOut
            if final {
                // A radio the server turns down is not asked for again either.
                if case .radio(let seed) = source { queue.adoptRadio(seedVideoId: seed) }
                queue.clearContinuation()
            }
            if signedOut { handle(error) }
            // A page that gave up may leave the queue on its last track: the radio takes over from there.
            if final, !signedOut { topUpQueue() }
            if radioTask == nil { settlePendingAdvance() }
            return
        }
        guard generation == radioGeneration, !Task.isCancelled else { return }
        radioTask = nil
        // The radio has answered: from here the queue is the radio's, even if it had nothing new to add.
        if case .radio(let seed) = source { queue.adoptRadio(seedVideoId: seed) }
        // Pages overlap heavily: one that adds nothing still has a continuation, so ask again at once,
        // up to `maxEmptyPages` in a row. The next track change starts a fresh attempt.
        let added = queue.append(page.tracks, continuation: page.continuation, using: &shuffleGenerator)
        if added > 0, resumePendingAdvance() { return }
        topUpQueue(emptyPages: added > 0 ? 0 : emptyPages + 1)
        if radioTask == nil { settlePendingAdvance() }
    }

    /// A page error that retrying will not fix: an unreadable response or a rejected request.
    private static func endsPaging(_ error: any Error) -> Bool {
        switch error as? MusicError {
        case .parse: true
        case .http(let status): (400..<500).contains(status)
        default: false
        }
    }

    private func cancelRadio() {
        radioGeneration += 1
        radioTask?.cancel()
        radioTask = nil
    }

    // MARK: - Prefetch

    private func prefetchNextIfNeeded(position: TimeInterval) {
        let duration = player.duration
        // Loop song replays the same track, so that is the stream worth resolving ahead.
        let target = loopMode == .song ? queue.current : queue.upcoming.first
        guard duration > Self.prefetchLead * 2, duration - position <= Self.prefetchLead,
              let next = target, prefetchAttempt != next.videoId else { return }
        prefetchAttempt = next.videoId
        prefetchTask = Task { [weak self, backend] in
            guard let stream = try? await backend.resolve(videoId: next.videoId) else { return }
            guard let self, !Task.isCancelled, self.prefetchAttempt == next.videoId else { return }
            self.prefetched = stream
        }
    }

    private func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchAttempt = nil
    }

    // MARK: - Player state, Now Playing and media keys

    private func playerStateChanged() {
        if player.isPlaying { failureStreak = 0 }
        let active = player.isActive
        if active != nativePlaying {
            nativePlaying = active
            onNativePlayingChange?(active)
        }
        // The lyrics follow the loaded track. Its length is the stream's exact one once that has loaded.
        lyrics.trackChanged(player.nowPlaying, duration: player.duration)
        lyrics.observePlayback(position: player.currentTime, isPlaying: player.isPlaying)
        syncNowPlaying()
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

    /// The listener touched a control: `lact` counts from now.
    private func noteActivity() {
        lastActivity = now()
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
            browse.reset()
            clearAccount()
            signOutTask = Task { [backend] in await backend.signOut() }
            return
        }
        logger.error("music request failed: \(Self.logDescription(of: error), privacy: .public)")
        lastError = Self.message(for: error)
    }

    /// A Home, Library or page request found the session gone: the same sign-out as a dead search.
    private func browseSessionExpired() {
        handle(MusicError.signedOut)
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
            }
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}
