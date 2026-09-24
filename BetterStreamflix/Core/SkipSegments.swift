import Foundation

enum PlaybackSkipSegmentKind:
    String,
    CaseIterable,
    Hashable,
    Sendable
{
    case intro
    case recap
    case outro
    case preview
}

enum PlaybackSkipSegmentSource:
    String,
    Sendable
{
    case skipDB
    case introDB
}

struct PlaybackSkipSegment:
    Identifiable,
    Equatable,
    Sendable
{
    let kind: PlaybackSkipSegmentKind
    let start: TimeInterval
    let end: TimeInterval
    let source: PlaybackSkipSegmentSource
    let confidence: Double?

    var id: String {
        """
        \(kind.rawValue):\
        \(Int((start * 1000).rounded())):\
        \(Int((end * 1000).rounded()))
        """
    }

    func contains(
        _ position: TimeInterval
    ) -> Bool {
        position >= start &&
        position < end
    }
}

private struct PlaybackSkipCandidate:
    Sendable
{
    let segment: PlaybackSkipSegment
    let match: String?
}

actor PlaybackSkipSegmentResolver {
    private struct CacheKey:
        Hashable
    {
        let imdbID: String
        let season: Int?
        let episode: Int?
        let durationSeconds: Int
    }

    private let skipDB: SkipDBClient
    private let introDB: IntroDBClient

    private var cache:
        [CacheKey: [PlaybackSkipSegment]] = [:]

    init(
        client: any HTTPClientProtocol =
            HTTPClient()
    ) {
        skipDB =
            SkipDBClient(
                client: client
            )

        introDB =
            IntroDBClient(
                client: client
            )
    }

    func segments(
        imdbID: String,
        season: Int?,
        episode: Int?,
        duration: TimeInterval
    ) async -> [PlaybackSkipSegment] {
        guard duration.isFinite,
              duration > 0 else {
            return []
        }

        let normalizedIMDbID =
            imdbID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard normalizedIMDbID.range(
            of: #"^tt\d{7,9}$"#,
            options: .regularExpression
        ) != nil else {
            return []
        }

        let key = CacheKey(
            imdbID: normalizedIMDbID,
            season: season,
            episode: episode,
            durationSeconds:
                Int(duration.rounded())
        )

        if let cached = cache[key] {
            return cached
        }

        async let skipResult =
            skipDB.segments(
                imdbID: normalizedIMDbID,
                season: season,
                episode: episode,
                duration: duration
            )

        async let introResult =
            introDB.segments(
                imdbID: normalizedIMDbID,
                season: season,
                episode: episode,
                duration: duration
            )

        let (
            skipSegments,
            introSegments
        ) = await (
            skipResult,
            introResult
        )

        let merged =
            merge(
                skipDB: skipSegments,
                introDB: introSegments
            )
            .sorted {
                if $0.start != $1.start {
                    return $0.start < $1.start
                }

                return $0.end < $1.end
            }

        cache[key] = merged

        return merged
    }

    private func merge(
        skipDB:
            [
                PlaybackSkipSegmentKind:
                    PlaybackSkipCandidate
            ],
        introDB:
            [
                PlaybackSkipSegmentKind:
                    PlaybackSkipCandidate
            ]
    ) -> [PlaybackSkipSegment] {
        PlaybackSkipSegmentKind
            .allCases
            .compactMap { kind in
                let skip =
                    skipDB[kind]

                let intro =
                    introDB[kind]

                if let skip {
                    switch
                        skip.match?
                            .lowercased()
                    {
                    case "exact",
                         "shifted":

                        // SkipDB wins here because
                        // it matched this exact stream
                        // duration or safely adjusted it.
                        return skip.segment

                    case "agnostic":

                        // No reliable duration match.
                        // Prefer IntroDB when available.
                        if let intro {
                            return intro.segment
                        }

                        if (
                            skip.segment
                                .confidence ?? 0
                        ) >= 0.65 {
                            return skip.segment
                        }

                    case "out-of-range":

                        // The SkipDB timestamp belongs
                        // to a substantially different
                        // cut. IntroDB is safer here.
                        if let intro {
                            return intro.segment
                        }

                    default:

                        if let intro {
                            return intro.segment
                        }

                        if (
                            skip.segment
                                .confidence ?? 0
                        ) >= 0.75 {
                            return skip.segment
                        }
                    }
                }

                return intro?.segment
            }
    }
}

