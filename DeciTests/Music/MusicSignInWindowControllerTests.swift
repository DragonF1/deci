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

    @Test("Only a cancelled load is ignored as a failure after the pick")
    func cancellation() {
        #expect(MusicSignInWindowController.isCancellation(URLError(.cancelled)))
        #expect(!MusicSignInWindowController.isCancellation(URLError(.notConnectedToInternet)))
        #expect(!MusicSignInWindowController.isCancellation(NSError(domain: "WebKitErrorDomain", code: NSURLErrorCancelled)))
    }
}
