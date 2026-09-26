import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sourceLookup: SourceLookupCoordinator
    @EnvironmentObject private var watchlistToast: WatchlistToastStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onInitialLoadCompleted: () -> Void
    @StateObject private var model = HomeViewModel()
    @State private var selectedDetails: ResolvedMediaItem?
    @State private var playback: PlaybackRequest?

    init(onInitialLoadCompleted: @escaping () -> Void = {}) {
        self.onInitialLoadCompleted = onInitialLoadCompleted
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if !model.trendingTitles.isEmpty {
                    TrendingHeroCarousel(
                        titles: model.trendingTitles,
                        assets: model.carouselAssets,
                        logosResolved: model.carouselLogosResolved,
                        resolvingKeys: sourceLookup.activeKeys,
                        freezesForNavigation: selectedDetails != nil,
                        onDetails: openDetails,
                        onToggleWatchlist: toggleWatchlist
                    )
                    .appHeroPageTransition()
                } else if model.isTrendingLoading {
                    TrendingHeroLoadingView()
                } else if let message = model.trendingMessage {
                    TrendingHeroUnavailableView(message: message)
                }
                if !library.continueWatching.isEmpty {
                    ContinueWatchingShelfView(
                        progress: library.continueWatching,
                        onDetails: {
                            selectedDetails = ResolvedMediaItem(media: $0, tmdbMetadata: nil)
                        },
                        onResume: { value in
                            playback = PlaybackRequest(media: value.media, episode: value.episode)
                        },
                        onMarkAsWatched: { value in markAsWatched(value) },
                        onRemoveFromContinueWatching: { library.removeProgress($0) }
                    )
                }
                let watchlistSeries = library.watchlist.filter { $0.kind == .series }
                if !watchlistSeries.isEmpty {
                    MediaShelfView(
                        title: "Watchlist Series",
                        items: watchlistSeries,
                        onDetails: openDetails
                    )
                }
                let watchlistMovies = library.watchlist.filter { $0.kind == .movie }
                if !watchlistMovies.isEmpty {
                    MediaShelfView(
                        title: "Watchlist Movies",
                        items: watchlistMovies,
                        onDetails: openDetails
                    )
                }
                ForEach(TMDBCollection.homeSections) { collection in
                    if let titles = model.tmdbShelves[collection], !titles.isEmpty {
                        TMDBShelfView(
                            collection: collection,
                            titles: titles,
                            resolvingKeys: sourceLookup.activeKeys,
                            onSelect: openDetails
                        )
                    }
                }
                ForEach(model.shelves) { shelf in
                    MediaShelfView(title: shelf.title, items: shelf.items, onDetails: openDetails)
                }
            }
            .padding(.bottom)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .coordinateSpace(name: HeroArtworkScrollEffect.homeCoordinateSpace)
        .background { AppScreenBackground() }
        .ignoresSafeArea(edges: .top)
        .modifier(HeroViewportModifier())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.visible, for: .tabBar)
        .task {
            await model.loadTrending(environment: environment)
            onInitialLoadCompleted()
        }
        .navigationDestination(for: MediaItem.self) { DetailsView(item: $0) }
        .navigationDestination(item: $selectedDetails) {
            DetailsView(item: $0.media, tmdbMetadata: $0.tmdbMetadata)
        }
        .fullScreenCover(isPresented: Binding(
            get: { playback != nil },
            set: { if !$0 { playback = nil } }
        )) {
            if let playback {
                PlayerScreen(request: playback, nextRequest: nil)
            }
        }
        .errorAlert($model.errorMessage)
    }

    private func openDetails(_ trending: TrendingTitle) {
        withTransaction(Transaction(animation: reduceMotion ? nil : .smooth(duration: 0.38))) {
            selectedDetails = ResolvedMediaItem(
                media: .tmdbCatalogItem(from: trending),
                tmdbMetadata: trending
            )
        }
    }

    private func openDetails(_ item: MediaItem) {
        withTransaction(Transaction(animation: reduceMotion ? nil : .smooth(duration: 0.38))) {
            selectedDetails = ResolvedMediaItem(media: item, tmdbMetadata: nil)
        }
    }

    private func toggleWatchlist(_ trending: TrendingTitle) {
        WatchlistFeedback.toggleTrending(
            trending,
            in: library,
            reduceMotion: reduceMotion,
            toastStore: watchlistToast
        )
    }

    private func markAsWatched(_ value: WatchProgress) {
        guard value.episode != nil else { return }
        let request = PlaybackRequest(media: value.media, episode: value.episode)
        library.markWatched(request: request)
        Task {
            if let next = await nextUnwatchedPlaybackRequest(
                after: request,
                environment: environment,
                library: library
            ) {
                library.promoteToContinueWatching(next)
            }
        }
    }
}