private struct SkipDBClient:
    Sendable
{
    private struct Response:
        Decodable
    {
        let segments: SegmentMap
    }

    private struct SegmentMap:
        Decodable
    {
        let intro: Segment?
        let recap: Segment?
        let outro: Segment?
        let preview: Segment?
    }

    private struct Segment:
        Decodable
    {
        let startMS: Double
        let endMS: Double?
        let match: String?
        let confidence: Double?

        enum CodingKeys:
            String,
            CodingKey
        {
            case startMS = "start_ms"
            case endMS = "end_ms"
            case match
            case confidence
        }
    }

    private let client:
        any HTTPClientProtocol

    init(
        client: any HTTPClientProtocol
    ) {
        self.client = client
    }

    func segments(
        imdbID: String,
        season: Int?,
        episode: Int?,
        duration: TimeInterval
    ) async
        -> [
            PlaybackSkipSegmentKind:
                PlaybackSkipCandidate
        ]
    {
        var components =
            URLComponents(
                string:
                    "https://api.skipdb.tv/api/segments"
            )

        var queryItems = [
            URLQueryItem(
                name: "imdb_id",
                value: imdbID
            ),
            URLQueryItem(
                name: "duration",
                value:
                    String(
                        Int(
                            duration
                                .rounded()
                        )
                    )
            ),
            URLQueryItem(
                name: "adjust",
                value: "conservative"
            ),
        ]

        if let season,
           let episode
        {
            queryItems.append(
                URLQueryItem(
                    name: "season",
                    value:
                        String(season)
                )
            )

            queryItems.append(
                URLQueryItem(
                    name: "episode",
                    value:
                        String(episode)
                )
            )
        }

        components?.queryItems =
            queryItems

        guard let url =
                components?.url else {
            return [:]
        }

        do {
            var request =
                URLRequest(url: url)

            request.timeoutInterval = 8

            request.cachePolicy =
                .useProtocolCachePolicy

            request.setValue(
                "application/json",
                forHTTPHeaderField:
                    "Accept"
            )

            request.setValue(
                "BetterStreamflix-iOS",
                forHTTPHeaderField:
                    "User-Agent"
            )

            let response =
                try await client.data(
                    for: request
                )

            let decoded =
                try JSONDecoder()
                    .decode(
                        Response.self,
                        from:
                            response.data
                    )

            var result:
                [
                    PlaybackSkipSegmentKind:
                        PlaybackSkipCandidate
                ] = [:]

            add(
                decoded.segments.intro,
                kind: .intro,
                duration: duration,
                to: &result
            )

            add(
                decoded.segments.recap,
                kind: .recap,
                duration: duration,
                to: &result
            )

            add(
                decoded.segments.outro,
                kind: .outro,
                duration: duration,
                to: &result
            )

            add(
                decoded.segments.preview,
                kind: .preview,
                duration: duration,
                to: &result
            )

            return result
        } catch {
            // One provider failing must never
            // break playback.
            return [:]
        }
    }

    private func add(
        _ value: Segment?,
        kind:
            PlaybackSkipSegmentKind,
        duration: TimeInterval,
        to result:
            inout [
                PlaybackSkipSegmentKind:
                    PlaybackSkipCandidate
            ]
    ) {
        guard let value else {
            return
        }

        let start =
            value.startMS / 1000

        let rawEnd =
            value.endMS.map {
                $0 / 1000
            }

        let end =
            rawEnd ??
            (
                kind == .outro
                    ? duration
                    : 0
            )

        guard let segment =
                validatedSegment(
                    kind: kind,
                    start: start,
                    end: end,
                    duration: duration,
                    source: .skipDB,
                    confidence:
                        value.confidence
                ) else {
            return
        }

        result[kind] =
            PlaybackSkipCandidate(
                segment: segment,
                match: value.match
            )
    }
}

