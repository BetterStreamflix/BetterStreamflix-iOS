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
    @State private var providerDomainDraft = ""
    @State private var providerDomainError: String?
    @State private var playbackToggles: [PlaybackSourcePreferenceID: Bool] = [:]
    @State private var selectedLanguage: ProviderLanguageGroup = AppSetupStore.activePlaybackLanguageGroup
    @State private var coreEnabled = AppSetupStore.isCoreResolversEnabled
    @State private var showAdvanced = false
    @State private var languageConfirmation: String?

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

            if let languageConfirmation {
                VStack {
                    Spacer()
                    Text(languageConfirmation)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 88)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            providerDomainDraft = environment.providerDomain
            selectedLanguage = AppSetupStore.activePlaybackLanguageGroup
            coreEnabled = AppSetupStore.isCoreResolversEnabled
            refreshPlaybackToggles()
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
                Text("Browsing uses TMDB. Pick one playback language — the player only uses that language’s sources.")
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

                PlaybackLanguagePickerGrid(
                    selected: selectedLanguage,
                    onSelect: { selectLanguage($0) }
                )

                PlaybackCoreResolversToggle(
                    isOn: $coreEnabled,
                    domainDraft: $providerDomainDraft,
                    domainError: providerDomainError,
                    onChanged: { enabled in
                        coreEnabled = enabled
                        AppSetupStore.setCoreResolversEnabled(enabled)
                        refreshPlaybackToggles()
                        DesignTokens.Haptics.selection()
                    }
                )

                DisclosureGroup(isExpanded: $showAdvanced) {
                    Text("Fine-tune providers inside \(selectedLanguage.title). Other languages stay off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(PlaybackSourcePreferenceID.sources(in: selectedLanguage)) { source in
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
                    if coreEnabled {
                        ForEach(PlaybackSourcePreferenceID.sources(in: .core)) { source in
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
                } label: {
                    Text("Advanced")
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
            get: { playbackToggles[source] ?? AppSetupStore.isPlaybackSourceEnabled(source) },
            set: { playbackToggles[source] = $0 }
        )
    }

    private func selectLanguage(_ group: ProviderLanguageGroup) {
        guard group.isSpokenLanguage else { return }
        selectedLanguage = group
        AppSetupStore.setActivePlaybackLanguageGroup(group)
        refreshPlaybackToggles()
        DesignTokens.Haptics.primaryAction()
        presentLanguageConfirmation(group.confirmationMessage)
    }

    private func refreshPlaybackToggles() {
        playbackToggles = Dictionary(
            uniqueKeysWithValues: PlaybackSourcePreferenceID.allCases.map {
                ($0, AppSetupStore.isPlaybackSourceEnabled($0))
            }
        )
    }

    private func presentLanguageConfirmation(_ message: String) {
        withAnimation(reduceMotion ? nil : DesignTokens.Motion.toast) {
            languageConfirmation = message
        }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(reduceMotion ? nil : DesignTokens.Motion.toast) {
                if languageConfirmation == message {
                    languageConfirmation = nil
                }
            }
        }
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
        AppSetupStore.setActivePlaybackLanguageGroup(selectedLanguage)
        AppSetupStore.setCoreResolversEnabled(coreEnabled)
        for source in AppSetupStore.allowedPreferenceIDs() {
            AppSetupStore.setPlaybackSource(
                source,
                enabled: playbackToggles[source] ?? true
            )
        }
        do {
            try await environment.applyProviderDomain(providerDomainDraft)
            providerDomainError = nil
        } catch {
            providerDomainError = "Enter a valid hostname like streamingunity.win"
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var providerDomainDraft = ""
    @State private var providerDomainError: String?
    @State private var showSetup = false
    @State private var playbackToggles: [PlaybackSourcePreferenceID: Bool] = [:]
    @State private var selectedLanguage: ProviderLanguageGroup = AppSetupStore.activePlaybackLanguageGroup
    @State private var coreEnabled = AppSetupStore.isCoreResolversEnabled
    @State private var showAdvanced = false
    @State private var languageConfirmation: String?

    var body: some View {
        Group {
            Section("Catalog & Providers") {
                LabeledContent("Main catalog") {
                    Text(AppSetupStore.catalogSource.title)
                        .foregroundStyle(.secondary)
                }
                Text("Pick one playback language. The player only uses that language’s sources. TMDB browsing stays independent.")
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

            Section {
                PlaybackLanguagePickerGrid(
                    selected: selectedLanguage,
                    onSelect: { selectLanguage($0) },
                    compact: true
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)

                if let languageConfirmation {
                    Text(languageConfirmation)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(environment.theme.accentBright)
                }
            } header: {
                Text("Playback language")
            } footer: {
                Text("Choosing a language enables every provider in that group and disables the others.")
            }

            Section {
                Toggle(isOn: coreBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Core / Anime & Stremio")
                        Text("StreamingCommunity, HiAnime, Anikoto, AnimeIL, and Stremio. Off by default.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(environment.theme.accent)
            } header: {
                Text("Optional core")
            }

            Section {
                DisclosureGroup(isExpanded: $showAdvanced) {
                    ForEach(PlaybackSourcePreferenceID.sources(in: selectedLanguage)) { source in
                        providerToggle(source)
                    }
                    if coreEnabled {
                        ForEach(PlaybackSourcePreferenceID.sources(in: .core)) { source in
                            providerToggle(source)
                        }
                    }
                } label: {
                    Text("Advanced · \(selectedLanguage.title)")
                }
            } footer: {
                Text("Advanced toggles apply only within the active language\(coreEnabled ? " and Core" : "").")
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
            selectedLanguage = AppSetupStore.activePlaybackLanguageGroup
            coreEnabled = AppSetupStore.isCoreResolversEnabled
            refreshPlaybackToggles()
        }
        .sheet(isPresented: $showSetup) {
            FirstLaunchSetupView(onFinished: { showSetup = false }, allowsSkip: true)
                .environmentObject(environment)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var coreBinding: Binding<Bool> {
        Binding(
            get: { coreEnabled },
            set: { enabled in
                coreEnabled = enabled
                AppSetupStore.setCoreResolversEnabled(enabled)
                refreshPlaybackToggles()
                DesignTokens.Haptics.selection()
            }
        )
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

    private func selectLanguage(_ group: ProviderLanguageGroup) {
        guard group.isSpokenLanguage else { return }
        selectedLanguage = group
        AppSetupStore.setActivePlaybackLanguageGroup(group)
        refreshPlaybackToggles()
        DesignTokens.Haptics.primaryAction()
        withAnimation(reduceMotion ? nil : DesignTokens.Motion.toast) {
            languageConfirmation = group.confirmationMessage
        }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(reduceMotion ? nil : DesignTokens.Motion.toast) {
                if languageConfirmation == group.confirmationMessage {
                    languageConfirmation = nil
                }
            }
        }
    }

    private func refreshPlaybackToggles() {
        playbackToggles = Dictionary(
            uniqueKeysWithValues: PlaybackSourcePreferenceID.allCases.map {
                ($0, AppSetupStore.isPlaybackSourceEnabled($0))
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

struct PlaybackLanguagePickerGrid: View {
    @EnvironmentObject private var environment: AppEnvironment

    let selected: ProviderLanguageGroup
    let onSelect: (ProviderLanguageGroup) -> Void
    var compact: Bool = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(ProviderLanguageGroup.spokenLanguages) { group in
                Button {
                    onSelect(group)
                } label: {
                    VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(group.flagEmoji)
                                .font(compact ? .title3 : .title2)
                            Spacer(minLength: 0)
                            if selected == group {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(environment.theme.accentBright)
                            }
                        }
                        Text(group.title)
                            .font((compact ? Font.subheadline : Font.headline).weight(.semibold))
                            .foregroundStyle(AppTheme.primaryText)
                        Text("\(group.providerCount) providers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(compact ? 12 : 14)
                    .frame(maxWidth: .infinity, minHeight: compact ? 88 : 108, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(selected == group ? environment.theme.accent.opacity(0.18) : AppTheme.elevatedSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                selected == group ? environment.theme.accentBright.opacity(0.9) : Color.clear,
                                lineWidth: 1.5
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected == group ? .isSelected : [])
                .accessibilityLabel("\(group.title), \(group.providerCount) providers")
            }
        }
    }
}

struct PlaybackCoreResolversToggle: View {
    @EnvironmentObject private var environment: AppEnvironment

    @Binding var isOn: Bool
    @Binding var domainDraft: String
    var domainError: String?
    var onChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { isOn },
                set: { onChanged($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Core / Anime & Stremio")
                        .font(.headline.weight(.semibold))
                    Text("Optional add-on. Off by default so Deutsch means German VOD only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(environment.theme.accent)

            if isOn {
                Text("StreamingCommunity domain")
                    .font(.subheadline.weight(.semibold))
                TextField("streamingunity.win", text: $domainDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12))
                if let domainError {
                    Text(domainError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffectWithFallback(
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}