struct TrendingHeroCarousel: View {
    private let interval: TimeInterval = 5

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.titleTransitionSelection) private var transitionSelection
    let titles: [TrendingTitle]
    let assets: TMDBCarouselAssets
    let logosResolved: Bool
    let resolvingKeys: Set<String>
    /// When true, auto-advance and swipe-to-next are paused so the zoom pop
    /// still morphs back to the Featured slide that opened Details.
    var freezesForNavigation: Bool = false
    let onDetails: (TrendingTitle) -> Void
    let onToggleWatchlist: (TrendingTitle) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var currentIndex = 0
    @State private var slideStartedAt = Date()
    @State private var isInteracting = false
    @State private var timerVersion = 0
    @State private var titleContentOffset: CGFloat = 0
    @State private var titleContentOpacity = 1.0
    @State private var indicatorDragProgress: CGFloat = 0
    /// Locked index while Details is open — keeps matchedTransitionSource stable.
    @State private var frozenIndex: Int? = nil

    private var activeIndex: Int { frozenIndex ?? currentIndex }
    private var currentTitle: TrendingTitle { titles[activeIndex % max(titles.count, 1)] }
    private var isCurrentTitleResolving: Bool { resolvingKeys.contains(currentTitle.lookupKey) }
    private var isCurrentTitleInWatchlist: Bool {
        library.watchlist.contains {
            $0.kind == currentTitle.kind && $0.tmdbID == currentTitle.id
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .named(HeroArtworkScrollEffect.homeCoordinateSpace)).minY
            let metrics = HeroArtworkScrollEffect.metrics(minY: minY, reduceMotion: reduceMotion, heroHeight: proxy.size.height)

            ZStack(alignment: .bottom) {
                ZStack {
                    ForEach(Array(titles.enumerated()), id: \.element.id) { index, title in
                        CenteredHeroArtwork(data: assets.artworkDataByKey[title.lookupKey])
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .opacity(index == activeIndex ? 1 : 0)
                            .animation(crossfadeAnimation, value: activeIndex)
                            .accessibilityHidden(index != activeIndex)
                    }

                    Color.black
                        .opacity(HeroArtworkScrollEffect.maximumDimming * metrics.recessionProgress)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(metrics.scale, anchor: .top)
                .offset(y: metrics.parallaxOffset)
                .modifier(HeroArtworkBoundaryClip(isEnabled: metrics.clipsToHeroBounds))
                .offset(y: metrics.verticalOffset)
                .opacity(metrics.opacity)

                AppHeroFade()

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: openCurrentDetails)
                    .contextMenu {
                        TMDBTitlePosterActions(title: currentTitle) {
                            openCurrentDetails()
                        }
                    }
                    .accessibilityHidden(true)

                FeaturedTopChrome(
                    titleCount: titles.count,
                    currentIndex: activeIndex
                )
                .offset(y: metrics.verticalOffset)

                heroContent
                    .padding(.horizontal, 22)
                    .padding(.bottom, 44)

                CarouselPageIndicator(
                    count: titles.count,
                    selectedIndex: activeIndex,
                    startedAt: slideStartedAt,
                    interval: interval,
                    isPaused: freezesForNavigation || isInteracting || scenePhase != .active,
                    dragProgress: indicatorDragProgress
                )
                .padding(.bottom, 18)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .containerRelativeFrame(.horizontal, alignment: .center)
        .modifier(HeroHeightModifier())
        .titleTransitionSource(
            id: currentTitle.titleTransitionID,
            sourceID: heroTransitionSourceID
        )
        .contentShape(Rectangle())
        .background {
            HorizontalCarouselPanRecognizer(
                onBegan: beginHorizontalInteraction,
                onChanged: updateHorizontalInteraction,
                onEnded: endHorizontalInteraction
            )
        }
        .task(id: timerVersion) {
            guard !freezesForNavigation,
                  scenePhase == .active,
                  !isInteracting,
                  titles.count > 1 else { return }
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            guard !Task.isCancelled, !freezesForNavigation else { return }
            select(index: nextIndex)
        }
        .onChange(of: scenePhase) { _, _ in restartTimer() }
        .onChange(of: freezesForNavigation) { _, frozen in
            if frozen {
                frozenIndex = currentIndex
                timerVersion += 1
                isInteracting = false
            } else {
                if let frozenIndex {
                    currentIndex = frozenIndex
                }
                frozenIndex = nil
                restartTimer()
            }
        }
        .onChange(of: titles.map(\.id)) { _, _ in
            currentIndex = min(currentIndex, max(titles.count - 1, 0))
            if let frozenIndex {
                self.frozenIndex = min(frozenIndex, max(titles.count - 1, 0))
            }
            restartTimer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trending: \(currentTitle.title)")
        .accessibilityAdjustableAction { direction in
            guard !freezesForNavigation else { return }
            switch direction {
            case .increment: select(index: nextIndex)
            case .decrement: select(index: previousIndex)
            @unknown default: break
            }
        }
    }

    private var heroContent: some View {
        VStack(spacing: 13) {
            Spacer()
            VStack(spacing: 13) {
                Text("TRENDING NOW")
                    .font(.caption2.weight(.bold))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.74))

                TitleLogoView(
                    title: currentTitle.title,
                    logoData: assets.logoDataByKey[currentTitle.lookupKey],
                    showsFallback: logosResolved
                ) {
                    Text(currentTitle.title)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                        .contentTransition(.opacity)
                }
                .id(currentTitle.id)

                metadata

                if !currentTitle.overview.isEmpty {
                    Text(currentTitle.overview)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                }
            }
            .offset(x: titleContentOffset)
            .opacity(titleContentOpacity)

            HStack(spacing: 10) {
                Button {
                    openCurrentDetails()
                } label: {
                    Group {
                        if isCurrentTitleResolving {
                            ProgressView().tint(.black)
                        } else {
                            Label("View Details", systemImage: "info.circle.fill")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(
                    AppPrimaryButtonStyle(
                        glow: .white.opacity(0.35),
                        minHeight: 44,
                        horizontalPadding: 14,
                        verticalPadding: 10
                    )
                )
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .allowsHitTesting(!isCurrentTitleResolving)

                FeaturedAddToListButton(
                    isInWatchlist: isCurrentTitleInWatchlist,
                    isDisabled: isCurrentTitleResolving
                ) {
                    onToggleWatchlist(currentTitle)
                }
            }
            .frame(height: 44)
            .padding(.horizontal, 16)

        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.55), radius: 12, y: 4)
    }

    private var metadata: some View {
        HStack(spacing: 7) {
            Text(currentTitle.kind == .movie ? "Movie" : "TV Show")
            if let year = currentTitle.year {
                Text("·")
                Text(year)
            }
            if let genre = currentTitle.genreNames.first {
                Text("·")
                Text(genre)
            }
            if let rating = currentTitle.rating, rating > 0 {
                Text("·")
                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                    .labelStyle(.titleAndIcon)
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private func openCurrentDetails() {
        guard !isInteracting, !isCurrentTitleResolving else { return }
        DesignTokens.Haptics.selection()
        transitionSelection?.select(
            titleID: currentTitle.titleTransitionID,
            sourceID: heroTransitionSourceID
        )
        // Freeze the hero on this slide before the zoom push so interactive
        // pop still morphs back to the same Featured source.
        frozenIndex = activeIndex
        onDetails(currentTitle)
    }

    private var heroTransitionSourceID: String {
        "\(currentTitle.titleTransitionID):home-hero"
    }

    private func beginHorizontalInteraction() {
        guard !freezesForNavigation, !isInteracting else { return }
        timerVersion += 1
        isInteracting = true
    }

    private func updateHorizontalInteraction(translation: CGFloat) {
        guard isInteracting else { return }
        let progress = min(abs(translation) / 72, 1)
        indicatorDragProgress = min(max(translation / 72, -1), 1)
        titleContentOffset = reduceMotion ? 0 : translation * 0.34
        titleContentOpacity = 1 - progress
    }

    private func endHorizontalInteraction(translation: CGFloat) {
        guard isInteracting, !freezesForNavigation else {
            isInteracting = false
            return
        }
        if abs(translation) > 34 {
            let direction: CGFloat = translation < 0 ? -1 : 1
            slideStartedAt = Date()
            withAnimation(nil) {
                currentIndex = direction < 0 ? nextIndex : previousIndex
                indicatorDragProgress = 0
                titleContentOffset = reduceMotion ? 0 : -direction * 28
                titleContentOpacity = reduceMotion ? 1 : 0
                isInteracting = false
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                titleContentOffset = 0
                titleContentOpacity = 1
            }
            timerVersion += 1
        } else {
            isInteracting = false
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
                indicatorDragProgress = 0
                titleContentOffset = 0
                titleContentOpacity = 1
            }
            restartTimer()
        }
    }

    private var nextIndex: Int { (currentIndex + 1) % titles.count }
    private var previousIndex: Int { (currentIndex - 1 + titles.count) % titles.count }
    private var crossfadeAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.72) }

    private func select(index: Int) {
        guard !freezesForNavigation else { return }
        slideStartedAt = Date()
        withAnimation(crossfadeAnimation) { currentIndex = index }
        timerVersion += 1
    }

    private func restartTimer() {
        guard !freezesForNavigation else { return }
        slideStartedAt = Date()
        timerVersion += 1
    }

}

struct FeaturedAddToListButton: View {
    let isInWatchlist: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var pulse = false
    @State private var ring = false

    var body: some View {
        Button {
            guard !isDisabled else { return }
            pulse.toggle()
            ring = true
            action()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(520))
                ring = false
            }
        } label: {
            ZStack {
                if ring {
                    Capsule()
                        .stroke(.white.opacity(0.55), lineWidth: 2)
                        .scaleEffect(pulse ? 1.16 : 1)
                        .opacity(pulse ? 0 : 0.85)
                }

                HStack(spacing: 7) {
                    Image(systemName: isInWatchlist ? "checkmark" : "plus")
                        .font(.subheadline.weight(.bold))
                        .contentTransition(.symbolEffect(.replace))
                        .scaleEffect(pulse ? 1.22 : 1)
                    Text(isInWatchlist ? "In My List" : "Add to List")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .glassEffectWithFallback(in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.24), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 10, y: 3)
        .scaleEffect(pulse ? 1.05 : 1)
        .animation(DesignTokens.Motion.watchlistBurst, value: pulse)
        .animation(DesignTokens.Motion.watchlistBurst, value: isInWatchlist)
        .accessibilityLabel(isInWatchlist ? "Remove from Watchlist" : "Add to Watchlist")
        .allowsHitTesting(!isDisabled)
    }
}

struct TitleLogoView<Fallback: View>: View {
    private let maximumLogoWidth: CGFloat
    private let maximumLogoHeight: CGFloat

    let title: String
    let logoData: Data?
    let showsFallback: Bool
    let fallback: Fallback

    init(
        title: String,
        logoData: Data?,
        showsFallback: Bool,
        maximumLogoWidth: CGFloat = 320,
        maximumLogoHeight: CGFloat = 96,
        @ViewBuilder fallback: () -> Fallback
    ) {
        self.title = title
        self.logoData = logoData
        self.showsFallback = showsFallback
        self.maximumLogoWidth = maximumLogoWidth
        self.maximumLogoHeight = maximumLogoHeight
        self.fallback = fallback()
    }

    var body: some View {
        let logoImage = logoData.flatMap(UIImage.init(data:)).flatMap { image -> UIImage? in
            guard image.size.width > 4, image.size.height > 4 else { return nil }
            return image
        }

        Group {
            if let logoImage {
                Image(uiImage: logoImage)
                    .resizable()
                    .scaledToFit()
                    .frame(
                        maxWidth: maximumLogoWidth,
                        maxHeight: maximumLogoHeight
                    )
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
                    .accessibilityHidden(true)
            } else if showsFallback {
                fallback
            } else {
                Color.clear
                    .frame(height: maximumLogoHeight * 0.4)
            }
        }
            // Reserve one consistent logo region. Logo XOR text — never both.
            .frame(maxWidth: maximumLogoWidth, minHeight: maximumLogoHeight * 0.72)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }
}

struct FeaturedTopChrome: View {
    let titleCount: Int
    let currentIndex: Int

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                PageTitleTopScrim(height: ScreenMetrics.topSafeAreaInset + 58)
                    .frame(maxWidth: .infinity)

                HStack(alignment: .center, spacing: 10) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("BetterStreamflix")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
                        Text("Featured")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                // Sit the brand closer to the status bar / Dynamic Island.
                .padding(.top, ScreenMetrics.topSafeAreaInset + 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    titleCount > 1
                        ? "BetterStreamflix Featured, \(currentIndex + 1) of \(titleCount)"
                        : "BetterStreamflix Featured"
                )
            }
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }
}

