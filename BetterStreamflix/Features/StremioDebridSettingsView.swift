import SwiftUI

struct StremioDebridSettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var debrid = StremioDebridStore.shared
    @ObservedObject private var store = StremioAddonStore.shared
    @State private var drafts: [StremioDebridService: String] = [:]
    @State private var banner: String?
    @State private var isRebinding = false
    @State private var validatingService: StremioDebridService?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Debrid-first playback")
                        .font(DesignTokens.Typography.shelfTitle)
                    Text("BetterStreamflix never runs BitTorrent in-app. Save a debrid token, validate it, then install or rebind Torrentio / Comet / MediaFusion so addons return HTTP streams for NativePlayer.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(AppTheme.elevatedSurface)

            Section {
                Picker("Preferred service", selection: $debrid.preferredService) {
                    ForEach(StremioDebridService.allCases) { service in
                        Text(service.title).tag(service)
                    }
                }
                .tint(environment.theme.accent)
                .onChange(of: debrid.preferredService) { _, _ in
                    banner = "Preferred service updated — tap Rebind to rewrite stream addons."
                }

                ForEach(StremioDebridService.allCases) { service in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(service.title)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            statusBadge(for: service)
                        }
                        Text(service.blurb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField("API token", text: draftBinding(for: service))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                        HStack {
                            Button("Save") {
                                debrid.setToken(drafts[service] ?? "", for: service)
                                banner = "\(service.title) token saved"
                                DesignTokens.Haptics.primaryAction()
                            }
                            .font(.caption.weight(.semibold))
                            .disabled((drafts[service] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Validate") {
                                Task {
                                    validatingService = service
                                    debrid.setToken(drafts[service] ?? "", for: service)
                                    let status = await debrid.validate(service: service)
                                    validatingService = nil
                                    banner = status.isPremium
                                        ? "\(service.shortTitle) OK — \(status.badgeTitle)"
                                        : "\(service.shortTitle): \(status.detail ?? status.badgeTitle)"
                                }
                            }
                            .font(.caption.weight(.semibold))
                            .disabled(validatingService != nil)
                            Button("Clear", role: .destructive) {
                                drafts[service] = ""
                                debrid.setToken("", for: service)
                                banner = "\(service.title) cleared"
                            }
                            .font(.caption.weight(.semibold))
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Tokens")
            } footer: {
                Text("Tokens stay in the Keychain on this device. They are injected into addon manifest URLs — never uploaded to BetterStreamflix servers.")
            }
            .listRowBackground(AppTheme.surface)

            Section {
                Button {
                    Task {
                        isRebinding = true
                        defer { isRebinding = false }
                        do {
                            let count = try await store.rebindDebridProfiles(debrid: debrid)
                            banner = count > 0
                                ? "Rebound \(count) stream addon\(count == 1 ? "" : "s") to \(debrid.preferredProfile?.service.title ?? "Debrid")"
                                : "No stream addons needed rebinding"
                            DesignTokens.Haptics.primaryAction()
                        } catch {
                            banner = error.localizedDescription
                        }
                    }
                } label: {
                    Label(
                        isRebinding ? "Rebinding…" : "Rebind stream addons",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(!debrid.hasAnyToken || isRebinding)

                Toggle("Prefer cached debrid links", isOn: Binding(
                    get: { debrid.preferCachedDebridLinks },
                    set: { debrid.preferCachedDebridLinks = $0 }
                ))
                Stepper(
                    "Max preferred size: \(debrid.maxPreferredSizeGB == 0 ? "Any" : "\(debrid.maxPreferredSizeGB) GB")",
                    value: Binding(
                        get: { debrid.maxPreferredSizeGB },
                        set: { debrid.maxPreferredSizeGB = $0 }
                    ),
                    in: 0...50,
                    step: 2
                )
            } header: {
                Text("Playback ranking")
            } footer: {
                Text("Cached `[RD+]` links rank first. Soft size caps demote huge REMUXes unless you opt into larger files.")
            }
            .listRowBackground(AppTheme.surface)

            Section {
                Toggle("Install with cached-only profile", isOn: Binding(
                    get: { debrid.installCachedOnly },
                    set: { debrid.installCachedOnly = $0 }
                ))
                Button("Apply Fast Cached preset") {
                    debrid.applyFastCachedInstallPreset()
                    banner = "Install profile: cached 1080p/720p"
                }
                .font(.caption.weight(.semibold))
                Button("Apply Quality preset") {
                    debrid.applyQualityInstallPreset()
                    banner = "Install profile: 4K/1080p/720p"
                }
                .font(.caption.weight(.semibold))
            } header: {
                Text("One-tap install profile")
            } footer: {
                Text("These options are baked into Torrentio / Comet / MediaFusion when you tap Install with Debrid.")
            }
            .listRowBackground(AppTheme.surface)

            Section {
                Stepper(
                    "Stream query timeout: \(Int(debrid.streamQueryTimeout))s",
                    value: Binding(
                        get: { debrid.streamQueryTimeout },
                        set: { debrid.streamQueryTimeout = $0 }
                    ),
                    in: 6...30,
                    step: 2
                )
                Stepper(
                    "Max parallel stream addons: \(debrid.maxParallelStreamQueries)",
                    value: Binding(
                        get: { debrid.maxParallelStreamQueries },
                        set: { debrid.maxParallelStreamQueries = $0 }
                    ),
                    in: 1...12
                )
                Button("Clear Stremio catalog cache") {
                    Task {
                        await StremioAddonCache.shared.clear()
                        banner = "Catalog cache cleared"
                    }
                }
                .font(.caption.weight(.semibold))
            } header: {
                Text("Performance")
            }
            .listRowBackground(AppTheme.surface)

            if let banner {
                Section {
                    Text(banner)
                        .font(.caption)
                        .foregroundStyle(environment.theme.accentBright)
                }
                .listRowBackground(AppTheme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background { AppScreenBackground() }
        .navigationTitle("Debrid")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            for profile in debrid.profiles {
                if drafts[profile.service] == nil {
                    drafts[profile.service] = profile.token
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for service: StremioDebridService) -> some View {
        if validatingService == service {
            ProgressView()
                .controlSize(.mini)
        } else if let status = debrid.accountStatuses[service] {
            Text(status.badgeTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(status.isPremium ? environment.theme.accentBright : Color(hex: 0xFF6B6B))
        } else if debrid.profiles.first(where: { $0.service == service })?.isConfigured == true {
            Text("Saved")
                .font(.caption.weight(.semibold))
                .foregroundStyle(environment.theme.accentBright)
        }
    }

    private func draftBinding(for service: StremioDebridService) -> Binding<String> {
        Binding(
            get: { drafts[service] ?? debrid.profiles.first(where: { $0.service == service })?.token ?? "" },
            set: { drafts[service] = $0 }
        )
    }
}
