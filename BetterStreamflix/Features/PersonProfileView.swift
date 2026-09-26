import SwiftUI

struct PersonProfileView: View {
    private enum FilmographyFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case movies = "Movies"
        case series = "TV"

        var id: String { rawValue }
    }

    let personID: Int
    let placeholderName: String
    let placeholderImageURL: URL?

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sourceLookup: SourceLookupCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var profile: PersonProfile?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedDetails: ResolvedMediaItem?
    @State private var showFullBiography = false
    @State private var filmographyFilter: FilmographyFilter = .all
    @State private var contentAppeared = false
    @State private var heroScrollMinY: CGFloat = 0

    private var displayName: String { profile?.name ?? placeholderName }

    private var showsCompactHeader: Bool {
        -heroScrollMinY > 96
    }

    private let actorCoordinateSpace = "actorProfileScroll"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                heroHeader
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ActorHeroScrollOffsetKey.self,
                                value: proxy.frame(in: .named(actorCoordinateSpace)).minY
                            )
                        }
                    }
                    .opacity(contentAppeared || profile == nil ? 1 : 0)
                    .offset(y: contentAppeared || profile == nil ? 0 : 12)

                if let profile {
                    if let biography = profile.biography, !biography.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        biographySection(biography)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if !profile.knownFor.isEmpty {
                        knownForSection(profile.knownFor)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if !profile.filmography.isEmpty {
                        filmographySection(profile.filmography)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else if profile.knownFor.isEmpty,
                              (profile.biography ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        emptyCatalogCard
                    }
                }
            }
            // Clear the tab bar + home indicator so filmography filters stay usable.
            .padding(.bottom, 108)
            .animation(reduceMotion ? nil : DesignTokens.Motion.soft, value: showFullBiography)
            .animation(reduceMotion ? nil : DesignTokens.Motion.soft, value: filmographyFilter)
            .animation(reduceMotion ? nil : DesignTokens.Motion.entrance, value: profile?.id)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .coordinateSpace(name: actorCoordinateSpace)
        .onPreferenceChange(ActorHeroScrollOffsetKey.self) { heroScrollMinY = $0 }
        .background { AppScreenBackground() }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.visible, for: .tabBar)
        .background {
            NavigationChromeStabilizer(enablesInteractivePop: true)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .top) {
            ScrollRevealChrome(
                showsCompactTitle: showsCompactHeader,
                reduceMotion: reduceMotion,
                onBack: { dismiss() }
            ) {
                Text(displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .overlay {
            if isLoading && profile == nil {
                loadingState
            }
        }
        .overlay {
            if !isLoading, profile == nil, let errorMessage {
                errorState(errorMessage)
            }
        }
        .navigationDestination(item: $selectedDetails) {
            DetailsView(item: $0.media, tmdbMetadata: $0.tmdbMetadata)
        }
        .task(id: personID) {
            await load()
        }
        .refreshable {
            await load()
        }
        .onChange(of: profile?.id) { _, _ in
            guard !reduceMotion else {
                contentAppeared = true
                return
            }
            contentAppeared = false
            withAnimation(DesignTokens.Motion.entrance) {
                contentAppeared = true
            }
        }
    }

    // MARK: - Hero

    private var heroHeader: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            CachedRemoteImage(url: profile?.profileURL ?? placeholderImageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(AppTheme.elevatedSurface)
                    .overlay {
                        Text(String(displayName.prefix(1)))
                            .font(.system(size: 42, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 128, height: 172)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.4), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 12) {
                Text(displayName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppTheme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                    .opacity(showsCompactHeader ? 0 : 1)
                    .accessibilityHidden(showsCompactHeader)

                if let department = profile?.knownForDepartment, !department.isEmpty {
                    Text(department)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(environment.theme.accentBright)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .glassEffectWithFallback(in: Capsule())
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let birthday = profile?.birthday, !birthday.isEmpty {
                        Label(birthday, systemImage: "calendar")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    if let place = profile?.placeOfBirth, !place.isEmpty {
                        Label(place, systemImage: "mappin.and.ellipse")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                if let profile {
                    HStack(spacing: 10) {
                        if let popularity = profile.popularity, popularity > 0 {
                            equalMetaPill(
                                value: Self.compactPopularity(popularity),
                                label: "Fans",
                                systemImage: "heart.fill"
                            )
                        } else if !profile.knownFor.isEmpty {
                            equalMetaPill(
                                value: "\(profile.knownFor.count)",
                                label: "Known",
                                systemImage: "star.fill"
                            )
                        }
                        if !profile.filmography.isEmpty {
                            equalMetaPill(
                                value: "\(profile.filmography.count)",
                                label: "Credits",
                                systemImage: "film.stack"
                            )
                        }
                    }
                } else if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(environment.theme.accentBright)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
        .padding(.top, ScreenMetrics.topSafeAreaInset + 52)
    }

    /// Fixed equal circles so Fans and Credits never mismatch in size.
    private func equalMetaPill(value: String, label: String, systemImage: String) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(AppTheme.elevatedSurface)
                Circle()
                    .stroke(.white.opacity(0.12), lineWidth: 0.8)
                VStack(spacing: 2) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(environment.theme.accentBright)
                    Text(value)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(width: 64, height: 64)

            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 72)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }

    private static func compactPopularity(_ value: Double) -> String {
        if value >= 1000 {
            return String(format: "%.1fk", value / 1000)
        }
        if value >= 100 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    // MARK: - Biography

    private func biographySection(_ biography: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Biography")
            Text(biography)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(showFullBiography ? nil : 5)
                .frame(maxWidth: .infinity, alignment: .leading)
            if biography.count > 280 {
                Button(showFullBiography ? "Show less" : "Read more") {
                    withAnimation(DesignTokens.Motion.soft) {
                        showFullBiography.toggle()
                    }
                }
                .font(.subheadline.weight(.semibold))
                .tint(environment.theme.accentBright)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffectWithFallback(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
    }

    // MARK: - Known For

    private func knownForSection(_ titles: [TrendingTitle]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Known For", count: titles.count)
                .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(titles) { title in
                        Button {
                            open(title)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack(alignment: .bottomLeading) {
                                    CachedRemoteImage(url: title.posterURL) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        RoundedRectangle(
                                            cornerRadius: DesignTokens.Radius.poster,
                                            style: .continuous
                                        )
                                        .fill(AppTheme.elevatedSurface)
                                    }
                                    .frame(
                                        width: MediaArtworkLayout.shelfPosterWidth,
                                        height: MediaArtworkLayout.shelfPosterWidth * 1.5
                                    )
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: DesignTokens.Radius.poster,
                                            style: .continuous
                                        )
                                    )
                                    .overlay {
                                        RoundedRectangle(
                                            cornerRadius: DesignTokens.Radius.poster,
                                            style: .continuous
                                        )
                                        .stroke(.white.opacity(0.1), lineWidth: 0.8)
                                    }

                                    LinearGradient(
                                        colors: [.clear, .black.opacity(0.55)],
                                        startPoint: .center,
                                        endPoint: .bottom
                                    )
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: DesignTokens.Radius.poster,
                                            style: .continuous
                                        )
                                    )

                                    if let year = title.releaseDate.map({ String($0.prefix(4)) }),
                                       year.count == 4 {
                                        Text(year)
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(.black.opacity(0.62), in: Capsule())
                                            .padding(8)
                                    }
                                }
                                Text(title.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.primaryText)
                                    .lineLimit(2)
                                    .frame(
                                        width: MediaArtworkLayout.shelfPosterWidth,
                                        alignment: .leading
                                    )
                                Text(title.kind == .movie ? "Movie" : "Series")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .pressablePoster()
                        .accessibilityLabel("\(title.title), \(title.kind == .movie ? "movie" : "series")")
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
            }
        }
    }

    // MARK: - Filmography

    private func filmographySection(_ credits: [PersonCredit]) -> some View {
        let filtered = filteredFilmography(credits)
        return VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Filmography", count: credits.count)
                .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)

            Picker("Filter", selection: $filmographyFilter) {
                ForEach(FilmographyFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)

            if filtered.isEmpty {
                Text("No \(filmographyFilter.rawValue.lowercased()) credits in this list.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(filtered) { credit in
                        filmographyRow(credit)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
            }
        }
    }

    private func filteredFilmography(_ credits: [PersonCredit]) -> [PersonCredit] {
        switch filmographyFilter {
        case .all: credits
        case .movies: credits.filter { $0.kind == .movie }
        case .series: credits.filter { $0.kind == .series }
        }
    }

    private func filmographyRow(_ credit: PersonCredit) -> some View {
        let resolving = sourceLookup.activeKeys.contains(credit.asTrendingTitle.lookupKey)
        return Button {
            DesignTokens.Haptics.selection()
            open(credit.asTrendingTitle)
        } label: {
            HStack(spacing: 12) {
                CachedRemoteImage(url: credit.posterURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppTheme.elevatedSurface)
                }
                .frame(width: 52, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(credit.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(credit.kind == .movie ? "Movie" : "TV")
                        if let year = credit.year {
                            Text("·")
                            Text(year)
                        }
                        if let rating = credit.rating, rating > 0 {
                            Text("·")
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    if let role = credit.character ?? credit.job, !role.isEmpty {
                        Text(role)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if resolving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(11)
            .glassEffectWithFallback(
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(resolving)
        .accessibilityHint("Opens title details")
    }

    // MARK: - Shared chrome bits

    private func sectionHeader(_ title: String, count: Int? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(DesignTokens.Typography.shelfTitle)
                .foregroundStyle(AppTheme.primaryText)
            if let count {
                Text("\(count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(AppTheme.elevatedSurface, in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyCatalogCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("No catalog credits yet")
                .font(.headline.weight(.semibold))
            Text("TMDB didn’t return known-for or filmography rows for this person.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .glassEffectWithFallback(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, DesignTokens.Spacing.screenHorizontal)
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Loading profile…")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .glassEffectWithFallback(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading profile")
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load profile", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") {
                Task { await load() }
            }
            .buttonStyle(.borderedProminent)
            .tint(environment.theme.accent)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Actions

    private func open(_ title: TrendingTitle) {
        DesignTokens.Haptics.selection()
        selectedDetails = ResolvedMediaItem(
            media: .tmdbCatalogItem(from: title),
            tmdbMetadata: title
        )
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            profile = try await environment.tmdbPersonProfile(id: personID)
        } catch {
            if profile == nil {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }
}

private struct ActorHeroScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
