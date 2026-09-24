import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AppThemePicker: View {
    @Binding var selection: AppTheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(AppTheme.allCases) { theme in
                        Button {
                            selection = theme
                            UISelectionFeedbackGenerator().selectionChanged()
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 0) {
                                    Circle()
                                        .fill(theme.accent)
                                        .frame(width: 28, height: 28)
                                    Circle()
                                        .fill(theme.accentBright)
                                        .frame(width: 28, height: 28)
                                        .offset(x: -7)
                                    Spacer(minLength: 2)
                                    if selection == theme {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(theme.accentBright, theme.accent)
                                    }
                                }

                                Text(theme.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.primaryText)
                                    .lineLimit(1)
                            }
                            .padding(12)
                            .frame(width: 126, alignment: .leading)
                            .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 15))
                            .overlay {
                                RoundedRectangle(cornerRadius: 15)
                                    .stroke(
                                        selection == theme ? theme.accentBright.opacity(0.9) : AppTheme.border,
                                        lineWidth: selection == theme ? 1.5 : 1
                                    )
                            }
                            .shadow(
                                color: selection == theme ? theme.glow.opacity(0.4) : .clear,
                                radius: 9,
                                y: 3
                            )
                        }
                        .buttonStyle(.plain)
                        .id(theme.id)
                        .accessibilityLabel(theme.name)
                        .accessibilityValue(selection == theme ? "Selected" : "")
                        .accessibilityAddTraits(selection == theme ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }
            .onAppear {
                proxy.scrollTo(selection.id, anchor: anchor(for: selection))
            }
            .onChange(of: selection) { _, selectedTheme in
                withAnimation(.smooth) {
                    proxy.scrollTo(selectedTheme.id, anchor: anchor(for: selectedTheme))
                }
            }
        }
        .scrollClipDisabled()
    }

    private func anchor(for theme: AppTheme) -> UnitPoint {
        let themes = AppTheme.allCases
        guard themes.count > 1, let index = themes.firstIndex(of: theme) else {
            return .center
        }
        return UnitPoint(x: CGFloat(index) / CGFloat(themes.count - 1), y: 0.5)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @AppStorage("player.autoNext") private var autoNext = true
    @AppStorage("player.defaultQualityHeight") private var defaultQualityHeight = 0
    @AppStorage("player.defaultPlaybackRate") private var defaultPlaybackRate = 1.0
    @AppStorage("player.orientation") private var playerOrientationRawValue = PlayerOrientationPreference.autoRotate.rawValue
    @AppStorage("player.subtitleLanguage.primary") private var primarySubtitleLanguage = "en"
    @AppStorage("player.subtitleLanguage.secondary") private var secondarySubtitleLanguage = ""
    @AppStorage("player.audioLanguage") private var audioLanguage = "en"
    @AppStorage("player.animeAudioLanguage") private var animeAudioLanguage = "en"
    @AppStorage("player.animeBackupAudioLanguage") private var animeBackupAudioLanguage = "ja"
    @AppStorage("player.subtitlesEnabledByDefault") private var subtitlesEnabledByDefault = true
    @AppStorage("player.subtitleLoadingMode")
    private var subtitleLoadingModeRawValue = SubtitleLoadingMode.fast.rawValue
    @AppStorage("subtitle.provider.subdl.enabled")
    private var subDLSubtitlesEnabled = true

    @AppStorage("subtitle.provider.wizdom.enabled")
    private var wizdomSubtitlesEnabled = true

    @AppStorage("subtitle.provider.ktuvit.enabled")
    private var ktuvitSubtitlesEnabled = true

    @AppStorage("subtitle.provider.externalStreams.enabled")
    private var externalStreamSubtitlesEnabled = true
    @AppStorage("player.subtitleSync.autoSelectLatest") private var autoSelectLatestSubtitleSync = true
    @State private var isCheckingForUpdates = false
    @State private var updateCheckResult: UpdateCheckResult?
    @State private var showCredits = false
    @State private var exportDocument: UserDataJSONDocument?
    @State private var isExportingUserData = false
    @State private var isImportingUserData = false
    @State private var pendingImport: PendingUserDataImport?
    @State private var backupNotice: UserDataBackupNotice?

    var body: some View {
        VStack(spacing: 0) {
            PageTitleHeader(title: "Settings")

            Form {
                Section("Appearance") {
                    AppThemePicker(selection: $environment.theme)
                    Text("Themes color only BetterStreamflix's accents, progress, selection, and glow. Text and graphite surfaces stay consistent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(AppTheme.surface)

                Section("Player") {
                    Toggle("Automatically play next episode", isOn: $autoNext)
                    Picker("Default quality", selection: $defaultQualityHeight) {
                        Text("Auto").tag(0)
                        Text("1080p").tag(1080)
                        Text("720p").tag(720)
                        Text("480p").tag(480)
                    }
                    .tint(environment.theme.accent)
                    Picker("Default speed", selection: $defaultPlaybackRate) {
                        ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { speed in
                            Text("\(speed, specifier: "%.2g")×").tag(speed)
                        }
                    }
                    .tint(environment.theme.accent)
                    Picker("Player orientation", selection: playerOrientation) {
                        ForEach(PlayerOrientationPreference.allCases) { option in
                            Text(option.name).tag(option)
                        }
                    }
                    .tint(environment.theme.accent)
                    Text("Auto-Rotate follows the device while the player is open. Landscape Only uses either landscape direction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("If the preferred quality is unavailable, the closest lower resolution is selected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(AppTheme.surface)
                Section("Playback Languages") {
                    Picker("Anime audio", selection: $animeAudioLanguage) {
                        Text("English").tag("en")
                        Text("Japanese").tag("ja")
                        Text("Hebrew").tag("he")
                    }
                    .tint(environment.theme.accent)
                    Picker("Backup anime audio", selection: $animeBackupAudioLanguage) {
                        Text("None").tag("")
                        Text("English").tag("en")
                        Text("Japanese").tag("ja")
                        Text("Hebrew").tag("he")
                    }
                    .tint(environment.theme.accent)
                    Toggle("Subtitles on by default", isOn: $subtitlesEnabledByDefault)
                    languagePicker("Default subtitles", selection: $primarySubtitleLanguage)
                    languagePicker("Backup subtitles", selection: $secondarySubtitleLanguage, allowsNone: true)
                    languagePicker("Default audio", selection: $audioLanguage)
                    Text("Anime uses the preferred language, then the backup language, when a title has no saved source. Subtitle visibility also applies only until you choose on or off for that title.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("For multi-audio streams, if the selected audio track is unavailable, English is used automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(AppTheme.surface)
                Section("Third-party Subtitles") {
                    Picker("Subtitle Loading", selection: $subtitleLoadingModeRawValue) {
                        ForEach(SubtitleLoadingMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .tint(environment.theme.accent)

                    Text(subtitleLoadingMode.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("SubDL", isOn: $subDLSubtitlesEnabled)
                    Toggle("Wizdom", isOn: $wizdomSubtitlesEnabled)
                    Toggle("Ktuvit", isOn: $ktuvitSubtitlesEnabled)
                    Toggle("External Streams", isOn: $externalStreamSubtitlesEnabled)

                    Toggle(
                        "Use latest saved sync automatically",
                        isOn: $autoSelectLatestSubtitleSync
                    )

                    LabeledContent("Sources enabled") {
                        Text(subtitleProviderSummary)
                            .foregroundStyle(.secondary)
                    }

                    Text(
                        "Choose which third-party subtitle services BetterStreamflix should search. Fewer sources can improve playback startup time."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .listRowBackground(AppTheme.surface)
                Section("Backup & Restore") {
                    Button {
                        prepareExport()
                    } label: {
                        Label("Export progress and settings", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        isImportingUserData = true
                    } label: {
                        Label("Import progress and settings", systemImage: "square.and.arrow.down")
                    }
                    Text("A backup includes all settings, watchlist entries, watched history, resume positions, Continue Watching selections, saved subtitle sync versions, title playback speeds, and player zoom preferences. Importing replaces the current app data with the backup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(AppTheme.surface)
                Section("About") {
                    HStack(spacing: 14) {
                        Image("AppLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("BetterStreamflix")
                                .font(.headline)
                            Text("for iOS")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Version") {
                        Text(appVersionLabel)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await checkForUpdates() }
                    } label: {
                        if isCheckingForUpdates {
                            HStack {
                                ProgressView()
                                Text("Checking for updates…")
                            }
                        } else {
                            Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(isCheckingForUpdates)

                    SupportCTAStack()
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        .listRowBackground(Color.clear)

                    Link(destination: SupportLinks.githubRepository) {
                        Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }

                    Button {
                        showCredits = true
                    } label: {
                        Label("Credits", systemImage: "star.bubble")
                    }

                    Text("This app does not host media. Use it only for content you are authorized to access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Trending data and images are provided by TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(AppTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
            // Form's UIKit-backed pickers and switches cache the tint they receive
            // when created. Rebuild them so every visible control adopts a newly
            // selected theme immediately instead of waiting for an app restart.
            .id(environment.theme)
        }
        .tint(environment.theme.accent)
        .background { AppScreenBackground() }
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $updateCheckResult) { result in
            UpdateCheckSheet(result: result)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCredits) {
            CreditsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fileExporter(
            isPresented: $isExportingUserData,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            exportDocument = nil
            switch result {
            case .success:
                backupNotice = UserDataBackupNotice(
                    title: "Backup exported",
                    message: "Your progress, history, watchlist, playback speeds, and settings were saved."
                )
            case let .failure(error):
                backupNotice = UserDataBackupNotice(title: "Export failed", message: error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $isImportingUserData,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            prepareImport(from: result)
        }
        .alert(
            "Replace current app data?",
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } }
            ),
            presenting: pendingImport
        ) { pending in
            Button("Import", role: .destructive) {
                restore(pending)
            }
            Button("Cancel", role: .cancel) {
                pendingImport = nil
            }
        } message: { pending in
            Text("This backup was exported with BetterStreamflix \(pending.summary.appVersion) on \(pending.summary.exportedAt.formatted(date: .abbreviated, time: .shortened)). Your current progress, history, watchlist, playback speeds, and settings will be replaced.")
        }
        .alert(item: $backupNotice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.2"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var subtitleLoadingMode: SubtitleLoadingMode {
        SubtitleLoadingMode(rawValue: subtitleLoadingModeRawValue) ?? .fast
    }

    private var subtitleProviderSummary: String {
        let count = [
            subDLSubtitlesEnabled,
            wizdomSubtitlesEnabled,
            ktuvitSubtitlesEnabled,
            externalStreamSubtitlesEnabled
        ]
        .filter { $0 }
        .count

        switch count {
        case 0:
            return "None"
        case 4:
            return "All"
        case 1:
            return "1 selected"
        default:
            return "\(count) selected"
        }
    }

    private var exportFilename: String {
        "BetterStreamflix-Backup-\(Date.now.formatted(.iso8601.year().month().day()))"
    }

    private func prepareExport() {
        do {
            exportDocument = UserDataJSONDocument(data: try environment.library.exportUserData())
            isExportingUserData = true
        } catch {
            backupNotice = UserDataBackupNotice(title: "Export failed", message: error.localizedDescription)
        }
    }

    private func prepareImport(from result: Result<[URL], any Error>) {
        do {
            guard let url = try result.get().first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let summary = try environment.library.backupSummary(for: data)
            pendingImport = PendingUserDataImport(data: data, summary: summary)
        } catch {
            backupNotice = UserDataBackupNotice(title: "Import failed", message: error.localizedDescription)
        }
    }

    private func restore(_ pending: PendingUserDataImport) {
        pendingImport = nil
        do {
            try environment.library.importUserData(pending.data)
            Task {
                await environment.reloadAfterUserDataImport()
                backupNotice = UserDataBackupNotice(
                    title: "Backup imported",
                    message: "All progress, history, watchlist entries, playback speeds, and settings were restored."
                )
            }
        } catch {
            backupNotice = UserDataBackupNotice(title: "Import failed", message: error.localizedDescription)
        }
    }

    private func languagePicker(
        _ title: String,
        selection: Binding<String>,
        allowsNone: Bool = false
    ) -> some View {
        Picker(title, selection: selection) {
            if allowsNone { Text("None").tag("") }
            ForEach(PlaybackLanguages.options) { option in
                Text(option.name).tag(option.code)
            }
        }
        .tint(environment.theme.accent)
    }

    private var playerOrientation: Binding<PlayerOrientationPreference> {
        Binding(
            get: {
                PlayerOrientationPreference(rawValue: playerOrientationRawValue) ?? .autoRotate
            },
            set: { playerOrientationRawValue = $0.rawValue }
        )
    }

    private func checkForUpdates() async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.1"
        let currentBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "1"

        let outcome = await UpdateCheckService().evaluate(
            currentVersion: currentVersion,
            currentBuild: currentBuild
        )
        switch outcome {
        case .newerRelease(let release):
            updateCheckResult = .updateAvailable(release)
        case .upToDate(let version, let build):
            updateCheckResult = .upToDate(version: version, build: build)
        case .openReleases(let version, let build):
            updateCheckResult = .openReleases(version: version, build: build)
        }
    }
}

struct UserDataJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw UserDataBackupError.invalidFile
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct PendingUserDataImport {
    let data: Data
    let summary: UserDataBackupSummary
}

struct UserDataBackupNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum UpdateCheckResult: Identifiable {
    case updateAvailable(GitHubRelease)
    case upToDate(version: String, build: String)
    case openReleases(version: String, build: String)

    var id: String {
        switch self {
        case .updateAvailable(let release): "available-\(release.tagName)"
        case .upToDate(let version, let build): "current-\(version)-\(build)"
        case .openReleases(let version, let build): "releases-\(version)-\(build)"
        }
    }
}

struct UpdateCheckSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var environment: AppEnvironment

    let result: UpdateCheckResult
    let onSkipUpdate: (() -> Void)?
    let onRemindLater: (() -> Void)?

    init(
        result: UpdateCheckResult,
        onSkipUpdate: (() -> Void)? = nil,
        onRemindLater: (() -> Void)? = nil
    ) {
        self.result = result
        self.onSkipUpdate = onSkipUpdate
        self.onRemindLater = onRemindLater
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch result {
                    case .updateAvailable(let release):
                        updateAvailableContent(release)
                    case .upToDate(let version, let build):
                        statusContent(
                            icon: "checkmark.circle.fill",
                            title: "You're up to date",
                            message: "BetterStreamflix \(version) (\(build)) matches the newest release we could confirm."
                        )
                        releasesCTA(title: "Browse Releases")
                    case .openReleases(let version, let build):
                        statusContent(
                            icon: "arrow.down.app.fill",
                            title: "Updates on GitHub Releases",
                            message: "You're running BetterStreamflix \(version) (\(build)). New unsigned IPAs are published on the repository Releases page — open it to download the latest build."
                        )
                        releasesCTA(title: "View Releases")
                        Button {
                            openURL(SupportLinks.githubLatestRelease)
                        } label: {
                            Label("Open latest release", systemImage: "link")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .background { AppScreenBackground() }
            .navigationTitle("Check for Updates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(accentColor)
                }
            }
        }
        .tint(accentColor)
    }

    @ViewBuilder
    private func updateAvailableContent(_ release: GitHubRelease) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(accentColor)
            Text("A new version was found")
                .foregroundStyle(.primary)
        }
        .font(.title2.bold())

        Text(release.name.flatMap { $0.isEmpty ? nil : $0 } ?? release.tagName)
            .font(.headline)
            .foregroundStyle(accentColor)

        Divider()

        ReleaseNotesMarkdownView(source: release.body, accentColor: accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)

        Button {
            openURL(release.htmlURL)
        } label: {
            Label("Open release page", systemImage: "safari")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AppPrimaryButtonStyle(glow: accentColor))

        if let onRemindLater {
            Button("Remind me later", action: onRemindLater)
                .frame(maxWidth: .infinity)
        }
        if let onSkipUpdate {
            Button("Skip this version", action: onSkipUpdate)
                .frame(maxWidth: .infinity)
                .foregroundStyle(.secondary)
        }
    }

    private func releasesCTA(title: String) -> some View {
        Button {
            openURL(SupportLinks.githubReleases)
        } label: {
            Label(title, systemImage: "safari")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AppPrimaryButtonStyle(glow: accentColor))
    }

    private func statusContent(icon: String, title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.title2.bold())
                .foregroundStyle(accentColor)
            Text(message)
                .foregroundStyle(.secondary)
        }
    }

    private var accentColor: Color { environment.theme.accentBright }
}

struct CreditsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        NavigationStack {
            List {
                Section("BetterStreamflix") {
                    Text("BetterStreamflix for iOS is maintained by the BetterStreamflix project.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(AppTheme.surface)

                Section("Data") {
                    Text("This product uses the TMDB API but is not endorsed or certified by TMDB. Trending metadata and artwork come from TMDB.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(AppTheme.surface)

                Section("Open source") {
                    Text("Licensed under the Apache License, Version 2.0. See NOTICE and LICENSE in the repository for attribution of Streamflix-family lineage.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(AppTheme.surface)

                Section("Community") {
                    Text("Thanks to everyone who tests builds, reports issues, and supports BetterStreamflix.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Link("Buy Me a Coffee", destination: SupportLinks.buyMeACoffee)
                    Link("Telegram", destination: SupportLinks.telegram)
                    Link("Discord", destination: SupportLinks.discord)
                    Link("Patreon", destination: SupportLinks.patreon)
                }
                .listRowBackground(AppTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background { AppScreenBackground() }
            .navigationTitle("Credits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .tint(environment.theme.accent)
        }
    }
}

struct ReleaseNotesMarkdownView: View {
    let blocks: [ReleaseNotesMarkdownBlock]
    let accentColor: Color

    init(source: String, accentColor: Color) {
        blocks = ReleaseNotesMarkdownParser.parse(source)
        self.accentColor = accentColor
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ReleaseNotesMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let source):
            VStack(alignment: .leading, spacing: 8) {
                inlineText(source)
                    .font(headingFont(for: level))
                    .fontWeight(.bold)
                if level <= 2 { Divider() }
            }
        case .paragraph(let source):
            inlineText(source)
                .font(.body)
                .lineSpacing(3)
        case .unorderedItem(let indentation, let source):
            listRow(marker: "•", source: source, indentation: indentation)
        case .orderedItem(let indentation, let marker, let source):
            listRow(marker: marker, source: source, indentation: indentation)
        case .quote(let source):
            inlineText(source)
                .italic()
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(accentColor)
                        .frame(width: 4)
                }
        case .code(let source):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: source)
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
            }
            .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 10))
        case .divider:
            Divider()
        }
    }

    private func listRow(marker: String, source: String, indentation: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .fontWeight(.semibold)
                .foregroundStyle(accentColor)
                .frame(minWidth: 18, alignment: .trailing)
            inlineText(source)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(indentation) * 18)
    }

    private func inlineText(_ source: String) -> Text {
        let attributed = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
        return Text(attributed)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: .title
        case 2: .title2
        case 3: .title3
        default: .headline
        }
    }
}

