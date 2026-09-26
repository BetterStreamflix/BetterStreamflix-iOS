import SwiftUI

/// Root-level confirmation when a `stremio://` / `betterstreamflix://install` deep link arrives.
struct StremioInstallPromptSheet: View {
    let rawURL: String
    var onDismiss: () -> Void
    var onInstalled: (() -> Void)?

    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var store = StremioAddonStore.shared
    @State private var previewName: String?
    @State private var previewDetail: String?
    @State private var previewLogo: URL?
    @State private var configureURL: URL?
    @State private var isLoading = true
    @State private var isInstalling = false
    @State private var errorMessage: String?
    @State private var showConfigure = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    addonLogo
                    VStack(alignment: .leading, spacing: 4) {
                        Text(previewName ?? "Stremio addon")
                            .font(DesignTokens.Typography.shelfTitle)
                        Text(previewDetail ?? rawURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }

                if isLoading {
                    ProgressView("Reading manifest…")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Color(hex: 0xFF6B6B))
                }

                VStack(spacing: 10) {
                    Button {
                        Task { await install() }
                    } label: {
                        Label(
                            isInstalling ? "Installing…" : "Install addon",
                            systemImage: "plus.app.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(environment.theme.accent)
                    .disabled(isInstalling || isLoading)

                    if configureURL != nil {
                        Button {
                            showConfigure = true
                        } label: {
                            Label("Open configure page", systemImage: "slider.horizontal.3")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("Cancel", role: .cancel) {
                        onDismiss()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background { AppScreenBackground() }
            .navigationTitle("Install Stremio addon")
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadPreview() }
            .fullScreenCover(isPresented: $showConfigure) {
                if let configureURL {
                    StremioConfigureWebView(
                        startURL: configureURL,
                        onInstalled: { _ in
                            showConfigure = false
                            onInstalled?()
                            onDismiss()
                        },
                        onCancel: { showConfigure = false }
                    )
                    .environmentObject(environment)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var addonLogo: some View {
        Group {
            if let previewLogo {
                AsyncImage(url: previewLogo) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        Image(systemName: "puzzlepiece.extension.fill")
                            .font(.title2)
                            .foregroundStyle(environment.theme.accentBright)
                    }
                }
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.title2)
                    .foregroundStyle(environment.theme.accentBright)
            }
        }
        .frame(width: 56, height: 56)
        .padding(10)
        .glassEffectWithFallback(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func loadPreview() async {
        isLoading = true
        defer { isLoading = false }
        guard let url = StremioManifestURL.parse(rawURL) else {
            errorMessage = "Invalid addon URL"
            return
        }
        do {
            let loaded = try await StremioAddonClient.loadManifest(from: url)
            previewName = loaded.manifest.name
            previewDetail = loaded.manifest.description ?? loaded.manifest.id
            previewLogo = URL(string: loaded.manifest.logo ?? "")
            if loaded.manifest.isConfigurable || loaded.manifest.requiresConfiguration {
                let manifest = url.path.lowercased().hasSuffix("manifest.json")
                    ? url
                    : url.appendingPathComponent("manifest.json")
                configureURL = StremioDebridURLBuilder.configurePageURL(from: manifest)
            } else {
                configureURL = nil
            }
        } catch {
            previewName = nil
            previewDetail = rawURL
            errorMessage = "Couldn’t read manifest — you can still try Install."
        }
    }

    private func install() async {
        isInstalling = true
        defer { isInstalling = false }
        do {
            _ = try await store.install(from: rawURL, curated: false)
            DesignTokens.Haptics.primaryAction()
            onInstalled?()
            onDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
