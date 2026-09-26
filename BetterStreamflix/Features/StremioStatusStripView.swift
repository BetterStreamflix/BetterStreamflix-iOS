import SwiftUI

/// Compact Stremio status strip for More / Settings — Debrid health + plugin counts.
struct StremioStatusStripView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject private var store = StremioAddonStore.shared
    @ObservedObject private var debrid = StremioDebridStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                statusChip(
                    title: "\(store.enabledAddons.count) plugins",
                    systemImage: "puzzlepiece.extension.fill"
                )
                statusChip(
                    title: "\(store.streamAddons.count) streams",
                    systemImage: "play.rectangle.fill"
                )
                if debrid.hasAnyToken {
                    statusChip(
                        title: debridPremiumChipTitle,
                        systemImage: "key.horizontal.fill",
                        bright: true
                    )
                } else {
                    statusChip(title: "No Debrid", systemImage: "exclamationmark.triangle.fill")
                }
                if !store.addonsWithUpdates.isEmpty {
                    statusChip(
                        title: "\(store.addonsWithUpdates.count) updates",
                        systemImage: "arrow.down.circle.fill",
                        bright: true
                    )
                }
            }
            Text(debrid.directMagnetUnrestrictEnabled
                 ? "Torrent indexes can play via Debrid API unrestrict when needed."
                 : "Install stream addons with Debrid for HTTP playback.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffectWithFallback(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var debridPremiumChipTitle: String {
        guard let profile = debrid.preferredProfile else { return "Debrid" }
        if let status = debrid.accountStatuses[profile.service],
           let days = status.premiumDays {
            if days <= 5 {
                return "\(profile.service.shortTitle) · \(days)d left"
            }
            return "\(profile.service.shortTitle) · \(days)d"
        }
        return "\(profile.service.shortTitle) ready"
    }

    private func statusChip(title: String, systemImage: String, bright: Bool = false) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(bright ? environment.theme.accentBright : AppTheme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AppTheme.elevatedSurface, in: Capsule())
    }
}

/// Recently resolved Stremio titles for quick re-open from the hub.
enum StremioRecentPlaybackStore {
    private static let key = "stremio.recent.playback.v1"
    private static let limit = 12

    struct Entry: Codable, Hashable, Identifiable {
        var id: String
        var title: String
        var posterURL: URL?
        var kind: MediaKind
        var imdbID: String?
        var tmdbID: Int?
        var providerID: String
        var seasonNumber: Int?
        var episodeNumber: Int?
        var contentID: String?
        var playedAt: Date
    }

    static func remember(request: PlaybackRequest) {
        remember(
            media: request.media,
            seasonNumber: request.episode?.seasonNumber,
            episodeNumber: request.episode?.number,
            contentID: request.contentID
        )
    }

    static func remember(
        media: MediaItem,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        contentID: String? = nil
    ) {
        var entries = load()
        entries.removeAll { $0.id == media.id }
        entries.insert(
            Entry(
                id: media.id,
                title: media.title,
                posterURL: media.posterURL,
                kind: media.kind,
                imdbID: media.imdbID,
                tmdbID: media.tmdbID,
                providerID: media.providerID,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                contentID: contentID,
                playedAt: Date()
            ),
            at: 0
        )
        if entries.count > limit {
            entries = Array(entries.prefix(limit))
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return decoded
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func remove(id: String) {
        var entries = load()
        entries.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func asMediaItems() -> [MediaItem] {
        load().map {
            MediaItem(
                id: $0.id,
                providerID: $0.providerID,
                kind: $0.kind,
                title: $0.title,
                imdbID: $0.imdbID,
                tmdbID: $0.tmdbID,
                posterURL: $0.posterURL
            )
        }
    }
}
