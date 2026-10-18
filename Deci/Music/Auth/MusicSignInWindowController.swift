// Deci/Music/Auth/MusicSignInWindowController.swift
import AppKit
import WebKit
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "Music")

/// The Google sign-in window. The owner types their own credentials into a throwaway web view.
/// Once music.youtube.com is loaded with a session cookie, the window shows YouTube's own channel
/// picker: a fresh sign-in always lands on the account's own channel, and History is kept per
/// channel, so a brand channel has to be picked here. After the pick (or when the window is
/// closed on the picker) the YouTube cookies are handed back. Nothing is persisted here.
///
/// `presentChannelPicker` opens the same window straight on the picker, seeded with the current
/// session's cookies. If the switch needs Google to sign in again, Google asks in the window.
@MainActor
final class MusicSignInWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKHTTPCookieStoreObserver {
    static let signInURL = URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmusic.youtube.com%2F&hl=en")!
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    /// Redirects to the account page, which lists every channel of the signed-in account.
    static let channelPickerURL = URL(string: "https://www.youtube.com/channel_switcher")!
    static let musicHomeURL = URL(string: "https://music.youtube.com/")!
    static let dataSyncIdScript = "(window.ytcfg && ytcfg.get('DATASYNC_ID')) || ''"
    /// How long music.youtube.com gets to load under the picked channel before the cookies are taken anyway.
    static let confirmTimeout: Duration = .seconds(10)

    enum Stage {
        case signingIn
        /// Signed in; the channel picker is on screen.
        case pickingChannel
        /// A channel was picked; music.youtube.com is loading under it.
        case confirming
    }

    /// Hides WebAuthn so Google offers the password flow in an embedded view instead of refusing it.
    static let hidePasskeysScript = """
    (function () {
      try { delete window.PublicKeyCredential; } catch (e) {}
      if ('PublicKeyCredential' in window) {
        try { Object.defineProperty(window, 'PublicKeyCredential', { value: undefined, configurable: true }); } catch (e) {}
      }
    })();
    """

    private static var active: MusicSignInWindowController?

    private let window: NSWindow
    private let webView: WKWebView
    /// The session to start from when the window opens on the picker; nil for a fresh sign-in.
    private let seed: [StoredCookie]?
    private var started = false
    private var completion: @MainActor ([StoredCookie]?) -> Void
    private var finished = false
    private var stage = Stage.signingIn
    /// Set once the picker page has loaded, so a redirect on the way there never counts as a pick.
    private var pickerShown = false
    private var channelPicked = false
    private var harvesting = false
    /// The window is closing and its cookies are still being read: a new sign-in gets a new window.
    private var closing = false

    /// Shows the window. Calls `completion` once with the cookies, or nil when the window is closed early.
    static func present(completion: @escaping @MainActor ([StoredCookie]?) -> Void) {
        open(seed: nil, completion: completion)
    }

    /// Shows the channel picker for `session`. Calls `completion` once with the cookies under the
    /// picked channel, or nil when the window is closed without a pick.
    static func presentChannelPicker(session: [StoredCookie], completion: @escaping @MainActor ([StoredCookie]?) -> Void) {
        open(seed: session, completion: completion)
    }

    /// Closes the window without handing anything back. Called on sign-out, so a picker still
    /// holding the old session can't be reused or picked from.
    static func cancelActive() {
        active?.finish(with: nil, closeWindow: true)
    }

    /// Brings the open window back in front of everything, for a user who lost it behind other windows.
    /// Nothing when none is open, or when the open one is already closing.
    static func bringToFront() {
        guard let active, !active.closing else { return }
        active.show()
    }

    private static func open(seed: [StoredCookie]?, completion: @escaping @MainActor ([StoredCookie]?) -> Void) {
        if let active, !active.closing {
            // Only a fresh sign-in window is reused: a picker is tied to the session it was seeded with.
            if active.seed == nil, seed == nil {
                active.completion = completion
                active.show()
                return
            }
            active.finish(with: nil, closeWindow: true)
        }
        let controller = MusicSignInWindowController(seed: seed, completion: completion)
        active = controller
        controller.show()
    }

