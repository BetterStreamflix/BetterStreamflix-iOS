import Foundation
import SwiftUI

@MainActor
func nextUnwatchedPlaybackRequest(
    after request: PlaybackRequest,
    environment: AppEnvironment,
    library: LibraryStore
) async -> PlaybackRequest? {
    guard request.media.kind == .series, let currentEpisode = request.episode else { return nil }
    do {
        let show = request.media.seasons.isEmpty
            ? try await environment.tmdbDetails(for: request.media)
            : request.media
        guard let startingSeasonIndex = show.seasons.firstIndex(where: {
            $0.number == currentEpisode.seasonNumber
        }) else { return nil }

        for seasonIndex in startingSeasonIndex..<show.seasons.count {
            let season = show.seasons[seasonIndex]
            let episodes = try await environment.tmdbEpisodes(for: season, show: show)
            let candidates: ArraySlice<MediaEpisode>

            if seasonIndex == startingSeasonIndex {
                guard let currentIndex = episodes.firstIndex(where: {
                    $0.id == currentEpisode.id || (
                        $0.seasonNumber == currentEpisode.seasonNumber &&
                            $0.number == currentEpisode.number
                    )
                }) else { return nil }
                candidates = episodes.dropFirst(currentIndex + 1)
            } else {
                candidates = episodes[...]
            }

            if let episode = candidates.first(where: { !library.isWatched($0, in: show) }) {
                return PlaybackRequest(media: show, episode: episode)
            }
        }
        return nil
    } catch where error.isCancellation {
        return nil
    } catch {
        return nil
    }
}
