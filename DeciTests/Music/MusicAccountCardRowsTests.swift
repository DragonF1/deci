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

    @Test("the show-window row keeps the flow's own icon and chevron, and a row that is only off keeps both too")
    func showWindowKeepsIcon() {
        let idle = MusicAccountCardRows(isSwitchingChannel: false, isAddingAccount: false)
        let switching = MusicAccountCardRows(isSwitchingChannel: true, isAddingAccount: false)
        let adding = MusicAccountCardRows(isSwitchingChannel: false, isAddingAccount: true)
        #expect(switching.switchChannel.symbol == idle.switchChannel.symbol)
        #expect(adding.useAnotherAccount.symbol == idle.useAnotherAccount.symbol)
        #expect(switching.useAnotherAccount.symbol == idle.useAnotherAccount.symbol)
        #expect(adding.switchChannel.symbol == idle.switchChannel.symbol)
        #expect(switching.switchChannel.hasChevron)
        #expect(adding.switchChannel.hasChevron)
    }

    @Test("only Switch channel has a chevron, and only Sign out is destructive")
    func chevronAndTint() {
        let idle = MusicAccountCardRows(isSwitchingChannel: false, isAddingAccount: false)
        #expect(idle.switchChannel.hasChevron)
        #expect(!idle.useAnotherAccount.hasChevron)
        #expect(!MusicAccountCardRows.signOut.hasChevron)
        #expect(MusicAccountCardRows.signOut.isDestructive)
        #expect(!idle.switchChannel.isDestructive)
        #expect(!idle.useAnotherAccount.isDestructive)
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
