import SwiftUI

enum CatalogSourcePreference: String, CaseIterable, Identifiable {
    case tmdb

    var id: String { rawValue }

    var title: String { "TMDB" }

    var subtitle: String {
        "Movies and series discovery, artwork, and metadata."
    }
}

struct FirstLaunchSetupView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onFinished: () -> Void
    var allowsSkip: Bool = false

    @State private var step = 0
    @AppStorage("player.orientation") private var playerOrientationRawValue =
        PlayerOrientationPreference.autoRotate.rawValue
    @AppStorage("player.subtitleLanguage.primary") private var primarySubtitleLanguage = "en"
    @AppStorage("player.audioLanguage") private var audioLanguage = "en"
    @AppStorage("player.animeAudioLanguage") private var animeAudioLanguage = "en"
    @State private var showAdvancedProviders = false
    @State private var providerDomainDraft = ""
    @State private var providerDomainError: String?
    @State private var playbackToggles: [PlaybackSourcePreferenceID: Bool] = [:]

    private let totalSteps = 3

    var body: some View {
        ZStack {
            AppScreenBackground()

            VStack(spacing: 0) {
                HStack {
                    if allowsSkip {
                        Button("Close") { onFinished() }
                            .font(.subheadline.weight(.semibold))
                    } else {
                        Color.clear.frame(width: 48, height: 1)
                    }
                    Spacer()
                    Text("Setup")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(step + 1)/\(totalSteps)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(environment.theme.accentBright)
                        .frame(width: 48, alignment: .trailing)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)

                TabView(selection: $step) {
                    welcomeStep.tag(0)
                    preferencesStep.tag(1)
                    providersStep.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(reduceMotion ? nil : DesignTokens.Motion.soft, value: step)

                bottomBar
            }
        }
        .onAppear {
            providerDomainDraft = environment.providerDomain
            playbackToggles = Dictionary(
                uniqueKeysWithValues: PlaybackSourcePreferenceID.allCases.map {
                    ($0, AppSetupStore.isPlaybackSourceEnabled($0))
                }
            )
        }
    }

    private var welcomeStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)

                Text("Welcome to BetterStreamflix")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.primaryText)

                Text("Pick your look, playback defaults, and catalog source. You can change everything later in Settings.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Theme")
                        .font(.headline.weight(.semibold))
                    AppThemePicker(selection: $environment.theme)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffectWithFallback(
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
            }
            .padding(22)
        }
    }

    private var preferencesStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Playback preferences")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("These apply the first time you press Play. Title-specific choices still win later.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 14) {
                    Picker("Player orientation", selection: playerOrientation) {
                        ForEach(PlayerOrientationPreference.allCases) { option in
                            Text(option.name).tag(option)
                        }
                    }
                    .pickerStyle(.inline)

                    Picker("Default audio", selection: $audioLanguage) {
                        ForEach(PlaybackLanguages.options) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                    Picker("Default subtitles", selection: $primarySubtitleLanguage) {
                        ForEach(PlaybackLanguages.options) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                    Picker("Anime audio", selection: $animeAudioLanguage) {
                        Text("English").tag("en")
                        Text("Japanese").tag("ja")
                        Text("Hebrew").tag("he")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffectWithFallback(
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
            }
            .padding(22)
            .tint(environment.theme.accent)
        }
    }

    private var providersStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Catalog & sources")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Browsing uses TMDB. German sources are first-class for playback — same as Android BetterStreamflix.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Main catalog")
                        .font(.headline.weight(.semibold))
                    ForEach(CatalogSourcePreference.allCases) { source in
                        catalogSourceRow(source)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffectWithFallback(
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )

                providerGroupCard(
                    title: "German sources",
                    caption: "Enabled by default. SerienStream, AniWorld, FilmPalast, and the full DE set.",
                    sources: PlaybackSourcePreferenceID.sources(in: .german)
                )

                providerGroupCard(
                    title: "Core resolvers",
                    caption: "StreamingCommunity, anime resolvers, and Stremio addons.",
                    sources: PlaybackSourcePreferenceID.sources(in: .core),
                    includeDomainField: true
                )

                DisclosureGroup(isExpanded: $showAdvancedProviders) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(
                            [ProviderLanguageGroup.english, .italian, .spanish, .french, .polish],
                            id: \.self
                        ) { group in
                            providerGroupCard(
                                title: group.title,
                                caption: nil,
                                sources: PlaybackSourcePreferenceID.sources(in: group),
                                compact: true
                            )
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    Label("Other languages", systemImage: "globe")
                        .font(.headline.weight(.semibold))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffectWithFallback(
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
            }
            .padding(22)
        }
    }

    @ViewBuilder
    private func providerGroupCard(
        title: String,
        caption: String?,
        sources: [PlaybackSourcePreferenceID],
        includeDomainField: Bool = false,
        compact: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            Text(title)
                .font(.headline.weight(.semibold))
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if includeDomainField {
                Text("StreamingCommunity domain")
                    .font(.subheadline.weight(.semibold))
                TextField("streamingunity.win", text: $providerDomainDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12))
                if let providerDomainError {
                    Text(providerDomainError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            ForEach(sources) { source in
                Toggle(isOn: playbackBinding(for: source)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.title)
                            .font(.subheadline.weight(.semibold))
                        Text(source.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(environment.theme.accent)
            }
        }
        .padding(compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffectWithFallback(
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button("Back") {
                    withAnimation(reduceMotion ? nil : DesignTokens.Motion.soft) {
                        step -= 1
                    }
                }
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .glassEffectWithFallback(in: Capsule())
            }

            Button(step == totalSteps - 1 ? "Get started" : "Continue") {
                Task { await advance() }
            }
            .buttonStyle(AppPrimaryButtonStyle(glow: environment.theme.glow, minHeight: 48))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
    }

    private func catalogSourceRow(_ source: CatalogSourcePreference) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(environment.theme.accentBright)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(.headline.weight(.semibold))
                Text(source.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Selected")
                .font(.caption.weight(.bold))
                .foregroundStyle(environment.theme.accentBright)
        }
        .padding(12)
        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityAddTraits(.isSelected)
    }

    private var playerOrientation: Binding<PlayerOrientationPreference> {
        Binding(
            get: {
                PlayerOrientationPreference(rawValue: playerOrientationRawValue) ?? .autoRotate
            },
            set: { playerOrientationRawValue = $0.rawValue }
        )
    }

    private func playbackBinding(for source: PlaybackSourcePreferenceID) -> Binding<Bool> {
        Binding(
            get: { playbackToggles[source] ?? source.defaultEnabled },
            set: { playbackToggles[source] = $0 }
        )
    }

    private func advance() async {
        if step < totalSteps - 1 {
            withAnimation(reduceMotion ? nil : DesignTokens.Motion.soft) {
                step += 1
            }
            return
        }
        await finish()
    }

    private func finish() async {
        AppSetupStore.catalogSource = .tmdb
        for source in PlaybackSourcePreferenceID.allCases {
            AppSetupStore.setPlaybackSource(
                source,
                enabled: playbackToggles[source] ?? source.defaultEnabled
            )
        }
        do {
            try await environment.applyProviderDomain(providerDomainDraft)
            providerDomainError = nil
        } catch {
            providerDomainError = "Enter a valid hostname like streamingunity.win"
            showAdvancedProviders = true
            return
        }
        AppSetupStore.isCompleted = true
        DesignTokens.Haptics.primaryAction()
        onFinished()
    }
}

/// Compact providers panel reused from Settings after first launch.
struct ProvidersSettingsSection: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var providerDomainDraft = ""
    @State private var providerDomainError: String?
    @State private var showSetup = false
    @State private var playbackToggles: [PlaybackSourcePreferenceID: Bool] = [:]

    var body: some View {
        Group {
            Section("Catalog & Providers") {
                LabeledContent("Main catalog") {
                    Text(AppSetupStore.catalogSource.title)
                        .foregroundStyle(.secondary)
                }
                Text("Browsing uses TMDB. German playback sources are first-class; other languages are optional.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("StreamingCommunity domain", text: $providerDomainDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await saveDomain() } }

                Button("Apply domain") {
                    Task { await saveDomain() }
                }
                if let providerDomainError {
                    Text(providerDomainError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("German sources") {
                ForEach(PlaybackSourcePreferenceID.sources(in: .german)) { source in
                    providerToggle(source)
                }
            }

            Section("Core resolvers") {
                ForEach(PlaybackSourcePreferenceID.sources(in: .core)) { source in
                    providerToggle(source)
                }
            }

            ForEach(
                [ProviderLanguageGroup.english, .italian, .spanish, .french, .polish],
                id: \.self
            ) { group in
                Section(group.title) {
                    ForEach(PlaybackSourcePreferenceID.sources(in: group)) { source in
                        providerToggle(source)
                    }
                }
            }

            Section {
                Button {
                    showSetup = true
                } label: {
                    Label("Open setup guide", systemImage: "sparkles")
                }
            }
        }
        .listRowBackground(AppTheme.surface)
        .onAppear {
            providerDomainDraft = environment.providerDomain
            playbackToggles = Dictionary(
                uniqueKeysWithValues: PlaybackSourcePreferenceID.allCases.map {
                    ($0, AppSetupStore.isPlaybackSourceEnabled($0))
                }
            )
        }
        .sheet(isPresented: $showSetup) {
            FirstLaunchSetupView(onFinished: { showSetup = false }, allowsSkip: true)
                .environmentObject(environment)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func providerToggle(_ source: PlaybackSourcePreferenceID) -> some View {
        Toggle(isOn: playbackBinding(for: source)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                Text(source.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(environment.theme.accent)
    }

    private func playbackBinding(for source: PlaybackSourcePreferenceID) -> Binding<Bool> {
        Binding(
            get: { playbackToggles[source] ?? AppSetupStore.isPlaybackSourceEnabled(source) },
            set: {
                playbackToggles[source] = $0
                AppSetupStore.setPlaybackSource(source, enabled: $0)
            }
        )
    }

    private func saveDomain() async {
        do {
            try await environment.applyProviderDomain(providerDomainDraft)
            providerDomainError = nil
            DesignTokens.Haptics.selection()
        } catch {
            providerDomainError = "Enter a valid hostname like streamingunity.win"
        }
    }
}
