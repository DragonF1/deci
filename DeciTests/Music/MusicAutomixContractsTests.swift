// DeciTests/Music/MusicAutomixContractsTests.swift
// The plain-value rules behind the playlist automix: which errors end a queue's paging for good, which browse ids are
// mixes, and which playlist id a page asks YouTube's automix of.

import Foundation
import Testing
@testable import Deci

@Suite("MusicError endsPaging")
struct MusicErrorEndsPagingTests {
    @Test("An unreadable response ends the paging: asking again would read the same thing")
    func parse() {
        #expect(MusicError.endsPaging(MusicError.parse("no panel")))
    }

    @Test("A rejected request (4xx) ends the paging, except a timeout (408) and a rate limit (429)")
    func clientErrors() {
        for status in [400, 401, 403, 404, 410, 418, 499] {
            #expect(MusicError.endsPaging(MusicError.http(status)), "status \(status)")
        }
        for status in [408, 429] {
            #expect(MusicError.endsPaging(MusicError.http(status)) == false, "status \(status)")
        }
    }

    @Test("Server errors and statuses outside 4xx wait for a retry")
    func otherStatuses() {
        for status in [0, 200, 302, 399, 500, 502, 503, 504, 599] {
            #expect(MusicError.endsPaging(MusicError.http(status)) == false, "status \(status)")
        }
    }

    @Test("The other music errors are not permanent")
    func otherMusicErrors() {
        let errors: [MusicError] = [.signedOut, .unplayable("Video unavailable"), .noAudioFormat, .solver("boom"), .rejected]
        for error in errors {
            #expect(MusicError.endsPaging(error) == false, "\(error)")
        }
    }

    @Test("An error that is not a MusicError (no network, cancelled) is not permanent")
    func foreignErrors() {
        #expect(MusicError.endsPaging(URLError(.notConnectedToInternet)) == false)
        #expect(MusicError.endsPaging(URLError(.timedOut)) == false)
        #expect(MusicError.endsPaging(CancellationError()) == false)
    }
}

@Suite("MusicBrowsePage automix ids")
struct MusicBrowsePageAutomixTests {
    @Test("A mix's browse id gives its playlist id, with or without the VL prefix")
    func mixIds() {
        let cases: [(browseId: String, playlist: String)] = [
            ("VLRDTMAK5uy_nA1b2c3", "RDTMAK5uy_nA1b2c3"),
            ("RDTMAK5uy_nA1b2c3", "RDTMAK5uy_nA1b2c3"),
            ("VLRDAMVM4D7u5KF7SP8", "RDAMVM4D7u5KF7SP8"),
            ("VLRDAMPLPL123", "RDAMPLPL123"),
            ("VLRDEMabcdef", "RDEMabcdef"),
            ("VLRDATabcdef", "RDATabcdef"),
            ("VLRDGMEMabcdef", "RDGMEMabcdef"),
        ]
        for item in cases {
            #expect(MusicBrowsePage.mixPlaylistId(ofBrowseId: item.browseId) == item.playlist, "\(item.browseId)")
        }
    }

    @Test("RDCLAK5uy_ pages are curated playlists, not mixes")
    func curatedPlaylistsAreNotMixes() {
        #expect(MusicBrowsePage.mixPlaylistId(ofBrowseId: "VLRDCLAK5uy_kAbCdEf") == nil)
        #expect(MusicBrowsePage.mixPlaylistId(ofBrowseId: "RDCLAK5uy_kAbCdEf") == nil)
    }

    @Test("Playlists, albums, artists, Liked Music and nonsense are not mixes")
    func notMixes() {
        let ids = [
            "VLPL123", "PL123", "VLLM", "LM", "VLOLAK5uy_abc", "MPREb_abc", "UCabc", "FEmusic_home",
            "", "VL", "vlrdtmak5uy_abc", "rdtmak5uy_abc", "xRDTMAK5uy_abc", " VLRDTMAK5uy_abc",
        ]
        for id in ids {
            #expect(MusicBrowsePage.mixPlaylistId(ofBrowseId: id) == nil, "\"\(id)\"")
        }
    }

    @Test("A playlist page asks the automix of its playlist, the VL prefix dropped")
    func playlistPage() {
        #expect(MusicSamples.page("VLPL123").automixPlaylistId == "PL123")
        #expect(MusicSamples.page("VLPLa-b_c").automixPlaylistId == "PLa-b_c")
    }

