import Foundation
import Observation

/// The songs being analysed right now (fetched and measured, not a fresh entry skipped), for the spinner on their rows.
/// Each coordinator run adds its own token and removes it when it ends, so two runs of one song never clear each other.
@MainActor
@Observable
final class MusicAnalysisActivity {
    static let shared = MusicAnalysisActivity()

    private var runs: [String: Set<UUID>] = [:]

    /// Called with a song's id when its last run ends, so a list that shows the song's row can read it.
    @ObservationIgnored var onFinished: ((String) -> Void)?

    func isAnalysing(_ videoId: String) -> Bool { runs[videoId] != nil }

    func begin(_ videoId: String, token: UUID) {
        runs[videoId, default: []].insert(token)
    }

    func end(_ videoId: String, token: UUID) {
        guard var tokens = runs[videoId], tokens.remove(token) != nil else { return }
        runs[videoId] = tokens.isEmpty ? nil : tokens
        if tokens.isEmpty { onFinished?(videoId) }
    }
}
