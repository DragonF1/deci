// DeciTests/Music/MusicSecretStoreTests.swift
// The Keychain item that holds the sign-in cookies. The round trip touches the real login
// keychain (under a throwaway service name), so it only runs when DECI_MUSIC_KEYCHAIN=1.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicSecretStore")
struct MusicSecretStoreTests {

    @Test("The production store uses the agreed service and account")
    func defaultIdentity() {
        let store = KeychainSecretStore()
        #expect(store.service == "com.abraham.Deci.music")
        #expect(store.account == "cookies")
    }

    @Test(
        "Keychain save, overwrite, load and delete round-trip",
        .enabled(if: ProcessInfo.processInfo.environment["DECI_MUSIC_KEYCHAIN"] == "1")
    )
    func keychainRoundTrip() throws {
        let store = KeychainSecretStore(service: "com.abraham.Deci.music.test.\(UUID().uuidString)", account: "cookies")
        defer { store.delete() }

        #expect(store.load() == nil)
        try store.save(Data("first".utf8))
        #expect(store.load() == Data("first".utf8))
        try store.save(Data("second".utf8))
        #expect(store.load() == Data("second".utf8))
        store.delete()
        #expect(store.load() == nil)
    }

    @Test("MemorySecretStore counts saves and deletes for the client tests")
    func memoryStoreBehaves() throws {
        let store = MemorySecretStore()
        #expect(store.load() == nil)
        try store.save(Data([1, 2]))
        #expect(store.load() == Data([1, 2]))
        #expect(store.saveCount == 1)
        store.delete()
        #expect(store.load() == nil)
        #expect(store.deleteCount == 1)
    }
}