struct CenteredHeroArtwork: View {
    let data: Data?

    var body: some View {
        Color.clear
            .overlay {
                Group {
                    if let data, let image = UIImage(data: data) {
                        if UIDevice.current.userInterfaceIdiom == .pad {
                            GeometryReader { proxy in
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                            }
                        } else {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        }
                    } else {
                        Rectangle().fill(.gray.opacity(0.16))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .clipped()
    }
}

struct CarouselPageIndicator: View {
    private let collapsedWidth: CGFloat = 7
    private let expandedWidth: CGFloat = 42

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let count: Int
    let selectedIndex: Int
    let startedAt: Date
    let interval: TimeInterval
    let isPaused: Bool
    let dragProgress: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: isPaused)) { context in
            let progress = min(max(context.date.timeIntervalSince(startedAt) / interval, 0), 1)
            HStack(spacing: 8) {
                ForEach(0..<count, id: \.self) { index in
                    let emphasis = emphasis(for: index)
                    GeometryReader { geometry in
                        Capsule()
                            .fill(.white.opacity(inactiveOpacity(for: emphasis)))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(.white)
                                    .frame(
                                        width: geometry.size.width * fillProgress(
                                            for: index,
                                            timerProgress: progress
                                        )
                                    )
                            }
                            .clipShape(Capsule())
                    }
                    .frame(width: width(for: emphasis), height: collapsedWidth)
                    .animation(settleAnimation, value: selectedIndex)
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private var dragAmount: CGFloat {
        min(abs(dragProgress), 1)
    }

    private var dragTargetIndex: Int? {
        guard count > 1, dragAmount > 0 else { return nil }
        return dragProgress < 0
            ? (selectedIndex + 1) % count
            : (selectedIndex - 1 + count) % count
    }

    private func emphasis(for index: Int) -> CGFloat {
        if index == selectedIndex { return 1 - dragAmount }
        if index == dragTargetIndex { return dragAmount }
        return 0
    }

    private func width(for emphasis: CGFloat) -> CGFloat {
        collapsedWidth + ((expandedWidth - collapsedWidth) * emphasis)
    }

    private func inactiveOpacity(for emphasis: CGFloat) -> Double {
        0.48 - (0.20 * Double(emphasis))
    }

    private func fillProgress(for index: Int, timerProgress: CGFloat) -> CGFloat {
        index == selectedIndex ? timerProgress : 0
    }

    private var settleAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.38)
    }
}

struct TrendingHeroLoadingView: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(.gray.opacity(0.12))
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            ProgressView("Loading trends from TMDB…")
                .tint(.white)
                .foregroundStyle(.white.opacity(0.72))
                .padding(.bottom, 54)
            PageTitleOverlay(title: "Home")
        }
        .containerRelativeFrame(.horizontal, alignment: .center)
        .modifier(HeroHeightModifier())
    }
}

