// Deci/Music/MusicPageListing.swift

/// Which of a page's songs its list shows now. The rows of a filtered list and the list a selection ranges over come
/// from one answer, worked out once per body, so the filter does not run over the page twice.
@MainActor
enum MusicPageListing {
    /// The positions in `tracks` the field's words leave; nil when the list is not filtered. An artist's top songs are
    /// never filtered, and a list whose order waits for the rest of its songs shows none yet.
    static func matches(in tracks: [MusicTrack], terms: [String], isArtist: Bool, orderPending: Bool) -> [Int]? {
        guard !isArtist, !orderPending, !terms.isEmpty else { return nil }
        return MusicLocalSearch.indices(of: tracks, terms: terms)
    }

    /// The page's own song rows as they show now, in order: an artist's top songs, the songs the filter leaves, or every
    /// song loaded; none while the order waits for the rest of them. A shelf's songs are a list of their own.
    static func listedTracks(
        _ tracks: [MusicTrack], matches: [Int]?, isArtist: Bool, orderPending: Bool
    ) -> [MusicTrack] {
        if isArtist { return tracks }
        if orderPending { return [] }
        guard let matches else { return tracks }
        return matches.map { tracks[$0] }
    }
}
