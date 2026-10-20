// DeciTests/Music/MusicPlayerColumnLogicTests.swift
// The player column's rules kept apart from its views: which state it is in, what each state dims and says, and the
// accent it takes from the cover.

import Testing
@testable import Deci

@Suite("MusicPlayerColumnState")
struct MusicPlayerColumnStateTests {
    private func state(
        signedIn: Bool = true, track: Bool = true, loading: Bool = false, playing: Bool = false
    ) -> MusicPlayerColumnState {
        .resolve(isSignedIn: signedIn, hasTrack: track, isLoading: loading, isPlaying: playing)
    }

    @Test("signed out wins over everything")
    func signedOut() {
        #expect(state(signedIn: false) == .signedOut)
        #expect(state(signedIn: false, track: true, loading: true, playing: true) == .signedOut)
    }

    @Test("no song is the empty state")
    func empty() {
        #expect(state(track: false) == .empty)
        #expect(state(track: false, loading: true, playing: true) == .empty)
    }

    @Test("a song that is loading is loading, whether or not it is also marked as playing")
    func loading() {
        #expect(state(loading: true) == .loading)
        #expect(state(loading: true, playing: true) == .loading)
    }

    @Test("a loaded song is playing or paused")
    func playingAndPaused() {
        #expect(state(playing: true) == .playing)
        #expect(state(playing: false) == .paused)
    }

    @Test("each state has its own kicker, and only paused reads brighter")
    func kickers() {
        #expect(MusicPlayerColumnState.playing.kicker == "NOW PLAYING")
        #expect(MusicPlayerColumnState.paused.kicker == "PAUSED")
        #expect(MusicPlayerColumnState.loading.kicker == "LOADING")
        #expect(MusicPlayerColumnState.empty.kicker == "NOTHING PLAYING")
        #expect(MusicPlayerColumnState.signedOut.kicker == "NOTHING PLAYING")
        #expect(MusicPlayerColumnState.paused.kickerOpacity == 0.60)
        for other in [MusicPlayerColumnState.playing, .loading, .empty, .signedOut] {
            #expect(other.kickerOpacity == 0.45)
        }
    }

    @Test("signed out and empty share a layout with their own words")
    func emptyWords() {
        #expect(MusicPlayerColumnState.empty.isEmptyLayout)
        #expect(MusicPlayerColumnState.signedOut.isEmptyLayout)
        #expect(MusicPlayerColumnState.empty.emptyTitle == "Pick something to play")
        #expect(MusicPlayerColumnState.empty.emptySubtitle == "Choose a song in Home or Library")
        #expect(MusicPlayerColumnState.signedOut.emptyTitle == "Not signed in")
        #expect(MusicPlayerColumnState.signedOut.emptySubtitle == "Your music shows up here after you sign in")
        for other in [MusicPlayerColumnState.playing, .paused, .loading] {
            #expect(other.isEmptyLayout == false)
        }
    }

    @Test("the transport and the view buttons dim and go dead with nothing to control")
    func controls() {
        for dead in [MusicPlayerColumnState.empty, .signedOut] {
            #expect(dead.controlsOpacity == 0.30)
            #expect(dead.controlsAreEnabled == false)
        }
        for live in [MusicPlayerColumnState.playing, .paused, .loading] {
            #expect(live.controlsOpacity == 1)
            #expect(live.controlsAreEnabled)
        }
    }

    @Test("loading dims the cover, and paused dims the bars")
    func dimming() {
        #expect(MusicPlayerColumnState.loading.coverOpacity == 0.45)
        #expect(MusicPlayerColumnState.playing.coverOpacity == 1)
        #expect(MusicPlayerColumnState.paused.barsOpacity == 0.55)
        #expect(MusicPlayerColumnState.playing.barsOpacity == 1)
    }

    @Test("only a playing or paused song shows progress")
    func progressStates() {
        for shown in [MusicPlayerColumnState.playing, .paused] {
            #expect(shown.showsProgress)
        }
        for hidden in [MusicPlayerColumnState.loading, .empty, .signedOut] {
            #expect(hidden.showsProgress == false)
        }
    }

    @Test("the accent wash is 0.16, and 0.05 when nothing plays")
    func wash() {
        #expect(MusicPlayerColumnState.playing.washOpacity == 0.16)
        #expect(MusicPlayerColumnState.loading.washOpacity == 0.16)
        #expect(MusicPlayerColumnState.empty.washOpacity == 0.05)
        #expect(MusicPlayerColumnState.signedOut.washOpacity == 0.05)
    }
}

@Suite("MusicAccent")
struct MusicAccentTests {
    @Test("a dark cover colour is lifted to a bright accent and keeps its hue")
    func darkIsLifted() {
        let lifted = MusicAccent.lifted(MusicTint(hue: 0.58, saturation: 0.70, brightness: 0.31))
        #expect(lifted.brightness == MusicAccent.minBrightness)
        #expect(lifted.hue == 0.58)
        #expect(lifted.saturation == 0.70)
    }

    @Test("a cover colour that is already bright and rich is left alone")
    func brightIsKept() {
        let tint = MusicTint(hue: 0.07, saturation: 0.67, brightness: 0.90)
        #expect(MusicAccent.lifted(tint) == tint)
    }

    @Test("a grey cover stays neutral and only brightens, so it does not pick up a colour from its hue")
    func greyStaysNeutral() {
        let grey = MusicTint(hue: 0.3, saturation: 0.05, brightness: 0.30)
        let lifted = MusicAccent.lifted(grey)
        #expect(lifted.saturation == 0.05)
        #expect(lifted.brightness == MusicAccent.minBrightness)
    }

    @Test("a pale colour gets enough saturation to read as a colour")
    func paleIsThickened() {
        let lifted = MusicAccent.lifted(MusicTint(hue: 0.9, saturation: 0.2, brightness: 0.88))
        #expect(lifted.saturation == MusicAccent.minSaturation)
        #expect(lifted.hue == 0.9)
    }

    @Test("lifting twice changes nothing more", arguments: [
        MusicTint(hue: 0.1, saturation: 0.5, brightness: 0.2),
        MusicTint(hue: 0.6, saturation: 0.02, brightness: 0.5),
        MusicTint(hue: 0.9, saturation: 0.15, brightness: 1),
    ])
    func idempotent(tint: MusicTint) {
        let once = MusicAccent.lifted(tint)
        #expect(MusicAccent.lifted(once) == once)
    }

    @Test("every accent is bright enough for the column's near black")
    func alwaysBright() {
        for tint in MusicTint.palette {
            #expect(MusicAccent.lifted(tint).brightness >= MusicAccent.minBrightness)
        }
    }

    @Test("the cover's colour wins; without one the song's palette tint stands in; with neither, the design's orange")
    func sources() {
        let cover = MusicTint(hue: 0.5, saturation: 0.6, brightness: 0.4)
        #expect(MusicAccent.accent(cover: cover, videoId: "x") == MusicAccent.lifted(cover))
        #expect(MusicAccent.accent(cover: nil, videoId: "x") == MusicAccent.lifted(MusicTint.forKey("x")))
        #expect(MusicAccent.accent(cover: nil, videoId: nil) == MusicAccent.fallback)
    }

    @Test("the fallback is the mock's orange, about #E0874A")
    func fallbackIsOrange() {
        #expect(abs(MusicAccent.fallback.hue - 0.068) < 0.001)
        #expect(MusicAccent.fallback.brightness >= MusicAccent.minBrightness)
    }
}
