// Deci/Music/Playback/MusicGenreFamily.swift
// The kind of music a song is, as far as mixing it goes: read from the genre tags the music services give it, and from its
// tempo and energy when they give none. Pure.

import Foundation

nonisolated enum MusicGenreFamily: String, CaseIterable, Sendable {
    /// House, deep and progressive house, disco, nu disco.
    case house
    case techno
    case trance
    /// Drum and bass, jungle.
    case dnb
    /// Dubstep, riddim, future bass, festival trap, big room, electro house, hardstyle.
    case bass
    /// UK garage, 2-step, bassline.
    case garage
    /// Hip-hop, trap, drill, grime, phonk, R&B, soul, funk.
    case hipHop
    /// Reggaeton, dembow, salsa, bachata, cumbia.
    case latin
    /// Afrobeats, amapiano, dancehall, reggae.
    case afro
    case pop
    /// Rock, metal, punk, indie and alternative rock.
    case rock
    /// Ballads, folk, acoustic, country, jazz, classical, ambient, lo-fi.
    case soft
    /// Nothing is known about it.
    case open

    /// Its place in the list, for loops that compare numbers.
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Families a DJ mixes the same way: going from one group to another is a change of genre.
    var group: Int {
        switch self {
        case .house, .techno, .trance, .garage: 0
        case .dnb, .bass: 1
        case .hipHop, .latin, .afro, .pop: 2
        case .rock: 3
        case .soft: 4
        case .open: -1
        }
    }

    /// Tempos a song of the family plausibly has; nil when any will do.
    var tempoRange: ClosedRange<Double>? {
        switch self {
        case .house: 110...135
        case .techno: 120...155
        case .trance: 124...150
        case .dnb: 160...186
        case .bass: 125...165
        case .garage: 125...142
        case .hipHop: 60...112
        case .latin: 80...135
        case .afro: 88...125
        case .pop, .rock, .soft, .open: nil
        }
    }

    /// Whether a song at `bpm` can be of the family. A tempo detector may report half or double the tempo, so those count too.
    func holds(bpm: Double) -> Bool {
        guard let tempoRange else { return true }
        return [bpm, bpm / 2, bpm * 2].contains { tempoRange.contains($0) }
    }
}

