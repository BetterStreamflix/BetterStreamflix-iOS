import Foundation

/// Pulls Stremio `meta` when TMDB is thin or the title came from an addon catalog (P3).
enum StremioMetaEnricher {
    struct Enrichment: Sendable {
        var item: MediaItem
        var trailerURL: URL?
        var trailerYouTubeID: String?
    }

    static func enrich(item: MediaItem) async -> MediaItem? {
        await enrichDetailed(item: item)?.item
    }

    static func enrichDetailed(item: MediaItem) async -> Enrichment? {
        let addons = await MainActor.run { StremioAddonStore.shared.enabledAddons.filter(\.supportsMeta) }
        guard !addons.isEmpty else { return nil }
        let type = item.kind == .movie ? "movie" : "series"
        let identifiers = metaIdentifiers(for: item)
        guard !identifiers.isEmpty else { return nil }

        return await withTaskGroup(of: Enrichment?.self, returning: Enrichment?.self) { group in
            for addon in addons.prefix(4) {
                for identifier in identifiers {
                    group.addTask {
                        let client = StremioAddonClient(client: HTTPClient(), baseURL: addon.baseURL)
                        do {
                            let detail = try await client.meta(type: type, id: identifier)
                            let mapped = detail.asMediaItem(providerID: item.providerID)
                            return Enrichment(
                                item: mapped,
                                trailerURL: detail.primaryTrailerURL,
                                trailerYouTubeID: detail.primaryTrailerYouTubeID
                            )
                        } catch {
                            return nil
                        }
                    }
                }
            }
            for await result in group {
                if let result { return result }
            }
            return nil
        }
    }

    /// Merge Stremio meta into an existing TMDB-backed item without wiping strong fields.
    static func merging(_ enriched: MediaItem, into item: MediaItem) -> MediaItem {
        MediaItem(
            id: item.id,
            providerID: item.providerID,
            kind: item.kind,
            title: item.title,
            originalTitle: item.originalTitle,
            overview: (item.overview?.isEmpty == false) ? item.overview : enriched.overview,
            releaseDate: item.releaseDate ?? enriched.releaseDate,
            rating: item.rating ?? enriched.rating,
            quality: item.quality,
            runtimeMinutes: item.runtimeMinutes ?? enriched.runtimeMinutes,
            imdbID: item.imdbID ?? enriched.imdbID,
            tmdbID: item.tmdbID ?? enriched.tmdbID,
            posterURL: item.posterURL ?? enriched.posterURL,
            backdropURL: item.backdropURL ?? enriched.backdropURL,
            posterShape: item.posterShape ?? enriched.posterShape,
            genres: item.genres.isEmpty ? enriched.genres : item.genres,
            cast: item.cast.isEmpty ? enriched.cast : item.cast,
            seasons: item.seasons.isEmpty ? enriched.seasons : item.seasons
        )
    }

    static func episodes(for season: MediaSeason, show: MediaItem) async -> [MediaEpisode]? {
        let addons = await MainActor.run { StremioAddonStore.shared.enabledAddons.filter(\.supportsMeta) }
        guard !addons.isEmpty else { return nil }
        let identifiers = metaIdentifiers(for: show)
        guard !identifiers.isEmpty else { return nil }

        return await withTaskGroup(of: [MediaEpisode]?.self, returning: [MediaEpisode]?.self) { group in
            for addon in addons.prefix(3) {
                for identifier in identifiers {
                    group.addTask {
                        let client = StremioAddonClient(client: HTTPClient(), baseURL: addon.baseURL)
                        do {
                            let detail = try await client.meta(type: "series", id: identifier)
                            let episodes = detail.episodes(for: season, show: show)
                            return episodes.isEmpty ? nil : episodes
                        } catch {
                            return nil
                        }
                    }
                }
            }
            for await result in group {
                if let result { return result }
            }
            return nil
        }
    }

    private static func metaIdentifiers(for item: MediaItem) -> [String] {
        var ids: [String] = []
        if let imdb = item.imdbID,
           imdb.range(of: #"^tt\d{7,9}$"#, options: .regularExpression) != nil {
            ids.append(imdb)
        }
        if let tmdb = item.tmdbID {
            ids.append("tmdb:\(tmdb)")
        }
        if item.id.contains(":") {
            let raw = item.id.split(separator: ":").last.map(String.init) ?? item.id
            if raw.hasPrefix("tt") || raw.hasPrefix("tmdb:") {
                ids.append(raw)
            } else if item.providerID.hasPrefix("stremio:") {
                let parts = item.id.split(separator: ":")
                if parts.count >= 3 {
                    let candidate = parts.dropFirst(2).joined(separator: ":")
                    if !candidate.isEmpty { ids.append(candidate) }
                }
            }
        }
        return Array(NSOrderedSet(array: ids)) as? [String] ?? ids
    }
}

/// Non-UI catalog search used by global Search (A4).
enum StremioCatalogSearch {
    static func search(query: String) async -> [MediaItem] {
        let addons = await MainActor.run { StremioAddonStore.shared.catalogAddons }
        guard !addons.isEmpty else { return [] }
        var results: [MediaItem] = []
        var seen = Set<String>()
        await withTaskGroup(of: [MediaItem].self) { group in
            for addon in addons {
                let searchable = addon.catalogs.filter(\.supportsSearch)
                let targets = searchable.isEmpty
                    ? Array(addon.catalogs.prefix(2))
                    : Array(searchable.prefix(3))
                group.addTask {
                    let client = StremioAddonClient(client: HTTPClient(), baseURL: addon.baseURL)
                    var local: [MediaItem] = []
                    for catalog in targets {
                        do {
                            let metas = try await client.catalog(
                                type: catalog.type,
                                id: catalog.id,
                                extras: ["search": query]
                            )
                            local.append(contentsOf: metas.prefix(16).map {
                                $0.asMediaItem(providerID: "stremio:\(addon.id)")
                            })
                        } catch {
                            continue
                        }
                    }
                    return local
                }
            }
            for await batch in group {
                for item in batch where seen.insert(item.id).inserted {
                    results.append(item)
                }
            }
        }
        return results
    }
}
