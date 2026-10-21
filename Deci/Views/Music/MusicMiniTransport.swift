// Deci/Views/Music/MusicMiniTransport.swift
import SwiftUI

enum MusicTimeFormat {
    /// "m:ss", or "h:mm:ss" from one hour up. Negative and non-finite values read as zero.
    static func string(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours):" + String(format: "%02d:%02d", minutes, secs)
        }
        return "\(minutes):" + String(format: "%02d", secs)
    }

    /// Fraction of the track played, clamped to 0...1; 0 while the duration is unknown.
    static func progress(current: TimeInterval, duration: TimeInterval) -> Double {
        guard current.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(current / duration, 0), 1)
    }

    /// Where a touch at `x` points along a bar `width` wide, clamped to 0...1.
    static func fraction(x: CGFloat, width: CGFloat) -> Double {
        guard x.isFinite, width.isFinite, width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1))
    }

    /// Time left as "-m:ss"; "-0:00" while the duration is unknown or already passed.
    static func remaining(current: TimeInterval, duration: TimeInterval) -> String {
        guard current.isFinite, duration.isFinite, duration > current else { return "-0:00" }
        return "-" + string(duration - current)
    }
}

/// A song's view count the way YouTube writes it: "999", "1.2K", "354K", "1.2M", "1.9B". A count is cut, never rounded
/// up, so it never reads higher than it is.
enum MusicViewCountFormat {
    /// The units from the largest down, each with the count it starts at.
    private static let units: [(size: Int, suffix: String)] = [
        (1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K"),
    ]

    /// Exact under 1,000. From there one decimal while the unit count is under 10 ("1.2K", a ".0" dropped), then whole
    /// units ("354K"). Nil for a negative count.
    static func abbreviated(_ count: Int) -> String? {
        guard count >= 0 else { return nil }
        guard let unit = units.first(where: { count >= $0.size }) else { return String(count) }
        let whole = count / unit.size
        let tenths = (count % unit.size) / (unit.size / 10)
        if whole >= 10 || tenths == 0 { return "\(whole)\(unit.suffix)" }
        return "\(whole).\(tenths)\(unit.suffix)"
    }

    /// "1.2M views", or "1 view" for exactly one. Nil while the count is unknown or negative.
    static func label(_ count: Int?) -> String? {
        guard let count, let short = abbreviated(count) else { return nil }
        return "\(short) \(noun(count))"
    }

    /// Every digit, grouped by thousands: "1,234,567 views". For a tooltip. Nil while the count is unknown or negative.
    static func fullLabel(_ count: Int?) -> String? {
        guard let count, count >= 0 else { return nil }
        let digits = count.formatted(.number.locale(Locale(identifier: "en_US")))
        return "\(digits) \(noun(count))"
    }

    /// "view" for exactly one, "views" for every other count.
    private static func noun(_ count: Int) -> String {
        count == 1 ? "view" : "views"
    }
}

/// Small square cover art with a neutral placeholder while it loads or when a track has none.
/// Artists get a round one.
struct MusicThumbnail: View {
    let url: URL?
    let size: CGFloat
    var circular = false
    var placeholder = "music.note"
    /// The corner radius of a square cover; the button radius when nil.
    var cornerRadius: CGFloat?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                MusicCoverPlaceholder(symbol: placeholder, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(MusicCoverShape(circular: circular, radius: cornerRadius))
    }
}

/// A small pushpin on a dark dot, for the top-right corner of a pinned song, playlist, album or artist cover. It
/// scales with the cover. A round cover is inset further, so the dot sits on the edge of the circle and not in the
/// empty corner of its square.
struct MusicPinBadge: View {
    let coverSize: CGFloat
    var circular = false
    /// A size and an inset the design fixes for a cover (18 on a tile, 20 on a Top Picks card); the rule below
    /// when nil.
    var diameterOverride: CGFloat?
    var insetOverride: CGFloat?

    /// The dot is about a fifth of the cover, never under `minDiameter`: 18 on a 96 tile, 14 on a row.
    static let minDiameter: CGFloat = 14

    static func diameter(coverSize: CGFloat) -> CGFloat {
        max(minDiameter, (coverSize * 0.1875).rounded())
    }

    /// The gap from the cover's top and right edges.
    static func inset(coverSize: CGFloat, circular: Bool) -> CGFloat {
        circular ? max(4, coverSize * 0.1) : 4
    }

    var body: some View {
        let diameter = diameterOverride ?? Self.diameter(coverSize: coverSize)
        let inset = insetOverride ?? Self.inset(coverSize: coverSize, circular: circular)
        Image(systemName: "pin.fill")
            .font(.system(size: diameter * 0.55, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(Color.black.opacity(0.6)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
            .padding(.top, inset)
            .padding(.trailing, inset)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Puts the pin badge on this cover's top-right corner while `isPinned`. Apply it after the playing overlay, so
    /// the badge stays on top while the song plays.
    func musicPinBadge(
        _ isPinned: Bool,
        coverSize: CGFloat,
        circular: Bool = false,
        diameter: CGFloat? = nil,
        inset: CGFloat? = nil
    ) -> some View {
        overlay(alignment: .topTrailing) {
            if isPinned {
                MusicPinBadge(coverSize: coverSize, circular: circular, diameterOverride: diameter, insetOverride: inset)
            }
        }
    }
}

/// What stands in for a cover or a photo that is still loading, failed, or does not exist.
struct MusicCoverPlaceholder: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        ZStack {
            DesignTokens.Colors.glassFillStrong
            Image(systemName: symbol)
                .font(.system(size: size * 0.4))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        }
    }
}

/// The cover clip: the button radius, or a circle for artists.
struct MusicCoverShape: Shape {
    let circular: Bool
    /// The corner radius of a square cover; the button radius when nil.
    var radius: CGFloat?

    func path(in rect: CGRect) -> Path {
        circular
            ? Circle().path(in: rect)
            : RoundedRectangle(cornerRadius: radius ?? DesignTokens.Dimensions.buttonRadius, style: .continuous).path(in: rect)
    }
}

extension MusicLoopMode {
    /// What the loop button says it is doing; also its accessibility label.
    var label: String {
        switch self {
        case .off: "Loop off"
        case .playlist: "Loop playlist"
        case .song: "Loop song"
        }
    }

    var systemImage: String {
        switch self {
        case .off, .playlist: "repeat"
        case .song: "repeat.1"
        }
    }
}

extension MusicCollection.Kind {
    /// Placeholder symbol while the cover loads or when there is none.
    var placeholderSymbol: String {
        switch self {
        case .playlist: "music.note.list"
        case .album: "opticaldisc"
        case .artist: "person.fill"
        }
    }
}
