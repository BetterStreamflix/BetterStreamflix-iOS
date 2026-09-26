import SwiftUI

struct StremioDebridSettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var debrid = StremioDebridStore.shared
    @State private var drafts: [StremioDebridService: String] = [:]
    @State private var banner: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Debrid-first playback")
                        .font(DesignTokens.Typography.shelfTitle)
                    Text("BetterStreamflix never runs BitTorrent in-app. Save a debrid token, then install Torrentio / Comet / MediaFusion with that profile so addons return HTTP streams for NativePlayer.")
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

                ForEach(StremioDebridService.allCases) { service in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(service.title)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if debrid.profiles.first(where: { $0.service == service })?.isConfigured == true {
                                Text("Saved")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(environment.theme.accentBright)
                            }
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
                Toggle("Show adult catalogs", isOn: Binding(
                    get: { debrid.adultCatalogsOptIn },
                    set: { debrid.adultCatalogsOptIn = $0 }
                ))
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
            } header: {
                Text("Catalog & performance")
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

    private func draftBinding(for service: StremioDebridService) -> Binding<String> {
        Binding(
            get: { drafts[service] ?? debrid.profiles.first(where: { $0.service == service })?.token ?? "" },
            set: { drafts[service] = $0 }
        )
    }
}
