// Deci/Audio/Keys/PlaybackKeyCoordinator.swift
import AppKit
import os

/// What the monitor hands a decoded transport key to.
@MainActor
protocol PlaybackKeyHandling: AnyObject {
    func handle(_ key: PlaybackKey, phase: PlaybackKeyPhase)
}

/// The Chrome side of the transport keys: the tab list to choose from and the way to send a key to a tab.
@MainActor
protocol PlaybackKeyChromeControlling: AnyObject {
    var chromeTabs: [ChromeTab] { get }
    func sendMediaKey(tabId: Int, key: PlaybackKey)
}

extension ChromeExtensionManager: PlaybackKeyChromeControlling {}

/// Deci's player as the transport keys see it.
@MainActor
protocol PlaybackKeyDeciControlling: AnyObject {
    var playbackState: DeciPlaybackState { get }
    func perform(_ action: DeciPlaybackAction)
}

/// Carries out the route a transport key gets: reads the front app, the Chrome tabs and Deci's state when a fresh press
/// arrives, asks the router, and sends the key to the tab or to the player. Repeats and key-ups do nothing (the monitor
/// swallows them), and the router's memory of the tab a key paused is cleared when another app is activated.
@MainActor
final class PlaybackKeyCoordinator: PlaybackKeyHandling {
    private let chrome: any PlaybackKeyChromeControlling
    private let deci: any PlaybackKeyDeciControlling
    private let frontmostBundleID: @MainActor () -> String?
    private let notificationCenter: NotificationCenter
    private var router = PlaybackKeyRouter()
    private var activationObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.abraham.Deci", category: "PlaybackKeys")

    /// The tab the last play/pause paused, until a press resumes it.
    var keyPausedTabID: Int? { router.keyPausedTabID }

    init(
        chrome: any PlaybackKeyChromeControlling,
        deci: any PlaybackKeyDeciControlling,
        frontmostBundleID: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.chrome = chrome
        self.deci = deci
        self.frontmostBundleID = frontmostBundleID
        self.notificationCenter = notificationCenter
        activationObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.frontmostApplicationChanged(to: bundleID) }
        }
    }

    isolated deinit {
        if let activationObserver { notificationCenter.removeObserver(activationObserver) }
    }

    func handle(_ key: PlaybackKey, phase: PlaybackKeyPhase) {
        guard phase == .down else { return }
        let route = router.route(
            key,
            frontmostBundleID: frontmostBundleID(),
            tabs: chrome.chromeTabs,
            deci: deci.playbackState
        )
        switch route {
        case .chromeTab(let id, let key):
            logger.debug("\(key.rawValue, privacy: .public) key to Chrome tab \(id)")
            chrome.sendMediaKey(tabId: id, key: key)
        case .deci(let action):
            logger.debug("\(key.rawValue, privacy: .public) key to Deci: \(String(describing: action), privacy: .public)")
            deci.perform(action)
        case .nothing:
            logger.debug("\(key.rawValue, privacy: .public) key: nothing to do")
        }
    }

    func frontmostApplicationChanged(to bundleID: String?) {
        router.frontmostApplicationChanged(to: bundleID)
    }
}