/// A song's family, and whether a genre tag says so or its tempo and energy only suggest it.
nonisolated struct MusicGenre: Equatable, Sendable {
    var family: MusicGenreFamily = .open
    var isGuess = true

    static let unknown = MusicGenre()

    /// A tag that names one kind of music counts this much, one that names a whole field ("electronic") counts `broadVote`.
    static let exactVote = 3.0
    static let broadVote = 1.0
    /// Each further tag counts this much less: services list the best fitting first.
    static let voteDecay = 0.85
    /// A family whose songs never have this tempo keeps this much of its votes.
    static let wrongTempoShare = 0.3
    /// A loud song is seldom a soft one.
    static let loudSoftShare = 0.5
    static let loudEnergy = 0.6

    /// The family of a song from its genre tags (best fitting first), its trusted tempo and its mean energy (0 to 1). Without a
    /// usable tag, the family its tempo and energy suggest, marked as a guess.
    static func classify(tags: [String], bpm: Double?, energy: Double?) -> MusicGenre {
        let bpm = bpm.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let energy = energy.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let suggested = suggestion(bpm: bpm, energy: energy)
        var votes: [MusicGenreFamily: Double] = [:]
        var order: [MusicGenreFamily] = []
        var weight = 1.0
        for tag in tags {
            guard let (family, vote) = vote(tag, bpm: bpm, energy: energy), family != .open else { continue }
            if votes[family] == nil { order.append(family) }
            votes[family, default: 0] += vote * weight
            weight *= voteDecay
        }
        guard !order.isEmpty else { return MusicGenre(family: suggested, isGuess: true) }
        func total(_ family: MusicGenreFamily) -> Double {
            var sum = votes[family] ?? 0
            if let bpm, !family.holds(bpm: bpm) { sum *= wrongTempoShare }
            if family == .soft, let energy, energy >= loudEnergy { sum *= loudSoftShare }
            return sum + (family == suggested ? 1 : 0)
        }
        var best = order[0]
        for family in order.dropFirst() where total(family) > total(best) + 1e-9 { best = family }
        return MusicGenre(family: best, isGuess: false)
    }

    /// The family a song's tempo and energy suggest. `bpm` is nil when the beat is not trusted: then nothing is suggested.
    static func suggestion(bpm: Double?, energy: Double?) -> MusicGenreFamily {
        guard let bpm else { return .open }
        switch bpm {
        case ..<60: return .open
        case ..<100: return (energy ?? 1) >= 0.4 ? .hipHop : .soft
        case ..<116: return .pop
        case ..<136: return (energy ?? 1) >= 0.45 ? .house : .soft
        case ..<160: return .pop
        case ...186: return (energy ?? 0) >= 0.7 ? .dnb : .hipHop
        default: return .open
        }
    }

    /// What one tag says: a family and how strongly, or nil when it says nothing about mixing.
    static func vote(_ tag: String, bpm: Double?, energy: Double?) -> (family: MusicGenreFamily, vote: Double)? {
        let name = normalized(tag)
        guard !name.isEmpty else { return nil }
        if name == "techno house" { return ((bpm ?? 0) >= 136 ? .techno : .house, exactVote) }
        if let family = exact[name] { return (family, exactVote) }
        if dance.contains(name) { return (danceFamily(bpm: bpm, energy: energy), broadVote) }
        // "melodic dubstep", "indie folk", "latin trap": the kind of music is the last word of the name, so the longest ending wins.
        let words = name.split(separator: " ")
        for start in words.indices.dropFirst() {
            let ending = words[start...].joined(separator: " ")
            if let family = exact[ending] { return (family, exactVote) }
            if dance.contains(ending) { return (danceFamily(bpm: bpm, energy: energy), broadVote) }
        }
        return nil
    }

    /// Lower case, "&" and every separator a space, so "Drum & Bass", "drum-and-bass" and "Drum'n'bass" compare alike.
    static func normalized(_ tag: String) -> String {
        var text = tag.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        for joiner in ["'n'", " n ", "&", "+", " and "] { text = text.replacingOccurrences(of: joiner, with: " ") }
        let words = text.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(words).split(separator: " ").filter { $0 != "and" }.joined(separator: " ")
    }

    /// A tag as wide as "electronic" or "dance" is the kind its tempo has.
    private static func danceFamily(bpm: Double?, energy: Double?) -> MusicGenreFamily {
        guard let bpm else { return .house }
        switch bpm {
        case 110..<136: return .house
        case 136..<156: return .bass
        case 160...186: return (energy ?? 0) >= 0.6 ? .dnb : .bass
        case 80..<93: return (energy ?? 0) >= 0.6 ? .dnb : .pop
        default: return .pop
        }
    }

    /// Names of the whole field of dance music, normalized.
    private static let dance: Set<String> = [
        "dance", "electronic", "electronica", "electro", "edm", "club", "club dance", "dance electronic", "electronic dance music",
        "dance music", "electronic music",
    ]

    /// The family of every genre name.
    private static let exact: [String: MusicGenreFamily] = {
        var out: [String: MusicGenreFamily] = [:]
        for family in MusicGenreFamily.allCases {
            for name in names[family] ?? [] { out[name] = family }
        }
        return out
    }()

    /// Genre names, normalized, each under one family only.
    static let names: [MusicGenreFamily: [String]] = [
        .house: [
            "house", "deep house", "progressive house", "tech house", "tropical house", "french house", "melodic house",
            "bass house", "slap house", "future house", "funky house", "acid house", "electro swing", "disco", "nu disco",
            "italo disco", "post disco", "hi nrg", "euro house", "eurodance", "hip house", "piano house", "organic house",
            "stutter house", "dance pop house", "g house",
        ],
        .techno: [
            "techno", "minimal", "minimal techno", "melodic techno", "hard techno", "industrial techno", "acid techno",
            "detroit techno", "dub techno", "peak time techno", "ebm", "electroclash",
        ],
        .trance: [
            "trance", "psytrance", "psy trance", "progressive trance", "uplifting trance", "goa trance", "vocal trance", "goa",
        ],
        .dnb: [
            "drum bass", "dnb", "d b", "jungle", "liquid funk", "liquid drum bass", "neurofunk", "jump up", "drumfunk",
            "breakcore", "darkstep", "drumstep",
        ],
        .bass: [
            "dubstep", "brostep", "riddim", "riddim dubstep", "future bass", "big room", "big room house", "electro house",
            "complextro", "hardstyle", "hardcore techno", "happy hardcore", "gabber", "edm trap", "festival trap", "trap edm",
            "midtempo bass", "color bass", "moombahton", "jersey club", "bass music", "glitch hop", "dariacore", "hyperpop",
            "dubstep brostep", "melbourne bounce", "hard dance", "breakbeat", "big beat",
        ],
        .garage: ["uk garage", "garage house", "2 step", "2 step garage", "speed garage", "bassline", "future garage", "ukg"],
        .hipHop: [
            "hip hop", "rap", "rap hip hop", "hip hop rap", "trap", "drill", "grime", "phonk", "gangsta rap", "boom bap",
            "cloud rap", "emo rap", "pop rap", "conscious hip hop", "west coast hip hop", "east coast hip hop", "southern hip hop",
            "alternative hip hop", "trap rap", "rage", "plugg", "crunk", "hyphy", "g funk", "bounce", "horrorcore", "mumble rap",
            "chicago drill", "uk drill", "r b", "rnb", "r b soul", "contemporary r b", "alternative r b", "trap soul", "neo soul",
            "soul", "funk", "new jack swing", "rhythm blues", "quiet storm", "soul funk", "hip hop soul",
        ],
        .latin: [
            "latin", "latin music", "reggaeton", "reggaeton latin", "dembow", "salsa", "bachata", "cumbia", "merengue", "latin pop",
            "latin trap", "latin urban", "urbano latino", "musica urbana", "samba", "baile funk", "funk carioca", "funk brasileiro",
            "brazilian funk", "tropical", "corridos tumbados", "regional mexican", "brazilian music", "sertanejo",
        ],
        .afro: [
            "afrobeats", "afrobeat", "afro pop", "afropop", "afro house", "amapiano", "dancehall", "reggae", "afro", "african music",
            "alte", "soca", "gqom", "afroswing", "afro swing", "afro fusion", "dub", "ska", "reggae fusion", "roots reggae",
        ],
        .pop: [
            "pop", "dance pop", "synth pop", "synthpop", "electropop", "indie pop", "art pop", "k pop", "j pop", "teen pop",
            "bedroom pop", "europop", "power pop", "bubblegum pop", "alt pop", "dream pop", "pop soul", "chamber pop", "new wave",
            "synthwave", "city pop", "asian music", "international pop", "films games", "film score", "mandopop", "c pop",
            "adult contemporary", "bubblegum", "boy band", "girl group", "pop dance",
        ],
        .rock: [
            "rock", "pop rock", "indie rock", "alternative rock", "alternative", "indie", "hard rock", "metal", "heavy metal", "punk",
            "pop punk", "punk rock", "grunge", "emo", "post punk", "classic rock", "nu metal", "metalcore", "shoegaze", "garage rock",
            "psychedelic rock", "soft rock", "progressive rock", "blues rock", "electronic rock", "arena rock", "folk rock",
            "alternative indie", "rock roll", "hardcore punk", "post hardcore", "industrial rock", "indie alternative", "glam rock",
        ],
        .soft: [
            "ballad", "folk", "acoustic", "singer songwriter", "country", "country pop", "jazz", "classical", "ambient", "lo fi",
            "lofi", "lo fi hip hop", "lofi hip hop", "chillhop", "chillout", "downtempo", "trip hop", "easy listening", "new age",
            "blues", "indie folk", "bluegrass", "americana", "soundtrack", "instrumental", "piano", "opera", "gospel", "christmas",
            "children s music", "kids", "bossa nova", "smooth jazz", "slowcore", "meditation", "sad", "contemporary folk",
            "spoken word", "lounge", "holiday",
        ],
    ]
}
