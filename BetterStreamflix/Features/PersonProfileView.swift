import SwiftUI

struct PersonProfileView: View {
    let personID: Int
    let placeholderName: String
    let placeholderImageURL: URL?

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var sourceLookup: SourceLookupCoordinator
    @State private var profile: PersonProfile?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedDetails: ResolvedMediaItem?
    @State private var showFullBiography = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if let biography = profile?.biography, !biography.isEmpty {
                    biographySection(biography)
                }

                if let knownFor = profile?.knownFor, !knownFor.isEmpty {
                    knownForSection(knownFor)
                }

                if let filmography = profile?.filmography, !filmography.isEmpty {
                    filmographySection(filmography)
                }
            }
            .padding(.bottom, 36)
        }
        .background { AppScreenBackground() }
        .navigationTitle(profile?.name ?? placeholderName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar(.visible, for: .tabBar)
        .background {
            NavigationChromeStabilizer(enablesInteractivePop: true)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay {
            if isLoading && profile == nil {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .overlay {
            if !isLoading, profile == nil, let errorMessage {
                ContentUnavailableView(
                    "Couldn't load profile",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text(errorMessage)
                )
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
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CachedRemoteImage(url: profile?.profileURL ?? placeholderImageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(AppTheme.elevatedSurface)
                    .overlay {
                        Text(String((profile?.name ?? placeholderName).prefix(1)))
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 120, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 8) {
                Text(profile?.name ?? placeholderName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppTheme.primaryText)
                if let department = profile?.knownForDepartment {
                    Text(department)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(environment.theme.accentBright)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffectWithFallback(in: Capsule())
                }
                if let birthday = profile?.birthday {
                    Label(birthday, systemImage: "calendar")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if let place = profile?.placeOfBirth {
                    Label(place, systemImage: "mappin.and.ellipse")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func biographySection(_ biography: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Biography")
                .font(DesignTokens.Typography.shelfTitle)
            Text(biography)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(showFullBiography ? nil : 5)
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
        .padding(.horizontal, 20)
    }

    private func knownForSection(_ titles: [TrendingTitle]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Known For")
                .font(DesignTokens.Typography.shelfTitle)
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(titles) { title in
                        Button {
                            open(title)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                CachedRemoteImage(url: title.posterURL) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: DesignTokens.Radius.poster, style: .continuous)
                                        .fill(AppTheme.elevatedSurface)
                                }
                                .frame(width: MediaArtworkLayout.shelfPosterWidth, height: MediaArtworkLayout.shelfPosterWidth * 1.5)
                                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.poster, style: .continuous))
                                Text(title.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.primaryText)
                                    .lineLimit(2)
                                    .frame(width: MediaArtworkLayout.shelfPosterWidth, alignment: .leading)
                            }
                        }
                        .pressablePoster()
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func filmographySection(_ credits: [PersonCredit]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filmography")
                .font(DesignTokens.Typography.shelfTitle)
                .padding(.horizontal, 20)

            LazyVStack(spacing: 10) {
                ForEach(credits) { credit in
                    Button {
                        open(credit.asTrendingTitle)
                    } label: {
                        HStack(spacing: 12) {
                            CachedRemoteImage(url: credit.posterURL) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(AppTheme.elevatedSurface)
                            }
                            .frame(width: 48, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(credit.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.primaryText)
                                    .multilineTextAlignment(.leading)
                                HStack(spacing: 6) {
                                    Text(credit.kind == .movie ? "Movie" : "TV")
                                    if let year = credit.year {
                                        Text("·")
                                        Text(year)
                                    }
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                if let role = credit.character ?? credit.job {
                                    Text(role)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .glassEffectWithFallback(
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func open(_ title: TrendingTitle) {
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
