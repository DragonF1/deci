// Deci/Music/MusicLikeStore.swift
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.abraham.Deci", category: "MusicLikes")

/// What Like, Dislike and the save shortcut came to, as the shortcut HUD words it.
nonisolated enum MusicActionOutcome: CaseIterable, Equatable, Sendable {
    case liked
    case likeRemoved
    case disliked
    case dislikeRemoved
    /// No song is playing.
    case nothingPlaying
    /// The user is not signed in to YouTube Music, or the call found the session gone.
    case signedOut
    /// YouTube Music could not be reached, or did not take the rating.
    case failed
    /// The Music item is hidden from the menu bar, so the popup that would show the result cannot open.
    case musicHidden
    /// Nothing to report: a tap folded into the rating still out for the song (that one reports for both), or the save
    /// menu opening.
    case quiet
}

/// The like state of the songs played this session: Like, Dislike or neither, as YouTube Music has it. `MusicService`
/// owns one (`service.likes`). A song's state is read once, when it starts, and kept for the session, so coming back to
/// a song needs no new read. Like and Dislike show their result at once and go back to what the song was if YouTube
/// Music does not take the call. A tap on a song whose rating is still out shows at once and is sent when that call is
/// back, so the latest tap is what the song ends as. Nothing here logs a song, only error kinds.
@MainActor
@Observable
final class MusicLikeStore {
    /// The states known so far, by video id. A song missing here is unknown, not unliked.
    private(set) var statuses: [String: MusicLikeStatus] = [:]

    @ObservationIgnored private let backend: any MusicBackend
    /// Bumped by `reset`: a call that was out when the session ended must not touch the next one.
    @ObservationIgnored private var sessionRun = 0
    /// Songs whose state was asked for this session, so an empty read is not repeated on every player change. A read that
    /// failed, or a rating that failed on a song with no known state, takes the song out again so it is read once more.
    @ObservationIgnored private var asked: Set<String> = []
    /// The reads out now, so a Like that needs a song's state can wait for it.
    @ObservationIgnored private var reads: [String: Task<Void, Never>] = [:]
    /// Songs a rating is out for, so a second tap on the same song is not sent beside the first.
    @ObservationIgnored private var rating: Set<String> = []
    /// For a song a rating is out for, what the latest tap made meanwhile wants it to be. It is sent when that call is back.
    @ObservationIgnored private var wanted: [String: MusicLikeStatus] = [:]
    /// Told when a call says the session is gone, so the service can sign out.
    @ObservationIgnored var onSessionExpired: (@MainActor () -> Void)?

    init(backend: any MusicBackend) {
        self.backend = backend
    }

    /// The state of a song; nil while it is unknown.
    func status(of videoId: String) -> MusicLikeStatus? {
        statuses[videoId]
    }

    // MARK: - Reading

    /// Reads a song's state, unless it was asked for already this session.
    func load(videoId: String) {
        guard !videoId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, asked.insert(videoId).inserted else { return }
        let session = sessionRun
        reads[videoId] = Task { [weak self, backend] in
            do {
                let status = try await backend.likeStatus(videoId: videoId)
                self?.landRead(status, videoId: videoId, session: session)
            } catch {
                self?.failRead(error, videoId: videoId, session: session)
            }
            self?.endRead(videoId: videoId, session: session)
        }
    }

    private func endRead(videoId: String, session: Int) {
        guard sessionRun == session else { return }
        reads[videoId] = nil
    }

    private func landRead(_ status: MusicLikeStatus?, videoId: String, session: Int) {
        guard sessionRun == session, let status else { return }
        // A rating made while the read was out is newer than the read.
        guard statuses[videoId] == nil, !rating.contains(videoId) else { return }
        statuses[videoId] = status
    }

    private func failRead(_ error: any Error, videoId: String, session: Int) {
        guard sessionRun == session else { return }
        logger.error("like status read failed: \(MusicService.logDescription(of: error), privacy: .public)")
        // A failed read is made again the next time the song is loaded; a gone session is not, it ends the store's use.
        if !expireIfSignedOut(error) { asked.remove(videoId) }
    }

