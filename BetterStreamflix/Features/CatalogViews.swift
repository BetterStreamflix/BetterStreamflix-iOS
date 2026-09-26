import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MediaShelfView: View {
    @Environment(\.titleTransitionSelection) private var transitionSelection
    let title: String
    let items: [MediaItem]
    var progress: [WatchProgress] = []
    var onDetails: ((MediaItem) -> Void)?
    var onResume: ((WatchProgress) -> Void)?
    var onRemoveFromContinueWatching: ((WatchProgress) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(DesignTokens.Typography.shelfTitle)
                Spacer()
                NavigationLink {
                    MediaGridView(
                        title: title,
                        items: items,
                        progress: progress,
                        onDetails: onDetails,
                        onResume: onResume,
                        onRemoveFromContinueWatching: onRemoveFromContinueWatching
                    )
                } label: {
                    Text("Show All")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { item in
                        let itemProgress = progress.first(where: {
                            $0.media.id == item.id && $0.providerID == item.providerID
                        })
                        Button { open(item) } label: {
                            PosterCard(
                                item: item,
                                progress: itemProgress?.fraction,
                                progressDetail: itemProgress?.shelfProgressLabel
                            )
                            .titleTransitionSource(
                                id: item.artworkIdentityKey,
                                sourceID: transitionSourceID(for: item)
                            )
                            .contextMenu {
                                MediaTitlePosterActions(item: item) {
                                    open(item)
                                }
                                if let itemProgress {
                                    Button {
                                        onResume?(itemProgress)
                                    } label: {
                                        Label("Resume", systemImage: "play.fill")
                                    }
                                    Button(role: .destructive) {
                                        onRemoveFromContinueWatching?(itemProgress)
                                    } label: {
                                        DestructiveTrashLabel(title: "Remove from Continue Watching")
                                    }
                                    .tint(.red)
                                }
                            }
                        }
                        .pressablePoster()
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func transitionSourceID(for item: MediaItem) -> String {
        "\(item.artworkIdentityKey):media-shelf:\(title)"
    }

    private func open(_ item: MediaItem) {
        transitionSelection?.select(
            titleID: item.artworkIdentityKey,
            sourceID: transitionSourceID(for: item)
        )
        onDetails?(item)
    }
}

struct MediaGridView: View {
    @Environment(\.titleTransitionSelection) private var transitionSelection
    let title: String
    let items: [MediaItem]
    let progress: [WatchProgress]
    let onDetails: ((MediaItem) -> Void)?
    let onResume: ((WatchProgress) -> Void)?
    let onRemoveFromContinueWatching: ((WatchProgress) -> Void)?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: MediaArtworkLayout.gridColumns, alignment: .leading, spacing: 16) {
                ForEach(items) { item in
                    let itemProgress = progress.first {
                        $0.media.id == item.id && $0.providerID == item.providerID
                    }
                    Button { open(item) } label: {
                        PosterGridCard(
                            item: item,
                            progress: itemProgress?.fraction,
                            progressDetail: itemProgress?.shelfProgressLabel
                        )
                        .titleTransitionSource(
                            id: item.artworkIdentityKey,
                            sourceID: transitionSourceID(for: item)
                        )
                        .contextMenu {
                            MediaTitlePosterActions(item: item) {
                                open(item)
                            }
                            if let itemProgress {
                                Button { onResume?(itemProgress) } label: {
                                    Label("Resume", systemImage: "play.fill")
                                }
                                Button(role: .destructive) {
                                    onRemoveFromContinueWatching?(itemProgress)
                                } label: {
                                    DestructiveTrashLabel(title: "Remove from Continue Watching")
                                }
                                .tint(.red)
                            }
                        }
                    }
                    .pressablePoster()
                }
            }
            .padding(.horizontal, MediaArtworkLayout.gridHorizontalPadding)
            .padding(.vertical)
        }
        .background { AppScreenBackground() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func transitionSourceID(for item: MediaItem) -> String {
        "\(item.artworkIdentityKey):media-grid:\(title)"
    }

    private func open(_ item: MediaItem) {
        transitionSelection?.select(
            titleID: item.artworkIdentityKey,
            sourceID: transitionSourceID(for: item)
        )
        onDetails?(item)
    }
}

struct PosterCard: View {
    let item: MediaItem
    var progress: Double?
    var progressDetail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottom) {
                CanonicalPosterArtwork(item: item)
                .frame(
                    width: MediaArtworkLayout.shelfPosterWidth,
                    height: MediaArtworkLayout.shelfPosterWidth * 1.5
                )
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                if let progress {
                    GeometryReader { geometry in
                        VStack { Spacer(); Rectangle().fill(.tint).frame(width: geometry.size.width * progress, height: 4) }
                    }
                }
            }
            Text(item.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .frame(width: MediaArtworkLayout.shelfPosterWidth, alignment: .leading)
            if let progressDetail {
                Text(progressDetail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: MediaArtworkLayout.shelfPosterWidth, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
    }
}

struct PosterGridCard: View {
    let item: MediaItem
    var progress: Double?
    var progressDetail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                // The cell defines the size; loaded artwork must not expand it.
                Color.clear
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay {
                        CanonicalPosterArtwork(item: item)
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if let progress {
                    ProgressView(value: progress)
                        .background(.black.opacity(0.5))
                }
            }
            Text(item.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let progressDetail {
                Text(progressDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
    }
}

struct CachedRemoteImage<Content: View, Placeholder: View>: View {
    @EnvironmentObject private var environment: AppEnvironment
    let url: URL?
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder
    @State private var loadedURL: URL?
    @State private var image: UIImage?

    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let displayedImage {
                content(Image(uiImage: displayedImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            if loadedURL != url {
                loadedURL = nil
                image = nil
            }
            guard let url else { return }
            if let cached = environment.cachedImageIfAvailable(for: url) {
                image = cached
                loadedURL = url
                return
            }
            guard let loadedImage = try? await environment.cachedImage(for: url),
                  !Task.isCancelled else { return }
            image = loadedImage
            loadedURL = url
        }
    }

    private var displayedImage: UIImage? {
        if loadedURL == url, let image { return image }
        return environment.cachedImageIfAvailable(for: url)
    }
}

struct CanonicalPosterArtwork: View {
    @EnvironmentObject private var environment: AppEnvironment
    let item: MediaItem
    @State private var posterURL: URL?

    var body: some View {
        CachedRemoteImage(url: posterURL) { image in
            image
                .resizable()
                .scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
        } placeholder: {
            Rectangle().fill(.gray.opacity(0.22))
                .overlay { Image(systemName: item.kind == .movie ? "film" : "tv") }
        }
        .task(id: item.artworkIdentityKey) {
            posterURL = await environment.canonicalPosterURL(for: item)
        }
    }
}

struct TMDBShelfView: View {
    @Environment(\.titleTransitionSelection) private var transitionSelection
    let collection: TMDBCollection
    let titles: [TrendingTitle]
    let resolvingKeys: Set<String>
    let onSelect: (TrendingTitle) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(collection.title).font(DesignTokens.Typography.shelfTitle)
                Spacer()
                NavigationLink {
                    TMDBCollectionGridView(collection: collection)
                } label: {
                    Text("Show All")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(titles) { title in
                        Button { open(title) } label: {
                            TMDBPosterCard(title: title, width: MediaArtworkLayout.shelfPosterWidth)
                                .overlay {
                                    if resolvingKeys.contains(title.lookupKey) {
                                        ProgressView()
                                            .tint(.white)
                                            .controlSize(.large)
                                            .padding(12)
                                            .background(.black.opacity(0.72), in: Circle())
                                    }
                                }
                                .titleTransitionSource(
                                    id: title.titleTransitionID,
                                    sourceID: transitionSourceID(for: title)
                                )
                                .contextMenu {
                                    TMDBTitlePosterActions(title: title) {
                                        open(title)
                                    }
                                }
                        }
                        .pressablePoster()
                        .allowsHitTesting(!resolvingKeys.contains(title.lookupKey))
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func transitionSourceID(for title: TrendingTitle) -> String {
        "\(title.titleTransitionID):tmdb-shelf:\(collection.id)"
    }

    private func open(_ title: TrendingTitle) {
        transitionSelection?.select(
            titleID: title.titleTransitionID,
            sourceID: transitionSourceID(for: title)
        )
        onSelect(title)
    }
}

struct TMDBPosterCard: View {
    let title: TrendingTitle
    let width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : width)
            .overlay {
                CachedRemoteImage(url: title.posterURL ?? title.backdropURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipped()
                } placeholder: {
                    Rectangle().fill(.gray.opacity(0.22))
                        .overlay { Image(systemName: title.kind == .movie ? "film" : "tv") }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(title.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
                .frame(width: width, alignment: .leading)
                .frame(maxWidth: width == nil ? .infinity : width, alignment: .leading)
        }
        .frame(maxWidth: width == nil ? .infinity : width, alignment: .leading)
        .foregroundStyle(.white)
    }
}

struct SourceLookupStatusOverlay: View {
    @EnvironmentObject private var sourceLookup: SourceLookupCoordinator

    var body: some View {
        VStack(spacing: 8) {
            if let failure = sourceLookup.failure {
                SourceLookupFailureBanner(failure: failure)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if sourceLookup.activeCount > 0 {
                SourceLookupProgressBanner(count: sourceLookup.activeCount) {
                    sourceLookup.cancelAll()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: sourceLookup.failure?.id)
        .animation(.easeInOut(duration: 0.22), value: sourceLookup.activeCount)
    }
}

struct SourceLookupProgressBanner: View {
    let count: Int
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            ProgressView()
                .tint(.white)
                .controlSize(.large)

            VStack(alignment: .leading, spacing: 3) {
                Text("Please wait, looking for sources…")
                    .font(.subheadline.weight(.semibold))
                Text(count > 1 ? String(count) + " searches in progress. This can take up to a minute." : "This can take up to a minute.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }

            Spacer(minLength: 8)

            Button(count > 1 ? "Cancel All" : "Cancel", action: onCancel)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
    }
}

struct SourceLookupFailureBanner: View {
    let failure: SourceLookupFailure

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                Text(failure.title)
                    .font(.subheadline.weight(.semibold))
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(3)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .padding(.horizontal, 12)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

struct TMDBCollectionGridView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sourceLookup: SourceLookupCoordinator
    @Environment(\.titleTransitionSelection) private var transitionSelection
    @StateObject private var model = TMDBCollectionGridViewModel()
    @State private var selectedDetails: ResolvedMediaItem?
    let collection: TMDBCollection

    var body: some View {
        ScrollView {
            LazyVGrid(columns: MediaArtworkLayout.gridColumns, alignment: .leading, spacing: 16) {
                ForEach(model.titles) { title in
                    Button { open(title) } label: {
                        TMDBPosterCard(title: title, width: nil)
                            .overlay {
                                if sourceLookup.activeKeys.contains(title.lookupKey) {
                                    ProgressView()
                                        .tint(.white)
                                        .controlSize(.large)
                                        .padding(10)
                                        .background(.black.opacity(0.72), in: Circle())
                                }
                            }
                            .titleTransitionSource(
                                id: title.titleTransitionID,
                                sourceID: transitionSourceID(for: title)
                            )
                            .contextMenu {
                                TMDBTitlePosterActions(title: title) {
                                    open(title)
                                }
                            }
                    }
                    .pressablePoster()
                    .allowsHitTesting(!sourceLookup.activeKeys.contains(title.lookupKey))
                    .onAppear {
                        if title == model.titles.last {
                            Task { await model.loadNext(collection: collection, environment: environment) }
                        }
                    }
                }
            }
            .padding(.horizontal, MediaArtworkLayout.gridHorizontalPadding)
            .padding(.vertical)
            if model.isLoading { ProgressView().padding() }
        }
        .background { AppScreenBackground() }
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedDetails) {
            DetailsView(item: $0.media, tmdbMetadata: $0.tmdbMetadata)
        }
        .task { await model.loadNext(collection: collection, environment: environment) }
        .errorAlert($model.errorMessage)
    }

    private func open(_ title: TrendingTitle) {
        transitionSelection?.select(
            titleID: title.titleTransitionID,
            sourceID: transitionSourceID(for: title)
        )
        selectedDetails = ResolvedMediaItem(media: .tmdbCatalogItem(from: title), tmdbMetadata: title)
    }

    private func transitionSourceID(for title: TrendingTitle) -> String {
        "\(title.titleTransitionID):tmdb-grid:\(collection.id)"
    }
}

struct CatalogView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sourceLookup: SourceLookupCoordinator
    @StateObject private var model: TMDBCollectionsViewModel
    @State private var selectedDetails: ResolvedMediaItem?
    let kind: MediaKind
    var onOpenSearch: (() -> Void)? = nil

    init(kind: MediaKind, onOpenSearch: (() -> Void)? = nil) {
        self.kind = kind
        self.onOpenSearch = onOpenSearch
        _model = StateObject(wrappedValue: TMDBCollectionsViewModel(
            collections: TMDBCollection.catalogSections(for: kind)
        ))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .center, spacing: 12) {
                    PageTitleText(title: kind == .movie ? "Movies" : "Series")
                    Spacer(minLength: 8)
                    if let onOpenSearch {
                        Button(action: onOpenSearch) {
                            Image(systemName: "magnifyingglass")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .glassEffectWithFallback(in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Search")
                        .padding(.trailing, 20)
                    }
                }
                .padding(.top, ScreenMetrics.topSafeAreaInset + 8)
                .padding(.bottom, 12)
                .background(alignment: .top) {
                    PageTitleTopScrim(height: ScreenMetrics.topSafeAreaInset + 64)
                        .ignoresSafeArea(edges: .top)
                }

                if model.isLoading && model.titles.isEmpty {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 10) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(AppTheme.elevatedSurface)
                                .frame(width: 140, height: 18)
                                .padding(.horizontal, 20)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(0..<6, id: \.self) { _ in
                                        RoundedRectangle(cornerRadius: DesignTokens.Radius.poster, style: .continuous)
                                            .fill(AppTheme.elevatedSurface)
                                            .frame(
                                                width: MediaArtworkLayout.shelfPosterWidth,
                                                height: MediaArtworkLayout.shelfPosterWidth * 1.5
                                            )
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                        .redacted(reason: .placeholder)
                    }
                } else if !model.isLoading,
                          model.collections.allSatisfy({ (model.titles[$0] ?? []).isEmpty }) {
                    ContentUnavailableView(
                        "Nothing to browse",
                        systemImage: kind == .movie ? "film" : "tv",
                        description: Text("Check your connection, then tap Retry.")
                    )
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                    Button("Retry") {
                        Task { await model.load(environment: environment, force: true) }
                    }
                    .buttonStyle(AppPrimaryButtonStyle(glow: environment.theme.glow, minHeight: 44))
                    .padding(.horizontal, 40)
                }
                ForEach(model.collections) { collection in
                    if let titles = model.titles[collection], !titles.isEmpty {
                        TMDBShelfView(
                            collection: collection,
                            titles: titles,
                            resolvingKeys: sourceLookup.activeKeys,
                            onSelect: open
                        )
                    }
                }
            }
            .padding(.bottom)
            .background {
                AppScreenBackground()
                    .ignoresSafeArea()
            }
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .background { AppScreenBackground().ignoresSafeArea() }
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.visible, for: .tabBar)
        .navigationDestination(item: $selectedDetails) {
            DetailsView(item: $0.media, tmdbMetadata: $0.tmdbMetadata)
        }
        .task { await model.load(environment: environment) }
        // No .refreshable — the system pull gesture was producing a black overscroll
        // bar and an unintended reload haptic on Series/Movies. Force-refresh stays
        // available via empty-state retry and revisiting the tab.
        .errorAlert($model.errorMessage)
    }

    private func open(_ title: TrendingTitle) {
        selectedDetails = ResolvedMediaItem(media: .tmdbCatalogItem(from: title), tmdbMetadata: title)
    }
}
