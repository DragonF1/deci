// DeciTests/Music/MusicAccountCardRowsTests.swift
// Which of the account card's two window rows can be pressed, and what they say, for each
// combination of the flows running. The card view only lays these out.

import Testing
@testable import Deci

@MainActor
@Suite("MusicAccountCardRows")
struct MusicAccountCardRowsTests {
    private let switchTitle = "Switch channel\u{2026}"
    private let addTitle = "Add account\u{2026}"
    private let showTitle = "Show sign-in window"

    @Test("with nothing running both rows start their flow")
    func idle() {
        let rows = MusicAccountCardRows(isSwitchingChannel: false, isAddingAccount: false)
        #expect(rows.switchChannel.title == switchTitle)
        #expect(rows.switchChannel.isEnabled)
        #expect(rows.addAccount.title == addTitle)
        #expect(rows.addAccount.isEnabled)
    }

    @Test("during a channel switch its row shows the window and the other row is off")
    func switching() {
        let rows = MusicAccountCardRows(isSwitchingChannel: true, isAddingAccount: false)
        #expect(rows.switchChannel.title == showTitle)
        #expect(rows.switchChannel.isEnabled)
        #expect(rows.addAccount.title == addTitle)
        #expect(!rows.addAccount.isEnabled)
    }

    @Test("while adding an account its row shows the window and the other row is off")
    func adding() {
        let rows = MusicAccountCardRows(isSwitchingChannel: false, isAddingAccount: true)
        #expect(rows.addAccount.title == showTitle)
        #expect(rows.addAccount.isEnabled)
        #expect(rows.switchChannel.title == switchTitle)
        #expect(!rows.switchChannel.isEnabled)
    }

    @Test("both flows at once cannot happen, and turns both rows off rather than guessing a window")
    func both() {
        let rows = MusicAccountCardRows(isSwitchingChannel: true, isAddingAccount: true)
        #expect(!rows.switchChannel.isEnabled)
        #expect(!rows.addAccount.isEnabled)
        #expect(rows.switchChannel.title != showTitle)
        #expect(rows.addAccount.title != showTitle)
    }

    @Test("Sign out and Settings are always there and never off")
    func fixedRows() {
        #expect(MusicAccountCardRows.signOut.title == "Sign out")
        #expect(MusicAccountCardRows.signOut.isEnabled)
        #expect(MusicAccountCardRows.settings.title == "Settings")
        #expect(MusicAccountCardRows.settings.isEnabled)
    }

    @Test("the signed-out card's Sign in row is off while the sign-in window is already open")
    func signIn() {
        #expect(MusicAccountCardRows.signIn(isSigningIn: false).title == "Sign in\u{2026}")
        #expect(MusicAccountCardRows.signIn(isSigningIn: false).isEnabled)
        #expect(!MusicAccountCardRows.signIn(isSigningIn: true).isEnabled)
    }
}
