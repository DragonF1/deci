// DeciTests/Music/MusicGenreFamilyTests.swift
// What kind of music a song is taken for, from its tags, its tempo and its energy.

import Testing
@testable import Deci

@Suite("Music genre family")
struct MusicGenreFamilyTests {
    private typealias G = MusicGenre

    private func family(_ tags: [String], bpm: Double? = nil, energy: Double? = nil) -> MusicGenreFamily {
        G.classify(tags: tags, bpm: bpm, energy: energy).family
    }

    @Test("one tag names its family", arguments: [
        ("House", MusicGenreFamily.house), ("Tech House", .house), ("Techno/House", .house), ("melodic techno", .techno),
        ("Psytrance", .trance), ("Drum & Bass", .dnb), ("drum and bass", .dnb), ("Drum'n'Bass", .dnb), ("Dubstep", .bass),
        ("melodic dubstep", .bass), ("Hardstyle", .bass), ("UK Garage", .garage), ("Rap/Hip Hop", .hipHop), ("Hip-Hop", .hipHop),
        ("R&B", .hipHop), ("alternative r&b", .hipHop), ("Reggaeton", .latin), ("latin trap", .latin), ("Afrobeats", .afro),
        ("Dancehall", .afro), ("Pop", .pop), ("synth-pop", .pop), ("K-Pop", .pop), ("Alternative", .rock), ("pop punk", .rock),
        ("Folk", .soft), ("indie folk", .soft), ("Lo-Fi Hip Hop", .soft), ("Musica Urbana", .latin), ("M\u{fa}sica urbana", .latin),
    ])
    func tags(_ tag: String, _ expected: MusicGenreFamily) {
        let genre = G.classify(tags: [tag], bpm: nil, energy: nil)
        #expect(genre.family == expected)
        #expect(!genre.isGuess)
    }

    @Test("no family's name is also listed under another")
    func noDuplicates() {
        for family in MusicGenreFamily.allCases {
            for name in G.names[family] ?? [] {
                #expect(G.vote(name, bpm: nil, energy: nil)?.family == family, "\(name)")
                #expect(G.normalized(name) == name, "\(name) is not normalized, so no tag can match it")
            }
        }
    }

    @Test("a tag nobody knows says nothing")
    func unknownTag() {
        #expect(G.classify(tags: ["zzz", "", "2010s", "female vocalists"], bpm: nil, energy: nil) == .unknown)
    }

    @Test("a field as wide as dance or electronic is the kind its tempo has")
    func wideTags() {
        #expect(family(["Dance"], bpm: 124, energy: 0.8) == .house)
        #expect(family(["Electronic"], bpm: 174, energy: 0.9) == .dnb)
        #expect(family(["electronic"], bpm: 87, energy: 0.9) == .dnb)
        #expect(family(["EDM"], bpm: 145, energy: 0.9) == .bass)
        #expect(family(["Dance"], bpm: 100, energy: 0.5) == .pop)
    }

    @Test("an exact name outvotes a wide one, whichever comes first")
    func exactWins() {
        #expect(family(["Electro", "dubstep"], bpm: 140, energy: 0.9) == .bass)
        #expect(family(["dance", "reggaeton"], bpm: 95, energy: 0.8) == .latin)
    }

    @Test("a tempo a family never has counts against it")
    func wrongTempo() {
        // "house" first, then two that fit 174 bpm.
        #expect(family(["drum and bass", "house"], bpm: 174, energy: 0.9) == .dnb)
        #expect(family(["house", "drum and bass"], bpm: 174, energy: 0.9) == .dnb)
        #expect(family(["house", "drum and bass"], bpm: 124, energy: 0.9) == .house)
        #expect(family(["house"], bpm: 174, energy: 0.9) == .house, "with no other name it still counts")
    }

    @Test("without a tag, tempo and energy make a guess")
    func guesses() {
        #expect(G.classify(tags: [], bpm: 124, energy: 0.8) == G(family: .house, isGuess: true))
        #expect(G.classify(tags: [], bpm: 92, energy: 0.8) == G(family: .hipHop, isGuess: true))
        #expect(G.classify(tags: [], bpm: 92, energy: 0.2) == G(family: .soft, isGuess: true))
        #expect(G.classify(tags: [], bpm: 174, energy: 0.9) == G(family: .dnb, isGuess: true))
        #expect(G.classify(tags: [], bpm: nil, energy: 0.9) == .unknown)
        #expect(G.classify(tags: [], bpm: .nan, energy: .nan) == .unknown)
        #expect(G.classify(tags: [], bpm: -5, energy: 2) == .unknown)
    }

    @Test("half and double the tempo belong to the family too")
    func halfTempo() {
        #expect(MusicGenreFamily.dnb.holds(bpm: 87))
        #expect(MusicGenreFamily.hipHop.holds(bpm: 150))
        #expect(!MusicGenreFamily.house.holds(bpm: 174))
        #expect(MusicGenreFamily.pop.holds(bpm: 174))
    }
}