    @Test("Liked Music asks the automix of LM")
    func likedMusic() {
        #expect(MusicSamples.page("VLLM").automixPlaylistId == "LM")
    }

    @Test("A curated RDCLAK5uy_ playlist asks the automix like any playlist")
    func curatedPlaylist() {
        #expect(MusicSamples.page("VLRDCLAK5uy_kAbCdEf").automixPlaylistId == "RDCLAK5uy_kAbCdEf")
    }

    @Test("An album asks the automix of its OLAK audio playlist, and nothing without one")
    func album() {
        #expect(MusicSamples.page("MPREb_abc", audioPlaylistId: "OLAK5uy_xyz").automixPlaylistId == "OLAK5uy_xyz")
        #expect(MusicSamples.page("MPREb_abc").automixPlaylistId == nil)
        #expect(MusicSamples.page("MPREb_abc", audioPlaylistId: "").automixPlaylistId == nil)
    }

    @Test("A playlist page takes its own id, not an audio playlist id it happens to carry")
    func playlistIgnoresAudioPlaylistId() {
        #expect(MusicSamples.page("VLPL123", audioPlaylistId: "OLAK5uy_xyz").automixPlaylistId == "PL123")
    }

    @Test("Mixes have no automix: they get their own endless treatment")
    func mixes() {
        for id in ["VLRDTMAK5uy_abc", "VLRDAMVM4D7u5KF7SP8", "VLRDEMabc", "VLRDATabc"] {
            #expect(MusicSamples.page(id).automixPlaylistId == nil, "\(id)")
        }
    }

    @Test("Artist pages and unknown ids have no automix, whatever else the page carries")
    func others() {
        #expect(MusicSamples.page("UCabc").automixPlaylistId == nil)
        #expect(MusicSamples.page("UCabc", audioPlaylistId: "OLAK5uy_xyz").automixPlaylistId == nil)
        #expect(MusicSamples.page("FEmusic_home").automixPlaylistId == nil)
        #expect(MusicSamples.page("").automixPlaylistId == nil)
    }

    @Test("A bare VL has no playlist behind it")
    func bareVL() {
        #expect(MusicSamples.page("VL").automixPlaylistId == nil)
    }

    @Test("A mix page names its own mix playlist, and every other page names none")
    func pageMixPlaylistId() {
        for (id, playlist) in [
            ("VLRDTMAK5uy_abc", "RDTMAK5uy_abc"), ("VLRDAMVM4D7u5KF7SP8", "RDAMVM4D7u5KF7SP8"),
            ("VLRDEMabc", "RDEMabc"), ("VLRDATabc", "RDATabc"),
        ] {
            #expect(MusicSamples.page(id).mixPlaylistId == playlist, "\(id)")
        }
        for id in ["VLPL123", "VLLM", "VLRDCLAK5uy_kAbCdEf", "MPREb_abc", "UCabc", "FEmusic_home", "", "VL"] {
            #expect(MusicSamples.page(id).mixPlaylistId == nil, "\"\(id)\"")
        }
        #expect(MusicSamples.page("MPREb_abc", audioPlaylistId: "OLAK5uy_xyz").mixPlaylistId == nil)
    }

    @Test("A page is a mix or has an automix, never both")
    func mixOrAutomix() {
        for id in ["VLRDTMAK5uy_abc", "VLRDAMVM4D7u5KF7SP8", "VLRDCLAK5uy_kAbCdEf", "VLPL123", "VLLM", "UCabc", "MPREb_abc"] {
            let page = MusicSamples.page(id)
            #expect(page.mixPlaylistId == nil || page.automixPlaylistId == nil, "\(id)")
        }
    }

    @Test("A page carries no audio playlist id unless it is given one")
    func audioPlaylistIdDefaults() {
        #expect(MusicSamples.page("VLPL123").audioPlaylistId == nil)
        #expect(MusicSamples.page("MPREb_abc", audioPlaylistId: "OLAK5uy_xyz").audioPlaylistId == "OLAK5uy_xyz")
        #expect(MusicSamples.page("MPREb_abc") != MusicSamples.page("MPREb_abc", audioPlaylistId: "OLAK5uy_xyz"))
    }
}