struct PageTitleOverlay: View {
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                PageTitleTopScrim(height: ScreenMetrics.topSafeAreaInset + 64)
                PageTitleText(title: title)
                    .padding(.top, ScreenMetrics.topSafeAreaInset + 8)
            }
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PageTitleHeader: View {
    let title: String
    /// When the parent ignores the top safe area (full-bleed pages), pad past the
    /// status bar / Dynamic Island. When the parent already respects safe area,
    /// only add a small breathing gap.
    var ignoresTopSafeArea: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if ignoresTopSafeArea {
                PageTitleTopScrim(height: ScreenMetrics.topSafeAreaInset + 56)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, -(ScreenMetrics.topSafeAreaInset + 56))
            }
            PageTitleText(title: title)
                .padding(.top, ignoresTopSafeArea ? ScreenMetrics.topSafeAreaInset + 8 : 8)
                .padding(.bottom, 12)
        }
    }
}

struct PageTitleText: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 12, y: 3)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }
}

struct HorizontalCarouselPanRecognizer: UIViewRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.onWindowChanged = { [weak coordinator = context.coordinator] marker in
            coordinator?.install(marker: marker)
        }
        return view
    }

    func updateUIView(_ uiView: AttachmentView, context: Context) {
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.install(marker: uiView)
    }

    static func dismantleUIView(_ uiView: AttachmentView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class AttachmentView: UIView {
        var onWindowChanged: ((AttachmentView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChanged?(self)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBegan: () -> Void
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat) -> Void
        private weak var host: UIView?
        private weak var marker: AttachmentView?
        private lazy var pan: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            return recognizer
        }()

        init(
            onBegan: @escaping () -> Void,
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat) -> Void
        ) {
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func install(marker: AttachmentView) {
            self.marker = marker
            guard let window = marker.window, host !== window else { return }
            uninstall()
            self.marker = marker
            host = window
            window.addGestureRecognizer(pan)
        }

        func uninstall() {
            host?.removeGestureRecognizer(pan)
            host = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let marker,
                  marker.window != nil,
                  marker.bounds.contains(pan.location(in: marker)) else { return false }
            let velocity = pan.velocity(in: marker)
            return abs(velocity.x) > abs(velocity.y) * 1.1
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                onBegan()
            case .changed:
                onChanged(recognizer.translation(in: recognizer.view).x)
            case .ended:
                onEnded(recognizer.translation(in: recognizer.view).x)
            case .cancelled, .failed:
                onEnded(0)
            default:
                break
            }
        }
    }
}