    /// Waits for a song's state when it is not known, so Like can tell a liked song from one that is not. A song whose
    /// read already came back empty is not read again.
    private func readIfUnknown(_ videoId: String) async {
        guard statuses[videoId] == nil else { return }
        load(videoId: videoId)
        await reads[videoId]?.value
    }

    // MARK: - Rating

    /// Likes a song, or takes its like back when it is liked. A disliked song becomes liked. A song whose state is not
    /// known yet is read first, so Like on a song that is already liked does not like it twice.
    func toggleLike(videoId: String) async -> MusicActionOutcome {
        let session = sessionRun
        await readIfUnknown(videoId)
        guard sessionRun == session else { return .quiet }
        let target: MusicLikeStatus = statuses[videoId] == .like ? .indifferent : .like
        return await rate(videoId: videoId, to: target)
    }

    /// Dislikes a song, or takes its dislike back when it is disliked. `onSent` runs once when a dislike (not the
    /// removal of one) is on its way, right after the state shows it and before YouTube Music answers: the service
    /// skips the song there. It does not wait for the song's state to be read, so the skip stays instant.
    func dislike(videoId: String, onSent: (@MainActor () -> Void)? = nil) async -> MusicActionOutcome {
        let target: MusicLikeStatus = statuses[videoId] == .dislike ? .indifferent : .dislike
        return await rate(videoId: videoId, to: target, onSent: target == .dislike ? onSent : nil)
    }

    /// Sends `target` for a song. When a call is already out for it, the tap shows at once, is remembered as what the song
    /// should end as, and returns `.quiet`: the call that is out sends it when it is back and reports for both. A failed
    /// call goes back to what YouTube Music last had; a tap made meanwhile is still sent, unless the session is gone.
    private func rate(
        videoId: String,
        to target: MusicLikeStatus,
        onSent: (@MainActor () -> Void)? = nil
    ) async -> MusicActionOutcome {
        guard rating.insert(videoId).inserted else {
            wanted[videoId] = target
            statuses[videoId] = target
            onSent?()
            return .quiet
        }
        let session = sessionRun
        var confirmed = statuses[videoId]
        var target = target
        var onSent = onSent
        var outcome = MusicActionOutcome.quiet
        while true {
            statuses[videoId] = target
            onSent?()
            onSent = nil
            do {
                try await backend.rate(videoId: videoId, status: target)
                guard sessionRun == session else { return .quiet }
                outcome = Self.outcome(of: target, after: confirmed)
                confirmed = target
            } catch {
                guard sessionRun == session else { return .quiet }
                logger.error("rating failed: \(MusicService.logDescription(of: error), privacy: .public)")
                statuses[videoId] = confirmed
                // A song still unknown is read again the next time it is loaded.
                if confirmed == nil { asked.remove(videoId) }
                if expireIfSignedOut(error) {
                    wanted[videoId] = nil
                    rating.remove(videoId)
                    return .signedOut
                }
                outcome = .failed
            }
            guard let next = wanted.removeValue(forKey: videoId), next != confirmed else { break }
            target = next
        }
        rating.remove(videoId)
        return outcome
    }

    private static func outcome(of target: MusicLikeStatus, after previous: MusicLikeStatus?) -> MusicActionOutcome {
        switch target {
        case .like: .liked
        case .dislike: .disliked
        case .indifferent: previous == .dislike ? .dislikeRemoved : .likeRemoved
        }
    }

    /// Tells the service when the session is gone; says whether it was.
    @discardableResult
    private func expireIfSignedOut(_ error: any Error) -> Bool {
        guard (error as? MusicError) == .signedOut else { return false }
        onSessionExpired?()
        return true
    }

    // MARK: - Reset

    /// Drops everything: on sign-out and after an account or channel switch. A call still out lands nowhere.
    func reset() {
        sessionRun += 1
        statuses.removeAll()
        asked.removeAll()
        reads.removeAll()
        rating.removeAll()
        wanted.removeAll()
    }
}
