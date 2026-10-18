// Deci/Music/Auth/MusicSignInWindowController.swift
import AppKit
import WebKit
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "Music")

/// The Google sign-in window. The owner types their own credentials into a throwaway web view;
/// once music.youtube.com is loaded with a session cookie, the Google and YouTube cookies are
/// handed back and the window closes. Nothing is persisted here.
@MainActor
final class MusicSignInWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKHTTPCookieStoreObserver {
    static let signInURL = URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmusic.youtube.com%2F&hl=en")!
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

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
    private var completion: @MainActor ([StoredCookie]?) -> Void
    private var finished = false

    /// Shows the window. Calls `completion` once with the cookies, or nil when the window is closed early.
    static func present(completion: @escaping @MainActor ([StoredCookie]?) -> Void) {
        if let active {
            active.completion = completion
            active.show()
            return
        }
        let controller = MusicSignInWindowController(completion: completion)
        active = controller
        controller.show()
    }

    private init(completion: @escaping @MainActor ([StoredCookie]?) -> Void) {
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
        window.makeKeyAndOrderFront(nil)
        if webView.url == nil {
            webView.load(URLRequest(url: Self.signInURL))
        }
    }

    // MARK: - Session detection

    private func checkForSession() {
        guard !finished, Self.isMusicHost(webView.url) else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        Task { [weak self] in
            let cookies = await store.allCookies()
            guard let self, !self.finished,
                  Self.isMusicHost(self.webView.url),
                  Self.hasSessionCookie(cookies) else { return }
            logger.info("sign-in complete, harvesting cookies")
            self.finish(with: Self.harvest(cookies), closeWindow: true)
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
            Self.active = nil
            completion(cookies)
        }
    }

    // MARK: - Pure helpers

    nonisolated static func isMusicHost(_ url: URL?) -> Bool {
        url?.host()?.lowercased() == "music.youtube.com"
    }

    nonisolated static func hasSessionCookie(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }
    }

    /// google.com and youtube.com, subdomains included; lookalikes such as notgoogle.com are out.
    nonisolated static func isRelevantDomain(_ domain: String) -> Bool {
        var host = domain.lowercased()
        if host.hasPrefix(".") { host.removeFirst() }
        return ["google.com", "youtube.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    nonisolated static func harvest(_ cookies: [HTTPCookie]) -> [StoredCookie] {
        cookies.filter { isRelevantDomain($0.domain) }.map(StoredCookie.init)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkForSession()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: - WKHTTPCookieStoreObserver

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        checkForSession()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        finish(with: nil, closeWindow: false)
    }
}
