import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DetailsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sourceLookup: SourceLookupCoordinator
    @EnvironmentObject private var watchlistToast: WatchlistToastStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.titleTransitionSelection) private var titleTransitionSelection
    @StateObject private var model: DetailsViewModel
    @State private var selectedSeasonNumber: Int?
    @State private var playback: PlaybackRequest?
    @State private var episodeInfo: MediaEpisode?
    @State private var tmdbHeroArtworkData: Data?
    @State private var tmdbTitleLogoData: Data?
    @State private var isHeroArtworkLoading = true
    @State private var isTitleLogoResolved = false
    @State private var selectedPerson: CastMember?
    @State private var heroScrollMinY: CGFloat = 0
    @State private var myListBurst = false

    private var showsCompactHeader: Bool {
        -heroScrollMinY > HeroArtworkScrollEffect.compactHeaderRevealDistance
    }

    init(item: MediaItem, tmdbMetadata: TrendingTitle? = nil) {
        _model = StateObject(wrappedValue: DetailsViewModel(
            item: item,
            tmdbMetadataSnapshot: tmdbMetadata
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                detailsHero
                    .appHeroPageTransition()

                VStack(alignment: .leading, spacing: 18) {
                    detailsTitle
                    detailsMetadata
                    if let overview = model.item.overview { Text(overview).foregroundStyle(.secondary) }
                    HStack(spacing: 10) {
                        Button {
                            guard let request = primaryPlaybackRequest else { return }
                            DesignTokens.Haptics.primaryAction()
                            Task { await beginPlayback(request) }
                        } label: {
                            Label(primaryActionTitle, systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .buttonStyle(
                            AppPrimaryButtonStyle(
                                glow: environment.theme.glow,
                                minHeight: 40,
                                horizontalPadding: 14,
                                verticalPadding: 8
                            )
                        )
                        .frame(height: 40)
                        .disabled(primaryPlaybackRequest == nil)

                        Button {
                            myListBurst.toggle()
                            WatchlistFeedback.toggle(
                                model.item,
                                in: library,
                                reduceMotion: reduceMotion,
                                toastStore: watchlistToast
                            )
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: library.isInWatchlist(model.item) ? "checkmark" : "plus")
                                    .font(.subheadline.weight(.bold))
                                    .contentTransition(.symbolEffect(.replace))
                                    .scaleEffect(myListBurst ? 1.18 : 1)
                                Text("My List")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(height: 40)
                        .glassEffectWithFallback(in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(.white.opacity(0.22), lineWidth: 1)
                        }
                        .scaleEffect(myListBurst ? 1.04 : 1)
                        .animation(DesignTokens.Motion.watchlistBurst, value: myListBurst)
                        .accessibilityLabel(
                            library.isInWatchlist(model.item) ? "Remove from My List" : "Add to My List"
                        )
                    }
                    .frame(height: 40)

                    if let trailerURL = model.trailerURL {
                        Button {
                            UIApplication.shared.open(trailerURL)
                        } label: {
                            Label("Watch trailer", systemImage: "film")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .frame(height: 40)
                        .glassEffectWithFallback(in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(.white.opacity(0.22), lineWidth: 1)
                        }
                    }

                    if !model.item.seasons.isEmpty { seasonsSection }
                    if !model.item.cast.isEmpty {
                        Text("Cast")
                            .font(DesignTokens.Typography.shelfTitle)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(model.item.cast) { member in
                                    castMemberButton(member)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                // Pull the details content into the hero so its clear logo sits
                // at the same vertical position as the Home carousel logo.
                .padding(.top, -HeroArtworkScrollEffect.detailsContentOverlap)
                .padding(.bottom, 32)
                .zIndex(1)
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .coordinateSpace(name: HeroArtworkScrollEffect.detailsCoordinateSpace)
        .background { AppScreenBackground() }
        .ignoresSafeArea(edges: .top)
        .modifier(HeroViewportModifier())
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .background {
            NavigationChromeStabilizer(enablesInteractivePop: true)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // Zoom transition applies only to page content — sticky chrome stays
        // outside matched geometry so it cannot ghost onto Home after pop.
        .titleNavigationTransition(id: model.item.artworkIdentityKey)
        .overlay(alignment: .top) {
            ScrollRevealChrome(
                showsCompactTitle: showsCompactHeader,
                reduceMotion: reduceMotion,
                onBack: { dismiss() }
            ) {
                // Sticky header uses the TMDB text logo (not plain title text).
                TitleLogoView(
                    title: model.item.title,
                    logoData: tmdbTitleLogoData,
                    showsFallback: isTitleLogoResolved,
                    maximumLogoWidth: 196,
                    maximumLogoHeight: 26
                ) {
                    Text(model.item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .overlay { if model.isLoading && model.item.overview == nil { ProgressView() } }
        .overlay {
            if let episodeInfo {
                EpisodeInfoOverlay(
                    showTitle: model.item.title,
                    episode: episodeInfo,
                    onDismiss: { withAnimation(.easeOut(duration: 0.18)) { self.episodeInfo = nil } }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: episodeInfo?.id)
        .task {
            let initialItem = model.item
            let preferredSeasonNumber = library.latestProgress(for: initialItem)?.episode?.seasonNumber

            // Resume the season selected by Continue Watching when it is already
            // available; otherwise present the first regular season immediately.
            selectedSeasonNumber = preferredSeasonNumber.flatMap { preferredNumber in
                model.item.seasons.first(where: { $0.number == preferredNumber })?.number
            } ?? model.orderedSeasons.first?.number

            let artworkTask = Task { @MainActor in
                let artwork = await sourceLookup.resolveArtwork(
                    for: initialItem,
                    environment: environment
                )
                guard !Task.isCancelled else { return }
                tmdbHeroArtworkData = artwork
                isHeroArtworkLoading = false
            }
            let logoTask = Task { @MainActor in
                // Shared cache + same presentation pipeline as Featured.
                if let logo = await loadTitleLogo(for: initialItem, metadata: model.tmdbMetadata) {
                    tmdbTitleLogoData = logo
                    isTitleLogoResolved = true
                }
            }
            defer {
                artworkTask.cancel()
                logoTask.cancel()
            }

            await model.load(
                environment: environment,
                preferredSeasonNumber: preferredSeasonNumber
            )
            await artworkTask.value
            await logoTask.value
            guard !Task.isCancelled else { return }

            if model.item.tmdbID != initialItem.tmdbID || tmdbTitleLogoData == nil {
                async let correctedArtwork = sourceLookup.resolveArtwork(
                    for: model.item,
                    environment: environment
                )
                async let correctedLogo = loadTitleLogo(for: model.item, metadata: model.tmdbMetadata)
                if let logo = await correctedLogo {
                    tmdbTitleLogoData = logo
                }
                if let artwork = await correctedArtwork {
                    tmdbHeroArtworkData = artwork
                }
            }
            isTitleLogoResolved = true
            guard !Task.isCancelled else { return }
            let preferredSeasonIsAvailable = preferredSeasonNumber.map { preferredNumber in
                model.item.seasons.contains { $0.number == preferredNumber }
            } ?? false
            let selectionIsStillAvailable = selectedSeasonNumber.map { selectedNumber in
                model.item.seasons.contains { $0.number == selectedNumber }
            } ?? false
            if preferredSeasonIsAvailable {
                selectedSeasonNumber = preferredSeasonNumber
            } else if !selectionIsStillAvailable {
                selectedSeasonNumber = model.orderedSeasons.first?.number
            }
        }
        .navigationDestination(item: $selectedPerson) { member in
            PersonProfileView(
                personID: member.tmdbID ?? 0,
                placeholderName: member.name,
                placeholderImageURL: member.imageURL
            )
        }
        .fullScreenCover(isPresented: Binding(get: { playback != nil }, set: { if !$0 { playback = nil } })) {
            if let playback {
                PlayerScreen(request: playback, nextRequest: nextRequest(after: playback.episode))
            }
        }
        .errorAlert($model.errorMessage)
        .onDisappear {
            // Clear zoom selection immediately so Home does not briefly ghost
            // Detail chrome / matched-geometry residue after swipe-back.
            titleTransitionSelection?.clear()
        }
    }

    @ViewBuilder
    private func castMemberButton(_ member: CastMember) -> some View {
        let content = VStack(spacing: 8) {
            CachedRemoteImage(url: member.imageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle()
                    .fill(AppTheme.elevatedSurface)
                    .overlay {
                        Text(String(member.name.prefix(1)))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())
            .overlay {
                if member.canOpenProfile {
                    Circle().stroke(environment.theme.accent.opacity(0.35), lineWidth: 1)
                }
            }
            Text(member.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 80)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(member.canOpenProfile ? .isButton : [])

        if member.canOpenProfile {
            Button {
                DesignTokens.Haptics.selection()
                selectedPerson = member
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var detailsHero: some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .named(HeroArtworkScrollEffect.detailsCoordinateSpace)).minY
            let metrics = HeroArtworkScrollEffect.metrics(minY: minY, reduceMotion: reduceMotion, heroHeight: proxy.size.height)

            ZStack(alignment: .bottom) {
                ZStack {
                    // Share the carousel's sizing and artwork alignment on each device.
                    CenteredHeroArtwork(data: tmdbHeroArtworkData)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .overlay {
                            if tmdbHeroArtworkData == nil {
                                if isHeroArtworkLoading {
                                    ProgressView()
                                        .controlSize(.large)
                                        .tint(.white)
                                        .accessibilityLabel("Loading artwork")
                                } else {
                                    Image(systemName: model.item.kind == .movie ? "film" : "tv")
                                        .font(.system(size: 44))
                                        .foregroundStyle(.white.opacity(0.45))
                                }
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()

                    Color.black
                        .opacity(HeroArtworkScrollEffect.maximumDimming * metrics.recessionProgress)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(metrics.scale, anchor: .top)
                .offset(y: metrics.parallaxOffset)
                .modifier(HeroArtworkBoundaryClip(isEnabled: metrics.clipsToHeroBounds))
                .offset(y: metrics.verticalOffset)
                .opacity(metrics.opacity)

                // This gradient deliberately remains in the scrolling layer so it
                // continues to sit behind the title as the artwork recedes.
                AppHeroFade()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .preference(key: DetailsHeroScrollOffsetKey.self, value: minY)
        }
        // The Home carousel intentionally locks to its scroll container. The
        // details hero instead follows the current proposal so a landscape
        // player presentation cannot leave a stale width behind in portrait.
        .frame(maxWidth: .infinity, alignment: .center)
        .modifier(HeroHeightModifier())
        .onPreferenceChange(DetailsHeroScrollOffsetKey.self) { value in
            heroScrollMinY = value
        }
    }

    private var detailsTitle: some View {
        // Logo XOR text — never both. Prefer the TMDB title treatment logo over
        // baked-in poster typography (hero art prefers textless sources when a logo exists).
        // Nav bar carries the Actor-style inline title; this remains the in-page brand mark.
        TitleLogoView(
            title: model.item.title,
            logoData: tmdbTitleLogoData,
            showsFallback: isTitleLogoResolved
        ) {
            Text(model.item.title)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .shadow(color: .black.opacity(0.55), radius: 12, y: 4)
        .accessibilityAddTraits(.isHeader)
        .opacity(showsCompactHeader ? 0 : 1)
        .accessibilityHidden(showsCompactHeader)
        .animation(reduceMotion ? nil : DesignTokens.Motion.compactHeader, value: showsCompactHeader)
    }

    private func loadTitleLogo(for item: MediaItem, metadata: TrendingTitle?) async -> Data? {
        func accepted(_ data: Data?) -> Data? {
            guard let data,
                  let image = UIImage(data: data),
                  image.size.width > 4,
                  image.size.height > 4 else { return nil }
            return data
        }

        // Featured → Detail parity: read shared in-memory cache first.
        if let metadata, let cached = accepted(environment.cachedTitleLogo(forKey: metadata.lookupKey)) {
            return cached
        }
        if let key = AppEnvironment.titleLogoKey(for: item),
           let cached = accepted(environment.cachedTitleLogo(forKey: key)) {
            return cached
        }

        let tmdbID = metadata?.id ?? item.tmdbID
        let kind = metadata?.kind ?? item.kind
        if let tmdbID {
            if let logo = accepted(
                await environment.titlePresentationLogo(
                    tmdbID: tmdbID,
                    kind: kind,
                    fallbackPosterURL: metadata?.posterURL ?? item.posterURL,
                    fallbackBackdropURL: metadata?.backdropURL ?? item.backdropURL
                )
            ) {
                return logo
            }
        }

        // Last resort: language-ordered logo URL path (also fills shared cache).
        for language in AppEnvironment.logoLanguageCandidates() {
            if let data = accepted(try? await environment.tmdbLogoData(for: item, language: language)) {
                return data
            }
            if let metadata,
               let data = accepted(try? await environment.tmdbLogoData(for: metadata, language: language)) {
                return data
            }
        }
        return nil
    }

    private var detailsMetadata: some View {
        HStack(spacing: 10) {
            Text(model.item.kind == .movie ? "Movie" : "TV Show")
            if let rating = model.item.rating, rating > 0 {
                Text("·")
                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                    .foregroundStyle(.yellow)
            }
            if let release = model.item.releaseDate {
                Text("·")
                Text(String(release.prefix(4)))
            }
            if let quality = model.item.quality {
                Text("·")
                Text(quality)
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white.opacity(0.82))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private var seasonsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let firstSeason = model.orderedSeasons.first {
                HStack {
                    Text("Episodes")
                        .font(DesignTokens.Typography.shelfTitle)
                        .foregroundStyle(AppTheme.primaryText)
                    Spacer(minLength: 8)
                    Picker("Season", selection: Binding(get: { selectedSeasonNumber ?? firstSeason.number }, set: { seasonNumber in
                        selectedSeasonNumber = seasonNumber
                        guard let season = model.item.seasons.first(where: { $0.number == seasonNumber }) else { return }
                        Task { await model.loadEpisodes(season, environment: environment) }
                    })) {
                        ForEach(model.orderedSeasons) { Text($0.title ?? "Season \($0.number)").tag($0.number) }
                    }
                    .pickerStyle(.menu)
                    .tint(environment.theme.accentBright)
                }

                let season = model.item.seasons.first {
                    $0.number == selectedSeasonNumber
                } ?? firstSeason
                LazyVStack(spacing: 12) {
                    ForEach(model.episodes[season.id] ?? []) { episode in
                        episodeCard(episode)
                    }
                }
            }
        }
    }

    private func episodeCard(_ episode: MediaEpisode) -> some View {
        let episodeProgress = library.progress(for: episode, in: model.item)
        let isWatched = library.isWatched(episode, in: model.item)
        let resumeLabel = episodeProgress?.resumeLabel

        return Button {
            DesignTokens.Haptics.primaryAction()
            Task { await beginPlayback(PlaybackRequest(media: model.item, episode: episode)) }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                ZStack(alignment: .bottom) {
                    CachedRemoteImage(url: episode.posterURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle()
                            .fill(AppTheme.elevatedSurface)
                            .overlay {
                                Image(systemName: "tv")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                    }
                    .frame(width: 132, height: 74)
                    .clipped()

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.55)],
                        startPoint: .center,
                        endPoint: .bottom
                    )

                    if let episodeProgress {
                        ProgressView(value: episodeProgress.fraction)
                            .tint(environment.theme.accent)
                            .background(.white.opacity(0.22))
                            .padding(.horizontal, 1)
                            .padding(.bottom, 1)
                    }

                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.55), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isWatched {
                        VStack {
                            HStack {
                                Spacer(minLength: 0)
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.white, .green)
                                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(6)
                    }
                }
                .frame(width: 132, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 0.8)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("E\(episode.number)  ·  \(episode.title ?? "Episode")")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        if let releaseDate = episode.formattedReleaseDate {
                            Text(releaseDate)
                        }
                        if let resumeLabel {
                            Text("·")
                            Text(resumeLabel)
                                .foregroundStyle(environment.theme.accentBright)
                        } else if isWatched {
                            Text("·")
                            Text("Watched")
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .glassEffectWithFallback(
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await beginPlayback(PlaybackRequest(media: model.item, episode: episode)) }
            } label: {
                Label(resumeLabel == nil ? "Play" : "Resume", systemImage: "play.fill")
            }

            Button {
                let request = PlaybackRequest(media: model.item, episode: episode)
                if isWatched {
                    library.markUnwatched(request: request)
                } else {
                    markEpisodeAsWatched(request)
                }
            } label: {
                Label(
                    isWatched ? "Mark as Unwatched" : "Mark as Watched",
                    systemImage: isWatched ? "circle" : "checkmark.circle"
                )
            }

            if hasPreviousEpisodes(before: episode) {
                Button {
                    markPreviousEpisodesAsWatched(before: episode)
                } label: {
                    Label(
                        "Mark Previous Episodes as Watched",
                        systemImage: "checkmark.rectangle.stack.fill"
                    )
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { episodeInfo = episode }
            } label: {
                Label("Show Episode Info", systemImage: "info.circle")
            }
        }
        .accessibilityLabel("Episode \(episode.number), \(episode.title ?? "Episode")")
        .accessibilityHint(resumeLabel == nil ? "Plays episode" : "Resumes episode")
    }

    private func nextRequest(after episode: MediaEpisode?) -> PlaybackRequest? {
        guard let episode,
              let season = model.item.seasons.first(where: { $0.number == episode.seasonNumber }),
              let list = model.episodes[season.id],
              let index = list.firstIndex(of: episode) else { return nil }
        if list.indices.contains(index + 1) {
            return PlaybackRequest(media: model.item, episode: list[index + 1])
        }
        guard let seasonIndex = model.item.seasons.firstIndex(of: season),
              model.item.seasons.indices.contains(seasonIndex + 1),
              let firstEpisode = model.episodes[model.item.seasons[seasonIndex + 1].id]?.first else { return nil }
        return PlaybackRequest(media: model.item, episode: firstEpisode)
    }

    private var primaryPlaybackRequest: PlaybackRequest? {
        if model.item.kind == .movie { return PlaybackRequest(media: model.item, episode: nil) }

        if let progressEpisode = library.latestProgress(for: model.item)?.episode,
           let progressSeason = model.item.seasons.first(where: { $0.number == progressEpisode.seasonNumber }),
           let progressEpisodes = model.episodes[progressSeason.id],
           let episode = progressEpisodes.first(where: { candidate in
               candidate.id == progressEpisode.id || (
                   candidate.seasonNumber == progressEpisode.seasonNumber &&
                   candidate.number == progressEpisode.number
               )
           }) {
            return PlaybackRequest(media: model.item, episode: episode)
        }

        guard let season = model.item.seasons.first(where: {
            $0.number == selectedSeasonNumber
        }) ?? model.item.seasons.first,
              let episodes = model.episodes[season.id] else { return nil }
        guard let episode = episodes.first(where: { !library.isWatched($0, in: model.item) })
            ?? episodes.first else { return nil }
        return PlaybackRequest(media: model.item, episode: episode)
    }

    private var primaryActionTitle: String {
        guard let progress = library.latestProgress(for: model.item) else { return "Play" }
        if model.item.kind == .movie { return progress.resumeLabel ?? "Play" }
        guard let episode = progress.episode else { return "Play" }
        return "S\(episode.seasonNumber) E\(episode.number) · \(progress.positionLabel)"
    }

    private func beginPlayback(_ request: PlaybackRequest) async {
        if let episode = request.episode,
           let season = model.item.seasons.first(where: { $0.number == episode.seasonNumber }),
           let episodes = model.episodes[season.id],
           episodes.last == episode,
           let seasonIndex = model.item.seasons.firstIndex(of: season),
           model.item.seasons.indices.contains(seasonIndex + 1) {
            await model.loadEpisodes(model.item.seasons[seasonIndex + 1], environment: environment)
        }
        guard !Task.isCancelled else { return }
        playback = request
    }

    private func markEpisodeAsWatched(_ request: PlaybackRequest) {
        let currentEpisode = library.latestProgress(for: request.media)?.episode
        let shouldAdvanceContinueWatching = currentEpisode.map {
            $0.id == request.episode?.id || (
                $0.seasonNumber == request.episode?.seasonNumber &&
                    $0.number == request.episode?.number
            )
        } ?? false
        library.markWatched(request: request)
        guard shouldAdvanceContinueWatching else { return }
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

    private func hasPreviousEpisodes(before episode: MediaEpisode) -> Bool {
        model.item.seasons.contains { $0.number < episode.seasonNumber }
            || model.episodes.values.joined().contains {
                $0.seasonNumber == episode.seasonNumber && $0.number < episode.number
            }
    }

    private func markPreviousEpisodesAsWatched(before episode: MediaEpisode) {
        Task {
            let relevantSeasons = model.item.seasons.filter { $0.number <= episode.seasonNumber }
            for season in relevantSeasons where model.episodes[season.id] == nil {
                await model.loadEpisodes(season, environment: environment)
            }
            guard !Task.isCancelled,
                  relevantSeasons.allSatisfy({ model.episodes[$0.id] != nil }) else { return }

            let previousEpisodes = relevantSeasons
                .flatMap { model.episodes[$0.id] ?? [] }
                .filter {
                    ($0.seasonNumber, $0.number) < (episode.seasonNumber, episode.number)
                }
            guard !previousEpisodes.isEmpty else { return }

            library.markPreviousEpisodesWatched(
                requests: previousEpisodes.map {
                    PlaybackRequest(media: model.item, episode: $0)
                },
                selectedRequest: PlaybackRequest(media: model.item, episode: episode)
            )
        }
    }
}

enum HeroArtworkScrollEffect {
    struct Metrics {
        let recessionProgress: CGFloat
        let scale: CGFloat
        let parallaxOffset: CGFloat
        let verticalOffset: CGFloat
        let opacity: Double
        let clipsToHeroBounds: Bool
    }

    static let homeCoordinateSpace = "home-hero-scroll"
    static let detailsCoordinateSpace = "details-hero-scroll"
    static let heroHeight: CGFloat = 690
    static let detailsContentOverlap: CGFloat = 274
    static let recessionDistance: CGFloat = 360
    static let disappearanceDistance: CGFloat = 500
    static let maximumDimming: Double = 0.64
    static let upwardParallaxCompensation: CGFloat = 0.35
    /// Reveal the compact sticky header once the in-content logo approaches the chrome.
    static let compactHeaderRevealDistance: CGFloat = 148

    static func metrics(minY: CGFloat, reduceMotion: Bool, heroHeight: CGFloat) -> Metrics {
        let upwardScroll = max(0, -minY)
        let overscroll = max(0, minY)
        let recessionProgress = min(upwardScroll / recessionDistance, 1)
        let disappearanceProgress = min(upwardScroll / disappearanceDistance, 1)
        let scale = reduceMotion
            ? 1
            : 1 + (overscroll / max(heroHeight, 1))

        return Metrics(
            recessionProgress: recessionProgress,
            scale: scale,
            parallaxOffset: reduceMotion ? 0 : upwardScroll * upwardParallaxCompensation,
            // Pin the artwork's top while its exact overscroll scale keeps the
            // bottom attached to the stretched hero instead of exposing a gap.
            verticalOffset: -overscroll,
            opacity: 1 - Double(disappearanceProgress),
            // Pull-down zoom needs to render above the hero's layout bounds.
            // During regular scrolling, restore the boundary so the artwork
            // cannot bleed behind the page's shelves or detail content.
            clipsToHeroBounds: overscroll == 0
        )
    }
}

private struct DetailsHeroScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct EpisodeInfoOverlay: View {
    let showTitle: String
    let episode: MediaEpisode
    let onDismiss: () -> Void

    private var synopsis: String {
        let value = episode.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "No episode synopsis is available." : value
    }

    var body: some View {
        ZStack {
            Button(action: onDismiss) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(.black.opacity(0.45))
                    .ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close episode info")

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(showTitle)
                            .font(.title2.bold())
                        Text("Season \(episode.seasonNumber) • Episode \(episode.number)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                }

                Text(episode.title ?? "Episode \(episode.number)")
                    .font(.headline)

                if let releaseDate = episode.formattedReleaseDate {
                    Label(releaseDate, systemImage: "calendar")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Text(synopsis)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            .padding(22)
            .frame(maxWidth: 520, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
            .padding(24)
            .onTapGesture { }
        }
        .zIndex(200)
    }
}

extension MediaEpisode {
    var formattedReleaseDate: String? {
        guard let releaseDate, !releaseDate.isEmpty else { return nil }
        let components = releaseDate.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3,
              let date = Calendar(identifier: .gregorian).date(
                from: DateComponents(year: components[0], month: components[1], day: components[2])
              ) else { return releaseDate }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