    private init(seed: [StoredCookie]?, completion: @escaping @MainActor ([StoredCookie]?) -> Void) {
        self.seed = seed
        self.completion = completion

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.hidePasskeysScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        webView.customUserAgent = Self.userAgent
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to YouTube Music"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentView = webView
        window.center()
        self.window = window

        super.init()

        webView.navigationDelegate = self
        window.delegate = self
        configuration.websiteDataStore.httpCookieStore.add(self)
    }

    private func show() {
        // The popup is a non-activating panel that hides when it loses key, and Deci is an
        // accessory app: let go of key first, then bring the app forward.
        if let keyWindow = NSApp.keyWindow, keyWindow !== window {
            keyWindow.resignKey()
        }
        NSApp.activate(ignoringOtherApps: true)
        // A window the user minimized stays in the Dock until asked back.
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        guard let seed else {
            if webView.url == nil { webView.load(URLRequest(url: Self.signInURL)) }
            return
        }
        guard !started else { return }
        started = true
        stage = .pickingChannel
        window.title = "Pick the channel to play as"
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = seed.compactMap(\.httpCookie)
        if cookies.count < seed.count {
            logger.error("channel picker dropped \(seed.count - cookies.count, privacy: .public) unreadable cookies")
        }
        Task { [weak self] in
            for cookie in cookies {
                guard self?.finished == false else { return }
                await store.setCookie(cookie)
            }
            guard let self, !self.finished else { return }
            self.webView.load(URLRequest(url: Self.channelPickerURL))
        }
    }

    // MARK: - Session detection

    private func checkForSession() {
        guard !finished, stage == .signingIn, Self.isMusicHost(webView.url) else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        Task { [weak self] in
            let cookies = await store.allCookies()
            guard let self, !self.finished, self.stage == .signingIn,
                  Self.isMusicHost(self.webView.url),
                  Self.hasSessionCookie(cookies) else { return }
            logger.notice("sign-in complete, showing the channel picker")
            self.stage = .pickingChannel
            self.window.title = "Pick the channel to play as"
            self.webView.load(URLRequest(url: Self.channelPickerURL))
        }
    }

    /// Picking a channel goes through youtube.com/signin and lands back on a youtube.com page;
    /// music.youtube.com is then loaded so the cookies are read under the picked channel.
    private func advanceChannelPick(finishedAt url: URL?) {
        guard !finished else { return }
        switch stage {
        case .signingIn:
            checkForSession()
        case .pickingChannel:
            guard Self.isYouTubeHost(url), !Self.isChannelSwitch(url) else { return }
            guard channelPicked else {
                // The picker lives on www.youtube.com; a late finish of the music page doesn't count.
                if !Self.isMusicHost(url) { pickerShown = true }
                return
            }
            stage = .confirming
            window.title = "Finishing sign-in"
            if Self.isMusicHost(url) {
                harvestAndFinish()
            } else {
                webView.load(URLRequest(url: Self.musicHomeURL))
                Task { [weak self] in
                    try? await Task.sleep(for: Self.confirmTimeout)
                    self?.harvestIfConfirming()
                }
            }
        case .confirming:
            if Self.isMusicHost(url) { harvestAndFinish() }
        }
    }

    /// A failed or slow music.youtube.com load after the pick: the picked channel is already in
    /// the cookies, so take them as they are.
    private func harvestIfConfirming() {
        guard !finished, stage == .confirming else { return }
        harvestAndFinish()
    }

