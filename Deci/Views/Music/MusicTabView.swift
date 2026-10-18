// Deci/Views/Music/MusicTabView.swift
import SwiftUI

/// The Music tab body. Fixed height so the popup does not jump as results come and go.
struct MusicTabView: View {
    let host: MusicServiceHost
    let height: CGFloat

    var body: some View {
        Group {
            if let service = host.service {
                MusicServiceView(service: service)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: height)
    }
}

private struct MusicServiceView: View {
    @Bindable var service: MusicService

    var body: some View {
        switch service.authState {
        case .unknown:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
            signedOutView
        case .signingIn:
            VStack(spacing: DesignTokens.Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Finish signing in in the YouTube Music window.")
                    .font(DesignTokens.Typography.rowDescription)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedIn:
            MusicSignedInView(service: service)
        }
    }

    private var signedOutView: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "music.note.list")
                .font(.system(size: 26))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
            Text("Sign in to search and play from your YouTube Music account.")
                .font(DesignTokens.Typography.rowDescription)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .multilineTextAlignment(.center)
            Button("Sign in to YouTube Music") {
                service.signIn()
            }
            .buttonStyle(.plain)
            .font(DesignTokens.Typography.pickerText)
            .foregroundStyle(DesignTokens.Colors.textPrimary)
            .glassButtonStyle()
            if let message = service.lastError {
                Text(message)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MusicSignedInView: View {
    @Bindable var service: MusicService
    @FocusState private var searchFocused: Bool
    /// The Up next button forces the queue even while a search is on screen.
    @State private var queueForced = false

    private var searchIsEmpty: Bool {
        service.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The queue shows when there is one and the search field is empty, or when asked for.
    private var showsQueue: Bool {
        !service.queue.isEmpty && (queueForced || searchIsEmpty)
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            searchRow

            if let message = service.lastError {
                Text(message)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if showsQueue {
                queueList
            } else {
                resultsList
            }

            MusicMiniTransport(service: service)
        }
        .task { searchFocused = true }
        .onChange(of: service.query) { queueForced = false }
    }

    private var searchRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                TextField("Search songs and artists", text: $service.query)
                    .textFieldStyle(.plain)
                    .font(DesignTokens.Typography.rowName)
                    .focused($searchFocused)
                    .onSubmit {
                        queueForced = false
                        service.search()
                    }
                if service.isSearching {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                    .fill(DesignTokens.Colors.glassFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                            .strokeBorder(DesignTokens.Colors.glassRowBorder, lineWidth: 0.5)
                    )
            )

            if !service.queue.isEmpty {
                Button("Up next", systemImage: "list.bullet") {
                    queueForced.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(showsQueue ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textTertiary)
                .accessibilityAddTraits(showsQueue ? .isSelected : [])
            }

            Button("Sign out") {
                service.signOut()
            }
            .buttonStyle(.plain)
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textTertiary)
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        if service.results.isEmpty {
            Text(service.isSearching ? "Searching..." : "Type a song or artist and press Return.")
                .font(DesignTokens.Typography.rowDescription)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(service.results) { track in
                        MusicResultRow(
                            track: track,
                            isCurrent: service.player.nowPlaying?.videoId == track.videoId
                        ) {
                            service.play(track)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private var queueList: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            Text("Up next")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(service.queue.fromCurrent) { track in
                        MusicResultRow(
                            track: track,
                            isCurrent: service.queue.current?.videoId == track.videoId
                        ) {
                            service.jump(to: track)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

private struct MusicResultRow: View {
    let track: MusicTrack
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                MusicThumbnail(url: track.thumbnailURL, size: 40)

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(DesignTokens.Typography.rowName)
                        .foregroundStyle(isCurrent ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textPrimary)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(DesignTokens.Typography.rowDescription)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: DesignTokens.Spacing.sm)

                if let seconds = track.durationSeconds {
                    Text(MusicTimeFormat.string(TimeInterval(seconds)))
                        .font(DesignTokens.Typography.percentage)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
            }
            .hoverableRow(isFocused: isCurrent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(track.title), \(track.artist)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