private struct IntroDBClient:
    Sendable
{
    private let client:
        any HTTPClientProtocol

    init(
        client: any HTTPClientProtocol
    ) {
        self.client = client
    }

    func segments(
        imdbID: String,
        season: Int?,
        episode: Int?,
        duration: TimeInterval
    ) async
        -> [
            PlaybackSkipSegmentKind:
                PlaybackSkipCandidate
        ]
    {
        var components =
            URLComponents(
                string:
                    "https://api.introdb.app/segments"
            )

        var queryItems = [
            URLQueryItem(
                name: "imdb_id",
                value: imdbID
            ),
        ]

        if let season,
           let episode
        {
            queryItems.append(
                URLQueryItem(
                    name: "season",
                    value:
                        String(season)
                )
            )

            queryItems.append(
                URLQueryItem(
                    name: "episode",
                    value:
                        String(episode)
                )
            )
        }

        components?.queryItems =
            queryItems

        guard let url =
                components?.url else {
            return [:]
        }

        do {
            var request =
                URLRequest(url: url)

            request.timeoutInterval = 8

            request.cachePolicy =
                .useProtocolCachePolicy

            request.setValue(
                "application/json",
                forHTTPHeaderField:
                    "Accept"
            )

            request.setValue(
                "BetterStreamflix-iOS",
                forHTTPHeaderField:
                    "User-Agent"
            )

            let response =
                try await client.data(
                    for: request
                )

            let object =
                try JSONSerialization
                    .jsonObject(
                        with:
                            response.data
                    )

            return Self.parse(
                object,
                duration: duration
            )
        } catch {
            return [:]
        }
    }

    private static func parse(
        _ root: Any,
        duration: TimeInterval
    ) -> [
        PlaybackSkipSegmentKind:
            PlaybackSkipCandidate
    ] {
        var collected:
            [
                PlaybackSkipSegmentKind:
                    [PlaybackSkipCandidate]
            ] = [:]

        func collect(
            _ value: Any,
            defaultKind:
                PlaybackSkipSegmentKind?
                    = nil
        ) {
            if let array =
                value as? [Any]
            {
                for entry in array {
                    collect(
                        entry,
                        defaultKind:
                            defaultKind
                    )
                }

                return
            }

            guard let object =
                    value as?
                        [String: Any]
            else {
                return
            }

            if let nested =
                object["segments"]
            {
                collect(
                    nested,
                    defaultKind:
                        defaultKind
                )
            }

            if let directKind =
                    kind(
                        from:
                            object[
                                "segment_type"
                            ]
                            ??
                            object["type"]
                            ??
                            defaultKind?
                                .rawValue
                    ),
               let candidate =
                    candidate(
                        from: object,
                        kind:
                            directKind,
                        duration:
                            duration
                    )
            {
                collected[
                    directKind,
                    default: []
                ]
                .append(candidate)
            }

            for (
                key,
                nested
            ) in object {
                guard let nestedKind =
                        kind(
                            from: key
                        )
                else {
                    continue
                }

                collect(
                    nested,
                    defaultKind:
                        nestedKind
                )
            }
        }

        collect(root)

        var result:
            [
                PlaybackSkipSegmentKind:
                    PlaybackSkipCandidate
            ] = [:]

        for (
            kind,
            candidates
        ) in collected {
            result[kind] =
                candidates.max {
                    lhs,
                    rhs in

                    let leftConfidence =
                        lhs.segment
                            .confidence
                        ?? 0.5

                    let rightConfidence =
                        rhs.segment
                            .confidence
                        ?? 0.5

                    if leftConfidence
                        != rightConfidence
                    {
                        return leftConfidence
                            < rightConfidence
                    }

                    return
                        lhs.segment.end
                        - lhs.segment.start
                        <
                        rhs.segment.end
                        - rhs.segment.start
                }
        }

        return result
    }

    private static func candidate(
        from object:
            [String: Any],
        kind:
            PlaybackSkipSegmentKind,
        duration:
            TimeInterval
    ) -> PlaybackSkipCandidate? {
        let start =
            timeValue(
                seconds:
                    object["start_sec"]
                    ??
                    object["start"],
                milliseconds:
                    object["start_ms"]
            )
            ?? 0

        let parsedEnd =
            timeValue(
                seconds:
                    object["end_sec"]
                    ??
                    object["end"],
                milliseconds:
                    object["end_ms"]
            )

        let end =
            parsedEnd
            ??
            (
                kind == .outro
                    ? duration
                    : 0
            )

        var confidence =
            number(
                object["confidence"]
            )

        if let value = confidence,
           value > 1
        {
            confidence =
                value / 100
        }

        guard let segment =
                validatedSegment(
                    kind: kind,
                    start: start,
                    end: end,
                    duration: duration,
                    source: .introDB,
                    confidence:
                        confidence
                ) else {
            return nil
        }

        return PlaybackSkipCandidate(
            segment: segment,
            match: nil
        )
    }

    private static func kind(
        from value: Any?
    ) -> PlaybackSkipSegmentKind? {
        guard let raw =
                value as? String
        else {
            return nil
        }

        switch raw.lowercased() {
        case "intro":
            return .intro

        case "recap":
            return .recap

        case "outro",
             "credits",
             "credit":
            return .outro

        case "preview",
             "post-credit",
             "post_credits",
             "postcredits":
            return .preview

        default:
            return nil
        }
    }

    private static func timeValue(
        seconds: Any?,
        milliseconds: Any?
    ) -> TimeInterval? {
        if let milliseconds =
            number(milliseconds)
        {
            return milliseconds
                / 1000
        }

        if let seconds =
            number(seconds)
        {
            return seconds
        }

        guard let text =
                seconds as? String
        else {
            return nil
        }

        return clockSeconds(text)
    }

    private static func number(
        _ value: Any?
    ) -> Double? {
        switch value {
        case let number
            as NSNumber:
            return number.doubleValue

        case let string
            as String:
            return Double(string)

        default:
            return nil
        }
    }

    private static func clockSeconds(
        _ value: String
    ) -> TimeInterval? {
        let parts =
            value
                .split(separator: ":")
                .compactMap {
                    Double($0)
                }

        guard !parts.isEmpty,
              parts.count <= 3 else {
            return nil
        }

        switch parts.count {
        case 1:
            return parts[0]

        case 2:
            return
                parts[0] * 60
                + parts[1]

        case 3:
            return
                parts[0] * 3600
                + parts[1] * 60
                + parts[2]

        default:
            return nil
        }
    }
}

private func validatedSegment(
    kind:
        PlaybackSkipSegmentKind,
    start: TimeInterval,
    end: TimeInterval,
    duration: TimeInterval,
    source:
        PlaybackSkipSegmentSource,
    confidence: Double?
) -> PlaybackSkipSegment? {
    guard start.isFinite,
          end.isFinite,
          duration.isFinite,
          start >= 0,
          end > start + 1,
          start < duration else {
        return nil
    }

    // Tiny encode-duration differences are
    // acceptable. A much larger difference
    // probably means a different cut.
    guard end <= duration + 15
    else {
        return nil
    }

    let safeEnd =
        min(end, duration)

    guard safeEnd > start + 1
    else {
        return nil
    }

    return PlaybackSkipSegment(
        kind: kind,
        start: start,
        end: safeEnd,
        source: source,
        confidence: confidence
    )
}