    private func harvestAndFinish() {
        guard !harvesting else { return }
        harvesting = true
        let store = webView.configuration.websiteDataStore.httpCookieStore
        Task { [weak self] in
            let dataSyncId = try? await self?.webView.evaluateJavaScript(Self.dataSyncIdScript) as? String
            let identity = dataSyncId.flatMap(InnerTubeParser.isBrandChannel(dataSyncId:))
                .map { $0 ? "brand channel" : "own channel" } ?? "unknown"
            logger.notice("channel picked: \(identity, privacy: .public)")
            let cookies = await store.allCookies()
            guard Self.hasSessionCookie(cookies) else {
                logger.error("channel pick ended without a session cookie")
                self?.finish(with: nil, closeWindow: true)
                return
            }
            self?.finish(with: Self.harvest(cookies), closeWindow: true)
        }
    }

    private func finish(with cookies: [StoredCookie]?, closeWindow: Bool) {
        guard !finished else { return }
        finished = true
        withExtendedLifetime(self) {
            webView.configuration.websiteDataStore.httpCookieStore.remove(self)
            webView.navigationDelegate = nil
            webView.stopLoading()
            window.delegate = nil
            if closeWindow { window.close() }
            if Self.active === self { Self.active = nil }
            completion(cookies)
        }
    }

    // MARK: - Pure helpers

    nonisolated static func isMusicHost(_ url: URL?) -> Bool {
        url?.host()?.lowercased() == "music.youtube.com"
    }

    nonisolated static func isYouTubeHost(_ url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "https", let host = url?.host()?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    /// The navigation a channel pick starts: youtube.com/signin with action_handle_signin, and a
    /// pageid for a brand channel.
    nonisolated static func isChannelSwitch(_ url: URL?) -> Bool {
        guard let url, isYouTubeHost(url) else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { $0.name == "action_handle_signin" || $0.name == "pageid" }
    }

    /// Whether closing the window hands the cookies back. Closing before sign-in cancels it.
    /// Closing on the picker keeps the channel the session is on now, so a signed-in session is
    /// never thrown away; when the window opened on the picker that session is the one the app
    /// already has, so nothing comes back unless a channel was already clicked.
    nonisolated static func harvestsOnClose(stage: Stage, seeded: Bool, channelPicked: Bool) -> Bool {
        switch stage {
        case .signingIn: false
        case .pickingChannel: !seeded || channelPicked
        case .confirming: true
        }
    }

    /// A load cut short by the next one, not a real failure.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }

    /// The API-hash cookie has to be one that youtube.com owns; a google.com one is no use to the client.
    nonisolated static func hasSessionCookie(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains {
            ($0.name == "SAPISID" || $0.name == "__Secure-3PAPISID") && MusicCookieJar.isYouTubeDomain($0.domain)
        }
    }

    /// Only youtube.com cookies leave the window; the Google ones stay in the throwaway web view.
    nonisolated static func harvest(_ cookies: [HTTPCookie]) -> [StoredCookie] {
        cookies.filter { MusicCookieJar.isYouTubeDomain($0.domain) }.map(StoredCookie.init)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        advanceChannelPick(finishedAt: webView.url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if !Self.isCancellation(error) { harvestIfConfirming() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if !Self.isCancellation(error) { harvestIfConfirming() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if stage == .pickingChannel, pickerShown, navigationAction.targetFrame?.isMainFrame != false,
           Self.isChannelSwitch(navigationAction.request.url) {
            channelPicked = true
        }
        return .allow
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: - WKHTTPCookieStoreObserver

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        checkForSession()
    }

    // MARK: - NSWindowDelegate

    /// See `harvestsOnClose` for what a close hands back.
    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        guard Self.harvestsOnClose(stage: stage, seeded: seed != nil, channelPicked: channelPicked) else {
            finish(with: nil, closeWindow: false)
            return
        }
        closing = true
        let store = webView.configuration.websiteDataStore.httpCookieStore
        // Strong on purpose: a new sign-in can replace `active` while the cookies are read.
        Task {
            let cookies = await store.allCookies()
            guard Self.hasSessionCookie(cookies) else {
                logger.error("window closed without a session cookie")
                self.finish(with: nil, closeWindow: false)
                return
            }
            logger.notice("channel picker closed, keeping the current channel")
            self.finish(with: Self.harvest(cookies), closeWindow: false)
        }
    }
}