struct TabBarTapObserver: UIViewRepresentable {
    let tabIndex: Int
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(tabIndex: tabIndex, onTap: onTap)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.onWindowChanged = { [weak coordinator = context.coordinator] marker in
            coordinator?.install(marker: marker)
        }
        return view
    }

    func updateUIView(_ uiView: AttachmentView, context: Context) {
        context.coordinator.tabIndex = tabIndex
        context.coordinator.onTap = onTap
        context.coordinator.install(marker: uiView)
    }

    static func dismantleUIView(_ uiView: AttachmentView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class AttachmentView: UIView {
        var onWindowChanged: ((AttachmentView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChanged?(self)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var tabIndex: Int
        var onTap: () -> Void
        private weak var tabBar: UITabBar?
        private weak var marker: AttachmentView?
        private var wasSelectedAtTouchStart = false
        private lazy var tap: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            return recognizer
        }()

        init(tabIndex: Int, onTap: @escaping () -> Void) {
            self.tabIndex = tabIndex
            self.onTap = onTap
        }

        func install(marker: AttachmentView) {
            self.marker = marker
            guard let window = marker.window,
                  let candidate = findTabBarController(in: window.rootViewController)?.tabBar,
                  tabBar !== candidate else { return }
            uninstall()
            self.marker = marker
            tabBar = candidate
            candidate.addGestureRecognizer(tap)
        }

        func uninstall() {
            tabBar?.removeGestureRecognizer(tap)
            tabBar = nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let tabBar,
                  let items = tabBar.items,
                  items.indices.contains(tabIndex),
                  tappedTabIndex(
                    in: tabBar,
                    itemCount: items.count,
                    location: touch.location(in: tabBar)
                  ) == tabIndex
            else {
                wasSelectedAtTouchStart = false
                return true
            }
            wasSelectedAtTouchStart = tabBar.selectedItem === items[tabIndex]
            return true
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            defer { wasSelectedAtTouchStart = false }
            guard recognizer.state == .ended,
                  wasSelectedAtTouchStart,
                  let tabBar,
                  let items = tabBar.items,
                  items.indices.contains(tabIndex),
                  tappedTabIndex(
                    in: tabBar,
                    itemCount: items.count,
                    location: recognizer.location(in: tabBar)
                  ) == tabIndex
            else { return }
            onTap()
        }

        private func tappedTabIndex(
            in tabBar: UITabBar,
            itemCount: Int,
            location: CGPoint
        ) -> Int? {
            let controls = tabBar.subviews
                .compactMap { $0 as? UIControl }
                .filter { !$0.isHidden && $0.alpha > 0 && $0.frame.contains(location) }

            if let tappedControl = controls.first {
                let orderedControls = tabBar.subviews
                    .compactMap { $0 as? UIControl }
                    .filter { !$0.isHidden && $0.alpha > 0 }
                    .sorted { $0.frame.minX < $1.frame.minX }
                guard let visualIndex = orderedControls.firstIndex(where: { $0 === tappedControl }) else {
                    return nil
                }
                return logicalIndex(forVisualIndex: visualIndex, itemCount: itemCount, in: tabBar)
            }

            guard itemCount > 0, tabBar.bounds.width > 0 else { return nil }
            let visualIndex = min(
                Int(location.x / (tabBar.bounds.width / CGFloat(itemCount))),
                itemCount - 1
            )
            return logicalIndex(forVisualIndex: visualIndex, itemCount: itemCount, in: tabBar)
        }

        private func logicalIndex(forVisualIndex visualIndex: Int, itemCount: Int, in view: UIView) -> Int {
            view.effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? itemCount - visualIndex - 1
                : visualIndex
        }

        private func findTabBarController(in viewController: UIViewController?) -> UITabBarController? {
            guard let viewController else { return nil }
            if let tabBarController = viewController as? UITabBarController {
                return tabBarController
            }
            for child in viewController.children {
                if let match = findTabBarController(in: child) { return match }
            }
            if let presented = viewController.presentedViewController {
                return findTabBarController(in: presented)
            }
            return nil
        }
    }
}

struct TrendingHeroUnavailableView: View {
    let message: String

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("Trending on TMDB")
                .font(DesignTokens.Typography.shelfTitle)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Pull to refresh and try again.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.Spacing.xl)
        .glassEffectWithFallback(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
    }
}
