import SwiftUI
import UIKit

/// Empty-state actions when Stremio only returned torrents / external / YouTube links.
struct StremioPlayerEmptyActionsView: View {
    let diagnostics: StremioResolveDiagnostics

    var body: some View {
        VStack(spacing: 10) {
            if !diagnostics.perAddon.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(diagnostics.perAddon) { row in
                            Text(row.chipTitle)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                if let url = diagnostics.primaryExternalURL {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Label("Open in Safari", systemImage: "safari")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let yt = diagnostics.primaryYouTubeURL {
                    Button {
                        UIApplication.shared.open(yt)
                    } label: {
                        Label("YouTube", systemImage: "play.rectangle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                if diagnostics.skippedTorrent > 0 {
                    Text(
                        diagnostics.debridConfigured
                            ? "Validate Debrid in More → Stremio"
                            : "Add Debrid in More → Stremio"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Live per-addon resolve HUD shown while discovery is still running.
struct StremioResolveHUDView: View {
    let diagnostics: StremioResolveDiagnostics
    let isSearching: Bool

    var body: some View {
        if isSearching, !diagnostics.perAddon.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(diagnostics.perAddon) { row in
                        Text(row.chipTitle)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 6)
        }
    }
}

/// Source command-center filters for Stremio-enriched playable streams.
struct StremioSourceFilterSheet: View {
    @Binding var cachedOnly: Bool
    @Binding var minQualityHeight: Int
    @Binding var selectedAddonID: String?
    let addonNames: [(id: String, name: String)]
    var onApply: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Cached debrid only", isOn: $cachedOnly)
                    Picker("Minimum quality", selection: $minQualityHeight) {
                        Text("Any").tag(0)
                        Text("720p+").tag(720)
                        Text("1080p+").tag(1080)
                        Text("4K").tag(2160)
                    }
                } header: {
                    Text("Filters")
                }

                if !addonNames.isEmpty {
                    Section("Addon") {
                        Button("All addons") { selectedAddonID = nil }
                        ForEach(addonNames, id: \.id) { pair in
                            Button {
                                selectedAddonID = pair.id
                            } label: {
                                HStack {
                                    Text(pair.name)
                                    Spacer()
                                    if selectedAddonID == pair.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Source filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onApply() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
