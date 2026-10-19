// DeciTests/Music/MusicServiceHostNavigationTests.swift
// The popup unmounts the Music tab's view on a switch to Mixer and builds it again on the way back, so what the
// tab shows over Home and Library (search results, an artist opened from them) lives in the host, one navigation
// for as long as the service.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicServiceHost navigation")
struct MusicServiceHostNavigationTests {

    private func makeHost(backend: FakeMusicBackend = FakeMusicBackend()) -> MusicServiceHost {
        MusicServiceHost(makeService: {
            MusicService(
                backend: backend,
                player: MusicPlayer(engine: FakePlaybackEngine()),
                presentSignIn: { _ in },
                nowPlaying: NowPlayingController(surface: FakeNowPlayingSurface(), fetchArtwork: { _ in nil }),
                refreshOnCreate: false
            )
        })
    }

    @Test("Before the Music tab opens there is no navigation, and reading it never creates the service")
    func noneBeforeLoad() {
        let host = makeHost()
        #expect(host.navigation == nil)
        #expect(host.service == nil)
    }

    @Test("Opening the Music tab builds the navigation with the service")
    func builtWithTheService() {
        let host = makeHost()
        host.loadIfNeeded()
        #expect(host.service != nil)
        #expect(host.navigation != nil)
    }

    @Test("Loading again keeps the one navigation, and its service")
    func sameInstanceAfterLoadingAgain() throws {
        let host = makeHost()
        host.loadIfNeeded()
        let first = try #require(host.navigation)
        let service = try #require(host.service)

        host.loadIfNeeded()

        #expect(host.navigation === first)
        #expect(host.service === service)
    }

    @Test("An artist opened from the results is still open when the view asks for the navigation again")
    func openArtistSurvivesTheViewBeingBuiltAgain() async throws {
        let backend = FakeMusicBackend()
        let host = makeHost(backend: backend)
        host.loadIfNeeded()
        let service = try #require(host.service)
        let navigation = try #require(host.navigation)
        let artist = MusicSamples.collection("UCa", kind: .artist, title: "Alpha", subtitle: "Artist")
        await backend.setSearch("alpha", results: [MusicSamples.track("s1")])
        await backend.setArtistSearch("alpha", results: [artist])
        service.query = "alpha"
        navigation.submit()
        await service.searchTask?.value
        navigation.openArtist(artist)
        #expect(navigation.hidesResults)
        #expect(navigation.showsResults == false)

        // The popup goes to Mixer and back: the Music view is built again and reads the host's navigation.
        let again = try #require(host.navigation)

        #expect(again === navigation)
        #expect(again.hidesResults)
        #expect(again.showsResults == false)
        #expect(again.isBrowsing)
        #expect(service.browse.path.map(\.browseId) == ["UCa"])
        // Back still returns to the results, as it would have without the switch.
        service.browse.back()
        #expect(again.showsResults)
    }
}
