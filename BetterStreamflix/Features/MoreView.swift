import SwiftUI

/// Premium hub for Settings, support, and updates — Search opens as a standalone cover.
struct MoreView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var path = NavigationPath()
    @State private var isCheckingForUpdates = false
    @State private var updateCheckResult: UpdateCheckResult?
    @State private var showCredits = false
    var onOpenSearch: (() -> Void)? = nil

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PageTitleHeader(title: "More", ignoresTopSafeArea: true)

                    hubCard {
                        hubRow(
                            title: "Search",
                            subtitle: "Find movies and series",
                            systemImage: "magnifyingglass"
                        ) {
                            onOpenSearch?()
                        }
                        Divider().opacity(0.35)
                        hubRow(
                            title: "Settings",
                            subtitle: "Player, languages, backup",
                            systemImage: "gearshape.fill"
                        ) {
                            path.append(MoreRoute.settings)
                        }
                        Divider().opacity(0.35)
                        hubRow(
                            title: "Library",
                            subtitle: "Continue, watchlist, watched",
                            systemImage: "bookmark.fill"
                        ) {
                            path.append(MoreRoute.library)
                        }
                    }
                    .padding(.horizontal, 20)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Support")
                            .font(DesignTokens.Typography.shelfTitle)
                            .padding(.horizontal, 20)
                        SupportCTAStack()
                            .padding(.horizontal, 20)
                    }

                    hubCard {
                        Button {
                            Task { await checkForUpdates() }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(environment.theme.accentBright)
                                    .frame(width: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(isCheckingForUpdates ? "Checking…" : "Check for updates")
                                        .font(.headline.weight(.semibold))
                                        .foregroundStyle(AppTheme.primaryText)
                                    Text(appVersionLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isCheckingForUpdates {
                                    ProgressView()
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(isCheckingForUpdates)

                        Divider().opacity(0.35)

                        Link(destination: SupportLinks.githubRepository) {
                            hubLabel(
                                title: "GitHub",
                                subtitle: "Source and releases",
                                systemImage: "chevron.left.forwardslash.chevron.right"
                            )
                        }

                        Divider().opacity(0.35)

                        Button {
                            showCredits = true
                        } label: {
                            hubLabel(
                                title: "Credits",
                                subtitle: "TMDB, open source, community",
                                systemImage: "star.bubble"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)

                    Text("BetterStreamflix does not host media. Use it only for content you are authorized to access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 28)
                }
                .background {
                    AppScreenBackground()
                        .padding(.vertical, -400)
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .background { AppScreenBackground() }
            .ignoresSafeArea(edges: .top)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.visible, for: .tabBar)
            .navigationDestination(for: MoreRoute.self) { route in
                switch route {
                case .settings:
                    SettingsView(showsInlineTitle: true)
                case .library:
                    LibraryView(showsInlineTitle: true)
                }
            }
            .sheet(item: $updateCheckResult) { result in
                UpdateCheckSheet(result: result)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(24)
            }
            .sheet(isPresented: $showCredits) {
                CreditsSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func hubCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffectWithFallback(
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private func hubRow(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            hubLabel(title: title, subtitle: subtitle, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }

    private func hubLabel(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(environment.theme.accentBright)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.6"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "1"
        return "Installed \(version) (\(build))"
    }

    private func checkForUpdates() async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
        let currentBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "1"
        let outcome = await UpdateCheckService().evaluate(
            currentVersion: currentVersion,
            currentBuild: currentBuild
        )
        switch outcome {
        case .newerRelease(let info):
            updateCheckResult = .updateAvailable(info)
        case .upToDate(let version, let build):
            updateCheckResult = .upToDate(version: version, build: build)
        case .unavailable(let version, let build):
            updateCheckResult = .unavailable(version: version, build: build)
        }
    }
}

private enum MoreRoute: Hashable {
    case settings, library
}
