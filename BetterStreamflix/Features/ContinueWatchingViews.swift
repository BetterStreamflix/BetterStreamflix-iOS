import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContinueWatchingShelfView: View {
    @Environment(\.titleTransitionSelection) private var transitionSelection
    let progress: [WatchProgress]
    let onDetails: (MediaItem) -> Void
    let onResume: (WatchProgress) -> Void
    let onMarkAsWatched: (WatchProgress) -> Void
    let onRemoveFromContinueWatching: (WatchProgress) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Continue Watching")
                    .font(DesignTokens.Typography.shelfTitle)
                Spacer()
                NavigationLink {
                    ContinueWatchingListView(
                        onResume: onResume,
                        onMarkAsWatched: onMarkAsWatched,
                        onRemoveFromContinueWatching: onRemoveFromContinueWatching
                    )
                } label: {
                    Text("Show All")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(progress) { value in
                        Button { onResume(value) } label: {
                            ContinueWatchingCard(progress: value)
                                .titleTransitionSource(
                                    id: value.media.artworkIdentityKey,
                                    sourceID: transitionSourceID(for: value)
                                )
                                .contextMenu {
                                    ContinueWatchingActions(
                                        progress: value,
                                        onDetails: { _ in showDetails(value) },
                                        onResume: onResume,
                                        onMarkAsWatched: onMarkAsWatched,
                                        onRemoveFromContinueWatching: onRemoveFromContinueWatching
                                    )
                                } preview: {
                                    ContinueWatchingMenuPreview(progress: value)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func transitionSourceID(for progress: WatchProgress) -> String {
        "\(progress.media.artworkIdentityKey):continue-watching-shelf:\(progress.id)"
    }

    private func showDetails(_ progress: WatchProgress) {
        transitionSelection?.select(
            titleID: progress.media.artworkIdentityKey,
            sourceID: transitionSourceID(for: progress)
        )
        onDetails(progress.media)
    }
}

struct ContinueWatchingListView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var selectedDetails: ResolvedMediaItem?
    let onResume: (WatchProgress) -> Void
    let onMarkAsWatched: (WatchProgress) -> Void
    let onRemoveFromContinueWatching: (WatchProgress) -> Void

    var body: some View {
        Group {
            if library.continueWatching.isEmpty {
                ContentUnavailableView(
                    "Nothing to Continue",
                    systemImage: "play.rectangle",
                    description: Text("Movies and episodes you start will appear here.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(library.continueWatching) { value in
                            ContinueWatchingRow(
                                progress: value,
                                onDetails: {
                                    selectedDetails = ResolvedMediaItem(
                                        media: $0,
                                        tmdbMetadata: nil
                                    )
                                },
                                onResume: onResume,
                                onMarkAsWatched: onMarkAsWatched,
                                onRemoveFromContinueWatching: onRemoveFromContinueWatching
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AppScreenBackground() }
        .navigationTitle("Continue Watching")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedDetails) {
            DetailsView(item: $0.media, tmdbMetadata: $0.tmdbMetadata)
        }
    }
}

struct ContinueWatchingRow: View {
    @Environment(\.titleTransitionSelection) private var transitionSelection
    @State private var transitionOccurrenceID = UUID().uuidString
    let progress: WatchProgress
    let onDetails: (MediaItem) -> Void
    let onResume: (WatchProgress) -> Void
    let onMarkAsWatched: (WatchProgress) -> Void
    let onRemoveFromContinueWatching: (WatchProgress) -> Void

    private var transitionSourceID: String {
        "\(progress.media.artworkIdentityKey):continue-watching-list:\(transitionOccurrenceID)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { onResume(progress) } label: {
                HStack(spacing: 14) {
                    ContinueWatchingRowArtwork(progress: progress)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(progress.media.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let episodeTitle = progress.episodeDisplayTitle {
                            Text(episodeTitle)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.78))
                                .lineLimit(1)
                        }
                        Text(progress.shelfProgressLabel)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.58))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .contextMenu {
                    ContinueWatchingActions(
                        progress: progress,
                        onDetails: { _ in showDetails() },
                        onResume: onResume,
                        onMarkAsWatched: onMarkAsWatched,
                        onRemoveFromContinueWatching: onRemoveFromContinueWatching
                    )
                } preview: {
                    ContinueWatchingMenuPreview(progress: progress)
                }
            }
            .buttonStyle(.plain)

            Menu {
                ContinueWatchingActions(
                    progress: progress,
                    onDetails: { _ in showDetails() },
                    onResume: onResume,
                    onMarkAsWatched: onMarkAsWatched,
                    onRemoveFromContinueWatching: onRemoveFromContinueWatching
                )
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Options for \(progress.media.title)")
        }
        .padding(12)
        .appSurface(cornerRadius: 16)
        .contentShape(Rectangle())
        .titleTransitionSource(
            id: progress.media.artworkIdentityKey,
            sourceID: transitionSourceID
        )
    }

    private func showDetails() {
        transitionSelection?.select(
            titleID: progress.media.artworkIdentityKey,
            sourceID: transitionSourceID
        )
        onDetails(progress.media)
    }
}

struct ContinueWatchingRowArtwork: View {
    @EnvironmentObject private var environment: AppEnvironment
    let progress: WatchProgress

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedRemoteImage(url: progress.continueWatchingArtworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle()
                    .fill(.gray.opacity(0.22))
                    .overlay {
                        Image(systemName: progress.media.kind == .movie ? "film" : "tv")
                    }
            }
            .frame(width: 128, height: 74)
            .clipped()

            ProgressView(value: progress.fraction)
                .tint(environment.theme.accent)
                .background(.white.opacity(0.28))
                .frame(maxWidth: .infinity)
        }
        .frame(width: 128, height: 74)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ContinueWatchingActions: View {
    let progress: WatchProgress
    let onDetails: (MediaItem) -> Void
    let onResume: (WatchProgress) -> Void
    let onMarkAsWatched: (WatchProgress) -> Void
    let onRemoveFromContinueWatching: (WatchProgress) -> Void

    var body: some View {
        Button { onDetails(progress.media) } label: {
            Label("Details", systemImage: "info.circle")
        }
        MediaTitleWatchlistAction(item: progress.media)
        Button { onResume(progress) } label: {
            Label(progress.isNextUp ? "Play Next" : "Resume", systemImage: "play.fill")
        }
        if progress.episode != nil {
            Button { onMarkAsWatched(progress) } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }
        }
        Button(role: .destructive) {
            onRemoveFromContinueWatching(progress)
        } label: {
            DestructiveTrashLabel(title: "Remove from Continue Watching")
        }
        .tint(.red)
    }
}

struct ContinueWatchingMenuPreview: View {
    let progress: WatchProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AsyncImage(url: progress.continueWatchingArtworkURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.gray.opacity(0.22))
                        .overlay {
                            if phase.error == nil {
                                ProgressView()
                            } else {
                                Image(systemName: progress.media.kind == .movie ? "film" : "tv")
                                    .font(.largeTitle)
                            }
                        }
                }
            }
            .frame(width: 300, height: 169)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(progress.media.title)
                .font(.headline)
                .lineLimit(1)
            if let episodeTitle = progress.episodeDisplayTitle {
                Text(episodeTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(progress.shelfProgressLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 328, alignment: .leading)
        .background(AppTheme.surface)
    }
}

struct ContinueWatchingCard: View {
    @EnvironmentObject private var environment: AppEnvironment
    let progress: WatchProgress
    private let width: CGFloat = 276
    private let imageHeight: CGFloat = 158

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottom) {
                CachedRemoteImage(url: progress.continueWatchingArtworkURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle()
                        .fill(.gray.opacity(0.22))
                        .overlay {
                            Image(systemName: progress.media.kind == .movie ? "film" : "tv")
                                .font(.title)
                        }
                }
                .frame(width: width, height: imageHeight)
                .clipped()

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.28),
                        .init(color: .black.opacity(0.35), location: 0.58),
                        .init(color: .black.opacity(0.92), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 3) {
                    Spacer()
                    HStack(alignment: .bottom, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(progress.media.title)
                                .font(.headline.bold())
                                .lineLimit(1)
                            if let episodeTitle = progress.episodeDisplayTitle {
                                Text(episodeTitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.78))
                                    .lineLimit(1)
                            }
                            Text(progress.shelfProgressLabel)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white.opacity(0.66))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        ZStack {
                            Circle()
                                .stroke(.white.opacity(0.22), lineWidth: 3)
                            Circle()
                                .trim(from: 0, to: progress.fraction)
                                .stroke(environment.theme.accentBright, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: "play.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 34, height: 34)
                        .accessibilityLabel("Resume")
                        .accessibilityValue("\(Int((progress.fraction * 100).rounded())) percent")
                    }
                    ProgressView(value: progress.fraction)
                        .tint(environment.theme.accent)
                        .background(.white.opacity(0.25))
                        .clipShape(Capsule())
                        .padding(.top, 5)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 9)

                if progress.isNextUp {
                    VStack {
                        HStack {
                            Spacer()
                            Text("Next Up")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
                        }
                        Spacer()
                    }
                    .padding(10)
                }
            }
            .frame(width: width, height: imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
            .shadow(color: environment.theme.glow.opacity(0.24), radius: 10, y: 4)
        }
        .frame(width: width, alignment: .leading)
        .foregroundStyle(.white)
        .contentShape(Rectangle())
    }
}

extension WatchProgress {
    var continueWatchingArtworkURL: URL? {
        episode?.posterURL ?? media.backdropURL ?? media.posterURL
    }

    var episodeDisplayTitle: String? {
        guard let episode else { return nil }
        let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : "Episode \(episode.number)"
    }
}
