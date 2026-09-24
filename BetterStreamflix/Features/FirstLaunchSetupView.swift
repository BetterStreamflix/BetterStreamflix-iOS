import SwiftUI

enum CatalogSourcePreference: String, CaseIterable, Identifiable {
    case tmdb

    var id: String { rawValue }

    var title: String { "TMDB" }

    var subtitle: String {
        "Movies and series discovery, artwork, and metadata."
    }
}

enum PlaybackSourcePreferenceID: String, CaseIterable, Identifiable {
    case streamingCommunity
    case hiAnime
    case anikoto
    case animeIL
    case stremio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .streamingCommunity: "StreamingCommunity"
        case .hiAnime: "HiAnime"
        case .anikoto: "Anikoto"
        case .animeIL: "AnimeIL"
        case .stremio: "Stremio"
        }
    }

    var subtitle: String {
        switch self {
        case .streamingCommunity: "Primary stream resolver for most titles"
        case .hiAnime: "Anime playback (English / Japanese)"
        case .anikoto: "Alternate anime resolver"
        case .animeIL: "Hebrew anime streams"
        case .stremio: "Addon-backed streams and extras"
        }
    }

    var defaultsKey: String { "playback.provider.\(rawValue).enabled" }

    var defaultEnabled: Bool { true }

    /// Matches provider type filtering in `ProviderRegistry.playbackProviders`.
    var registryMatchIDs: [String] {
        switch self {
        case .streamingCommunity: ["streamingcommunity"]
        case .hiAnime: ["hianime"]
        case .anikoto: ["anikoto"]
        case .animeIL: ["animeil"]
        case .stremio: ["external-streams", "stremio"]
        }
    }

    func matches(providerID: String) -> Bool {
        let lowered = providerID.lowercased()
        return registryMatchIDs.contains { lowered.contains($0) }
    }
}

enum AppSetupStore {
    static let completedKey = "setup.completed"
    static let catalogSourceKey = "catalog.source"

    static var isCompleted: Bool {
        get {
            if UserDefaults.standard.object(forKey: completedKey) != nil {
                return UserDefaults.standard.bool(forKey: completedKey)
            }
            // Existing installs from earlier builds skip onboarding once.
            let looksLikeReturningUser =
                UserDefaults.standard.object(forKey: "appearance.themeColor") != nil
                || UserDefaults.standard.object(forKey: "provider.streamingcommunity.domain") != nil
                || UserDefaults.standard.object(forKey: "player.autoNext") != nil
            if looksLikeReturningUser {
                UserDefaults.standard.set(true, forKey: completedKey)
                return true
            }
            return false
        }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }

    static var catalogSource: CatalogSourcePreference {
        get {
            CatalogSourcePreference(
                rawValue: UserDefaults.standard.string(forKey: catalogSourceKey) ?? ""
            ) ?? .tmdb
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: catalogSourceKey) }
    }

    static func isPlaybackSourceEnabled(_ source: PlaybackSourcePreferenceID) -> Bool {
        if UserDefaults.standard.object(forKey: source.defaultsKey) == nil {
            return source.defaultEnabled
        }
        return UserDefaults.standard.bool(forKey: source.defaultsKey)
    }

    static func setPlaybackSource(_ source: PlaybackSourcePreferenceID, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: source.defaultsKey)
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
                Text("Browsing uses TMDB. Advanced sources power stream resolution when you play.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Languages / main catalog")
                        .font(.headline.weight(.semibold))
                    ForEach(CatalogSourcePreference.allCases) { source in
                        catalogSourceRow(source)
                    }
                    Text("Only TMDB is available on the main path. Additional catalog providers are not offered here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffectWithFallback(
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )

                DisclosureGroup(isExpanded: $showAdvancedProviders) {
                    VStack(alignment: .leading, spacing: 14) {
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

                        ForEach(PlaybackSourcePreferenceID.allCases) { source in
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
                    .padding(.top, 10)
                } label: {
                    Label("Advanced providers", systemImage: "slider.horizontal.3")
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
        Section("Catalog & Providers") {
            LabeledContent("Main catalog") {
                Text(AppSetupStore.catalogSource.title)
                    .foregroundStyle(.secondary)
            }
            Text("Languages and browsing use TMDB only. Playback sources below can be toggled independently.")
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

            ForEach(PlaybackSourcePreferenceID.allCases) { source in
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

            Button {
                showSetup = true
            } label: {
                Label("Open setup guide", systemImage: "sparkles")
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
