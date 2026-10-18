// DeciTests/Music/MusicAccountCardContentTests.swift
// The words on the account card: which name, handle and channel kind line it shows for each
// combination of what is known. The card view itself only lays these out.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicAccountCardContent")
struct MusicAccountCardContentTests {
    private let account = MusicAccount(name: "Test Listener", handle: "@testlistener", photoURL: nil)

    @Test("a known account shows its name and handle")
    func nameAndHandle() {
        let content = MusicAccountCardContent(account: account, isBrandChannel: nil)
        #expect(content.title == "Test Listener")
        #expect(content.handle == "@testlistener")
    }

    @Test("an account without a handle shows no handle line")
    func noHandle() {
        let plain = MusicAccount(name: "Plain Account", handle: nil, photoURL: nil)
        let content = MusicAccountCardContent(account: plain, isBrandChannel: nil)
        #expect(content.title == "Plain Account")
        #expect(content.handle == nil)
    }

    @Test("no account yet falls back to Signed in and no handle")
    func noAccount() {
        let content = MusicAccountCardContent(account: nil, isBrandChannel: nil)
        #expect(content.title == "Signed in")
        #expect(content.handle == nil)
    }

    @Test("a brand channel is labelled Brand channel")
    func brandChannel() {
        #expect(MusicAccountCardContent(account: account, isBrandChannel: true).kind == "Brand channel")
    }

    @Test("an own channel is labelled Your own channel")
    func ownChannel() {
        #expect(MusicAccountCardContent(account: account, isBrandChannel: false).kind == "Your own channel")
    }

    @Test("an unknown channel kind shows no line")
    func unknownKind() {
        #expect(MusicAccountCardContent(account: account, isBrandChannel: nil).kind == nil)
    }

    @Test("the channel kind is shown even before the account menu answered")
    func kindWithoutAccount() {
        #expect(MusicAccountCardContent(account: nil, isBrandChannel: true).kind == "Brand channel")
        #expect(MusicAccountCardContent(account: nil, isBrandChannel: false).kind == "Your own channel")
    }

    @Test("a long name is kept whole, the view truncates it")
    func longName() {
        let long = String(repeating: "Name ", count: 40)
        let content = MusicAccountCardContent(
            account: MusicAccount(name: long, handle: nil, photoURL: nil),
            isBrandChannel: nil
        )
        #expect(content.title == long)
    }
}
