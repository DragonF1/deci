// DeciTests/Music/MusicAccountCardRowsTests.swift
// Which of the account card's two window rows can be pressed, and what they say, for each
// combination of the flows running. The card view only lays these out.

import Testing
@testable import Deci

@MainActor
@Suite("MusicAccountCardRows")
struct MusicAccountCardRowsTests {
    private let switchTitle = "Switch channel"
    private let addTitle = "Use another Google account"
    private let showTitle = "Show sign-in window"

    @Test("with nothing running both rows start their flow")
    func idle() {
        let rows = MusicAccountCardRows(isSwitchingChannel: false, isAddingAccount: false)
        #expect(rows.switchChannel.title == switchTitle)
        #expect(rows.switchChannel.isEnabled)
        #expect(rows.useAnotherAccount.title == addTitle)
        #expect(rows.useAnotherAccount.isEnabled)
    }

    @Test("during a channel switch its row shows the window and the other row is off")
    func switching() {
        let rows = MusicAccountCardRows(isSwitchingChannel: true, isAddingAccount: false)
        #expect(rows.switchChannel.title == showTitle)
        #expect(rows.switchChannel.isEnabled)
        #expect(rows.useAnotherAccount.title == addTitle)
        #expect(!rows.useAnotherAccount.isEnabled)
    }

    @Test("while adding an account its row shows the window and the other row is off")
    func adding() {
        let rows = MusicAccountCardRows(isSwitchingChannel: false, isAddingAccount: true)
        #expect(rows.useAnotherAccount.title == showTitle)
        #expect(rows.useAnotherAccount.isEnabled)
        #expect(rows.switchChannel.title == switchTitle)
        #expect(!rows.switchChannel.isEnabled)
    }

    @Test("the show-window row has its own symbol, not the flow's")
    func showWindowSymbol() {
        let idle = MusicAccountCardRows(isSwitchingChannel: false, isAddingAccount: false)
        let switching = MusicAccountCardRows(isSwitchingChannel: true, isAddingAccount: false)
        let adding = MusicAccountCardRows(isSwitchingChannel: false, isAddingAccount: true)
        #expect(switching.switchChannel.symbol == MusicAccountCardRows.showWindowSymbol)
        #expect(adding.useAnotherAccount.symbol == MusicAccountCardRows.showWindowSymbol)
        #expect(switching.switchChannel.symbol != idle.switchChannel.symbol)
        #expect(adding.useAnotherAccount.symbol != idle.useAnotherAccount.symbol)
        // A row that is only off keeps its own symbol.
        #expect(switching.useAnotherAccount.symbol == idle.useAnotherAccount.symbol)
        #expect(adding.switchChannel.symbol == idle.switchChannel.symbol)
    }

    @Test("both flows at once cannot happen, and turns both rows off rather than guessing a window")
    func both() {
        let rows = MusicAccountCardRows(isSwitchingChannel: true, isAddingAccount: true)
        #expect(!rows.switchChannel.isEnabled)
        #expect(!rows.useAnotherAccount.isEnabled)
        #expect(rows.switchChannel.title != showTitle)
        #expect(rows.useAnotherAccount.title != showTitle)
    }

    @Test("Sign out is always there and never off")
    func signOutAlwaysOn() {
        #expect(MusicAccountCardRows.signOut.title == "Sign out")
        #expect(MusicAccountCardRows.signOut.isEnabled)
    }
}
