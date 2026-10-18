// DeciTests/Music/MusicSignInWindowControllerTests.swift
// The pure URL checks behind the sign-in window's channel picker stage.

import Foundation
import Testing
@testable import Deci

@Suite("MusicSignInWindowController channel picker")
struct MusicSignInWindowControllerTests {

    @Test("A channel pick is a youtube.com signin with action_handle_signin or a pageid")
    func channelSwitchURLs() {
        #expect(MusicSignInWindowController.isChannelSwitch(URL(string: "https://www.youtube.com/signin?action_handle_signin=true&authuser=0&pageid=123&next=%2Faccount")))
        #expect(MusicSignInWindowController.isChannelSwitch(URL(string: "https://www.youtube.com/signin?action_handle_signin=true&authuser=0&next=%2F")))
        #expect(MusicSignInWindowController.isChannelSwitch(URL(string: "https://music.youtube.com/?pageid=123")))
        #expect(!MusicSignInWindowController.isChannelSwitch(URL(string: "https://www.youtube.com/account")))
        #expect(!MusicSignInWindowController.isChannelSwitch(URL(string: "https://accounts.google.com/signin?action_handle_signin=true")))
        #expect(!MusicSignInWindowController.isChannelSwitch(URL(string: "http://www.youtube.com/signin?action_handle_signin=true")))
        #expect(!MusicSignInWindowController.isChannelSwitch(nil))
    }

    @Test("Only https youtube.com hosts count as YouTube")
    func youTubeHosts() {
        #expect(MusicSignInWindowController.isYouTubeHost(URL(string: "https://www.youtube.com/account")))
        #expect(MusicSignInWindowController.isYouTubeHost(URL(string: "https://music.youtube.com/")))
        #expect(MusicSignInWindowController.isYouTubeHost(URL(string: "https://youtube.com/")))
        #expect(!MusicSignInWindowController.isYouTubeHost(URL(string: "https://notyoutube.com/")))
        #expect(!MusicSignInWindowController.isYouTubeHost(URL(string: "https://youtube.com.evil.example/")))
        #expect(!MusicSignInWindowController.isYouTubeHost(URL(string: "http://www.youtube.com/")))
    }

    @Test("A stored cookie converts back to an HTTPCookie for seeding the picker")
    func cookieRoundTrip() throws {
        let stored = StoredCookie(
            name: "SAPISID", value: "v", domain: ".youtube.com", path: "/",
            // Whole seconds and under Foundation's 400-day cookie cap, so the date comes back as is.
            expires: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 86_400).rounded()),
            isSecure: true, isHTTPOnly: false
        )
        let cookie = try #require(stored.httpCookie)
        #expect(StoredCookie(cookie) == stored)

        var httpOnly = stored
        httpOnly.name = "__Secure-3PSID"
        httpOnly.isHTTPOnly = true
        httpOnly.expires = nil
        let sessionCookie = try #require(httpOnly.httpCookie)
        #expect(StoredCookie(sessionCookie) == httpOnly)
    }

    @Test("Closing hands cookies back only once signed in, and a seeded picker only after a click")
    func closeDisposition() {
        typealias C = MusicSignInWindowController
        #expect(!C.harvestsOnClose(stage: .signingIn, seeded: false, channelPicked: false))
        #expect(C.harvestsOnClose(stage: .pickingChannel, seeded: false, channelPicked: false))
        #expect(!C.harvestsOnClose(stage: .pickingChannel, seeded: true, channelPicked: false))
        #expect(C.harvestsOnClose(stage: .pickingChannel, seeded: true, channelPicked: true))
        #expect(C.harvestsOnClose(stage: .confirming, seeded: true, channelPicked: true))
        #expect(C.harvestsOnClose(stage: .confirming, seeded: false, channelPicked: true))
    }

    @Test("Only a cancelled load is ignored as a failure after the pick")
    func cancellation() {
        #expect(MusicSignInWindowController.isCancellation(URLError(.cancelled)))
        #expect(!MusicSignInWindowController.isCancellation(URLError(.notConnectedToInternet)))
        #expect(!MusicSignInWindowController.isCancellation(NSError(domain: "WebKitErrorDomain", code: NSURLErrorCancelled)))
    }
}
