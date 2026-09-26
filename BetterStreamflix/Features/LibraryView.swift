import SwiftUI
import UIKit

struct LibraryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watchlistToast: WatchlistToastStore
    @State private var selectedDetails: ResolvedMediaItem?
    @State private var playback: PlaybackRequest?
    @State private var segment: LibrarySegment = .continueWatching
    @State private var sortNewestFirst = true
    @State private var newListName = ""
    @State private var showCreateList = false
    /// When pushed from More, use the system navigation chrome instead of the large page title.
    var showsInlineTitle: Bool = false

    private enum LibrarySegment: String, CaseIterable, Identifiable {
        case continueWatching = "Continue"
        case watchlist = "Watchlist"
        case lists = "Lists"
        case watched = "Watched"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .continueWatching: "Continue Watching"
            case .watchlist: "Watchlist"
            case .lists: "Lists"
            case .watched: "Watched"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsInlineTitle {
                Color.clear.frame(height: 0)
            } else {
                PageTitleHeader(title: "Library", ignoresTopSafeArea: true)
            }

            Picker("Library", selection: $segment) {
                ForEach(LibrarySegment.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            HStack {
                Text(segment.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText.opacity(0.7))
                Spacer()
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    sortNewestFirst.toggle()
                } label: {
                    Label(
                        sortNewestFirst ? "Newest" : "Oldest",
                        systemImage: "arrow.up.arrow.down"
                    )
                    .font(.caption.weight(.semibold))
                }
                .tint(environment.theme.accentBright)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            Group {
                switch segment {
                case .continueWatching:
                    continueWatchingContent
                case .watchlist:
                    watchlistContent
                case .lists:
                    listsContent
                case .watched:
                    watchedContent
                }
            }
        }
        .background { AppScreenBackground() }
        .modifier(LibraryChromeModifier(showsInlineTitle: showsInlineTitle))
        .navigationDestination(item: $selectedDetails) { item in
            DetailsView(item: item.media, tmdbMetadata: item.tmdbMetadata)
        }
        .fullScreenCover(item: $playback) { request in
            PlayerScreen(request: request, nextRequest: nil)
        }
        .alert("New list", isPresented: $showCreateList) {
            TextField("Name", text: $newListName)
            Button("Create") {
                let created = library.createCustomList(named: newListName)
                newListName = ""
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                _ = created
            }
            Button("Cancel", role: .cancel) { newListName = "" }
        } message: {
            Text("Local lists stay on this device — no Trakt sync.")
        }
    }

    @ViewBuilder
    private var continueWatchingContent: some View {
        let items = sortedProgress(library.continueWatching)
        if items.isEmpty {
            LibraryEmptyState(
                title: "Nothing to resume",
                message: "Titles you start watching appear here with progress and quick resume.",
                systemImage: "play.circle"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { value in
                        ContinueWatchingRow(
                            progress: value,
                            onDetails: { openDetails($0) },
                            onResume: { resume($0) },
                            onMarkAsWatched: { markWatched($0) },
                            onRemoveFromContinueWatching: { remove($0) }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .padding(.bottom, 28)
            }
        }
    }

    @ViewBuilder
    private var watchlistContent: some View {
        let items = sortNewestFirst ? library.watchlist : library.watchlist.reversed()
        if items.isEmpty {
            LibraryEmptyState(
                title: "Your list is empty",
                message: "Save movies and series from any title screen to build your watchlist.",
                systemImage: "bookmark"
            )
        } else {
            ScrollView {
                LazyVGrid(
                    columns: MediaArtworkLayout.gridColumns,
                    spacing: MediaArtworkLayout.gridSpacing
                ) {
                    ForEach(items) { item in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            openDetails(item)
                        } label: {
                            PosterGridCard(
                                item: item,
                                progress: library.latestProgress(for: item)?.fraction,
                                progressDetail: library.latestProgress(for: item)?.shelfProgressLabel
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                resume(WatchProgressProxy.resumeRequest(for: item, library: library))
                            } label: {
                                Label("Play", systemImage: "play.fill")
                            }
                            MediaTitlePosterActions(item: item) {
                                openDetails(item)
                            }
                            Button(role: .destructive) {
                                WatchlistFeedback.toggle(
                                    item,
                                    in: library,
                                    toastStore: watchlistToast
                                )
                            } label: {
                                DestructiveTrashLabel(title: "Remove from Watchlist")
                            }
                        }
                    }
                }
                .padding(.horizontal, MediaArtworkLayout.gridHorizontalPadding)
                .padding(.bottom, 28)
            }
        }
    }

    @ViewBuilder
    private var listsContent: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    showCreateList = true
                } label: {
                    Label("New list", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .tint(environment.theme.accentBright)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            if library.customLists.isEmpty {
                LibraryEmptyState(
                    title: "No custom lists",
                    message: "Create lists from here or add titles from any detail screen.",
                    systemImage: "list.bullet.rectangle"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(library.customLists) { list in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(list.name)
                                        .font(DesignTokens.Typography.shelfTitle)
                                    Spacer()
                                    Text("\(list.items.count)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Button(role: .destructive) {
                                        library.deleteCustomList(id: list.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 20)

                                if list.items.isEmpty {
                                    Text("Empty — add titles from Details → Add to list")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 20)
                                } else {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        LazyHStack(spacing: 12) {
                                            ForEach(list.items) { item in
                                                Button {
                                                    openDetails(item)
                                                } label: {
                                                    PosterGridCard(item: item)
                                                }
                                                .buttonStyle(.plain)
                                                .frame(width: 110)
                                                .contextMenu {
                                                    Button(role: .destructive) {
                                                        library.toggleCustomList(item, listID: list.id)
                                                    } label: {
                                                        Label("Remove from list", systemImage: "trash")
                                                    }
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 20)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 28)
                }
            }
        }
    }

    @ViewBuilder
    private var watchedContent: some View {
        let items = sortedProgress(library.progress.filter { $0.fraction >= 0.9 })
        if items.isEmpty {
            LibraryEmptyState(
                title: "No watched titles yet",
                message: "Finished movies and episodes will show up in this history.",
                systemImage: "checkmark.circle"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { value in
                        ContinueWatchingRow(
                            progress: value,
                            onDetails: { openDetails($0) },
                            onResume: { resume($0) },
                            onMarkAsWatched: { markWatched($0) },
                            onRemoveFromContinueWatching: { remove($0) }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .padding(.bottom, 28)
            }
        }
    }

    private func sortedProgress(_ values: [WatchProgress]) -> [WatchProgress] {
        values.sorted {
            sortNewestFirst ? $0.updatedAt > $1.updatedAt : $0.updatedAt < $1.updatedAt
        }
    }

    private func openDetails(_ item: MediaItem) {
        selectedDetails = ResolvedMediaItem(media: item, tmdbMetadata: nil)
    }

    private func resume(_ value: WatchProgress) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        playback = PlaybackRequest(media: value.media, episode: value.episode)
    }

    private func resume(_ request: PlaybackRequest) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        playback = request
    }

    private func markWatched(_ value: WatchProgress) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        library.markWatched(request: PlaybackRequest(media: value.media, episode: value.episode))
    }

    private func remove(_ value: WatchProgress) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        library.removeProgress(value)
    }
}

private enum WatchProgressProxy {
    @MainActor
    static func resumeRequest(for item: MediaItem, library: LibraryStore) -> PlaybackRequest {
        if let progress = library.latestProgress(for: item) {
            return PlaybackRequest(media: progress.media, episode: progress.episode)
        }
        return PlaybackRequest(media: item, episode: nil)
    }
}

struct LibraryEmptyState: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Spacer(minLength: 56)
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(AppTheme.primaryText.opacity(0.55))
                .frame(width: 84, height: 84)
                .glassEffectWithFallback(in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct LibraryChromeModifier: ViewModifier {
    let showsInlineTitle: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if showsInlineTitle {
            content
                .navigationTitle("Library")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                .toolbar(.visible, for: .tabBar)
        } else {
            content
                .ignoresSafeArea(edges: .top)
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(.visible, for: .tabBar)
        }
    }
}
