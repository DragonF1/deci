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
        defer { try? store.delete() }

        #expect(store.load() == nil)
        try store.save(Data("first".utf8))
        #expect(store.load() == Data("first".utf8))
        try store.save(Data("second".utf8))
        #expect(store.load() == Data("second".utf8))
        try store.delete()
        #expect(store.load() == nil)
        try store.delete()
    }

    @Test("MemorySecretStore counts saves and deletes for the client tests")
    func memoryStoreBehaves() throws {
        let store = MemorySecretStore()
        #expect(store.load() == nil)
        try store.save(Data([1, 2]))
        #expect(store.load() == Data([1, 2]))
        #expect(store.saveCount == 1)
        try store.delete()
        #expect(store.load() == nil)
        #expect(store.deleteCount == 1)
    }

    @Test("MemorySecretStore refuses on demand and counts only what went through")
    func memoryStoreRefuses() throws {
        let store = MemorySecretStore(data: Data([1]))
        store.failSaves = true
        store.failDeletes = true
        #expect(throws: KeychainSecretStore.KeychainError.self) { try store.save(Data([2])) }
        #expect(throws: KeychainSecretStore.KeychainError.self) { try store.delete() }
        #expect(store.contents == Data([1]))
        #expect(store.saveCount == 0)
        #expect(store.deleteCount == 0)

        store.failDeletes = false
        try store.delete()
        #expect(store.contents == nil)
        #expect(store.deleteCount == 1)
    }
}
