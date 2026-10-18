// DeciTests/Music/MusicLiveAccountTests.swift
// Hits the real YouTube Music `account/account_menu` endpoint through the real client and transport,
// on the signed-in session in the Deci Keychain item.
// Skipped unless DECI_MUSIC_LIVE=1 (pass it to xcodebuild as TEST_RUNNER_DECI_MUSIC_LIVE=1).
// Prints three booleans only, never the name, handle, photo URL, ids or cookies: the account is the owner's.
// Checks go through local Bools so a failed #expect cannot print a value either.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite(
    "Music live account",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["DECI_MUSIC_LIVE"] == "1")
)
struct MusicLiveAccountTests {

    private func report(_ line: String) {
        print(line)
        guard let path = ProcessInfo.processInfo.environment["DECI_MUSIC_LIVE_LOG"],
              let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    @Test("The real account menu names the signed-in account, and its avatar is an https URL")
    func accountAgainstTheRealEndpoint() async throws {
        let directory = makeTemporaryDirectory("deci-music-live-account")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = InnerTubeClient(transport: URLSessionTransport(), secretStore: KeychainSecretStore())
        let cache = PlayerCache(directory: directory)
        let resolver = StreamResolver(client: client, solver: FakeChallengeSolver(), cache: cache)
        let backend = MusicBackendLive(client: client, resolver: resolver)

        let account = try await backend.accountInfo()
        let found = account != nil
        let hasHandle = account?.handle != nil
        let hasPhoto = account?.photoURL != nil
        report("MUSIC_LIVE account accountFound=\(found) hasHandle=\(hasHandle) hasPhoto=\(hasPhoto)")
        #expect(found)
        let nameFilled = account.map { !$0.name.isEmpty } ?? false
        #expect(nameFilled)
        let photoIsHTTPS = account?.photoURL.map { $0.scheme == "https" } ?? true
        #expect(photoIsHTTPS)
        let handleIsAHandle = account?.handle.map { $0.hasPrefix("@") } ?? true
        #expect(handleIsAHandle)
    }
}
