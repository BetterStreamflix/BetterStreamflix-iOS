import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum PlaybackLanguages {
    struct Option: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    static let options: [Option] = Locale.LanguageCode.isoLanguageCodes
        .map(\.identifier)
        .filter { $0.count == 2 }
        .compactMap { code in
            Locale.current.localizedString(forLanguageCode: code).map { Option(code: code, name: $0) }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

struct SubtitleStudioVersionMenuOption: Identifiable, Equatable {
    let id: UUID
    let title: String
    let offsetTenths: Int
}

struct SubtitleStudioVersionMenu: View {
    let options: [SubtitleStudioVersionMenuOption]
    let selectedID: UUID?
    let selectedTitle: String
    let onSelectOriginal: () -> Void
    let onSelectVersion: (UUID, Int) -> Void

    var body: some View {
        Menu {
            Button {
                onSelectOriginal()
            } label: {
                Label(
                    "Original · 0.0s",
                    systemImage: selectedID == nil
                        ? "checkmark"
                        : "captions.bubble"
                )
            }

            ForEach(options) { option in
                Button {
                    onSelectVersion(
                        option.id,
                        option.offsetTenths
                    )
                } label: {
                    Label(
                        option.title,
                        systemImage: selectedID == option.id
                            ? "checkmark"
                            : "clock.arrow.circlepath"
                    )
                }
            }
        } label: {
            menuLabel(
                selectedTitle,
                systemImage: "square.stack.3d.up"
            )
        }
        .buttonStyle(.plain)
    }

    private func menuLabel(
        _ title: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)

            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(
            Color.accentColor.opacity(0.2),
            in: Capsule()
        )
        .contentShape(Capsule())
    }
}

struct SubtitleSyncStudioView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    let session: PlayerSession
    let request: PlaybackRequest
    let initialContext: SubtitleStudioContext

    @State private var selectedTrackID: String
    @State private var offsetTenths: Int
    @State private var selectedVersionID: UUID?
    @State private var selectedCueIndex: Int?
    @State private var isSaving = false
    @State private var isCueBrowserExpanded = false

    init(
        session: PlayerSession,
        request: PlaybackRequest,
        initialContext: SubtitleStudioContext
    ) {
        self.session = session
        self.request = request
        self.initialContext = initialContext
        _selectedTrackID = State(initialValue: initialContext.selectedTrackID)
        _offsetTenths = State(initialValue: Int((initialContext.offset * 10).rounded()))
        _selectedVersionID = State(initialValue: initialContext.selectedVersionID)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                studioHeader
                SubtitleStudioPreview(
                    session: session,
                    selectedTrack: selectedTrack,
                    offsetTenths: offsetTenths
                )
                    .frame(maxHeight: max(240, proxy.size.height * 0.62))
                controls(isCompact: proxy.size.width < 600)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
        .interactiveDismissDisabled()
        .preferredColorScheme(.dark)
    }

    private var studioHeader: some View {
        HStack {
            Button("Cancel") { cancel() }
                .disabled(isSaving)
            Spacer()
            VStack(spacing: 2) {
                Text("Subtitle Sync Studio")
                    .font(.headline)
                Text(request.displayTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Save") { save() }
                .fontWeight(.semibold)
                .disabled(isSaving || offsetTenths == 0 || selectedTrack == nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func controls(isCompact: Bool) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                selectedSubtitleCard

                subtitleVersionMenu

                cueSyncBrowser

                HStack(spacing: 16) {
                    timingButton(systemImage: "minus", change: -1, accessibilityLabel: "Move subtitles earlier")
                    Text(offsetText)
                        .font(.system(.title2, design: .monospaced, weight: .bold))
                        .frame(maxWidth: isCompact ? .infinity : 220)
                    timingButton(systemImage: "plus", change: 1, accessibilityLabel: "Move subtitles later")
                }
                .frame(maxWidth: .infinity)

                SubtitleStudioPlaybackControls(
                    session: session,
                    isCompact: isCompact
                ) {
                    selectedVersionID = nil
                    offsetTenths = 0
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var cueSyncBrowser: some View {
        Group {
            if let track = selectedTrack, !track.cues.isEmpty {
                VStack(spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isCueBrowserExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "text.alignleft")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.accentColor)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sync to Line")
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                if isCueBrowserExpanded {
                                    Text("Tap the line you hear at the current video position")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if let index = activeCueIndex(in: track) {
                                    Text(
                                        SubtitleDirectionFormatter.displayText(
                                            track.cues[index].text,
                                            languageCode: track.source.languageCode
                                        )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                } else {
                                    Text("Choose a subtitle line to sync")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer(minLength: 8)

                            Image(
                                systemName: isCueBrowserExpanded
                                    ? "chevron.up"
                                    : "chevron.down"
                            )
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 54)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if isCueBrowserExpanded {
                        Divider()
                            .opacity(0.5)

                        cueBrowserContents(track: track)
                            .padding(12)
                            .transition(
                                .opacity.combined(with: .move(edge: .top))
                            )
                    }
                }
                .background(
                    Color.black.opacity(0.18),
                    in: RoundedRectangle(
                        cornerRadius: 14,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: 14,
                        style: .continuous
                    )
                    .stroke(.white.opacity(0.08), lineWidth: 1)
                }
            }
        }
    }

    @ViewBuilder
    private func cueBrowserContents(
        track: SubtitleStudioTrack
    ) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text(
                    "Video \(cueTimeText(session.subtitleStudioPosition))"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 8) {
                    cueNavigationButton(
                        systemImage: "chevron.up",
                        direction: -1,
                        accessibilityLabel: "Previous subtitle line"
                    )

                    cueNavigationButton(
                        systemImage: "chevron.down",
                        direction: 1,
                        accessibilityLabel: "Next subtitle line"
                    )
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 6) {
                        ForEach(
                            Array(track.cues.enumerated()),
                            id: \.offset
                        ) { index, cue in

                            let isActive = selectedCueIndex == index

                            Button {
                                selectCue(
                                    at: index,
                                    cue: cue
                                )
                            } label: {
                                HStack(
                                    alignment: .top,
                                    spacing: 12
                                ) {
                                    Text(
                                        cueTimeText(cue.startTime)
                                    )
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(
                                        isActive
                                            ? Color.accentColor
                                            : .secondary
                                    )
                                    .frame(
                                        width: 52,
                                        alignment: .leading
                                    )

                                    Text(
                                        SubtitleDirectionFormatter.displayText(
                                            cue.text,
                                            languageCode: track.source.languageCode
                                        )
                                    )
                                    .font(
                                        isActive
                                            ? .callout.weight(.semibold)
                                            : .callout
                                    )
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment: .leading
                                    )

                                    if isActive {
                                        Image(
                                            systemName: "waveform.circle.fill"
                                        )
                                        .foregroundStyle(
                                            Color.accentColor
                                        )
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    isActive
                                        ? Color.accentColor.opacity(0.16)
                                        : Color.clear,
                                    in: RoundedRectangle(
                                        cornerRadius: 10,
                                        style: .continuous
                                    )
                                )
                                .contentShape(
                                    RoundedRectangle(
                                        cornerRadius: 10,
                                        style: .continuous
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding(6)
                }
                .frame(height: 220)
                .onAppear {
                    updateActiveCue(in: track)

                    if let selectedCueIndex {
                        DispatchQueue.main.async {
                            proxy.scrollTo(
                                selectedCueIndex,
                                anchor: .center
                            )
                        }
                    }
                }
                .onChange(
                    of: session.subtitleStudioPosition
                ) { _, _ in
                    updateActiveCue(in: track)
                }
                .onChange(of: offsetTenths) { _, _ in
                    let previousIndex = selectedCueIndex

                    updateActiveCue(in: track)

                    guard let selectedCueIndex,
                          selectedCueIndex != previousIndex else {
                        return
                    }

                    withAnimation(
                        .easeInOut(duration: 0.22)
                    ) {
                        proxy.scrollTo(
                            selectedCueIndex,
                            anchor: .center
                        )
                    }
                }
                .onChange(of: selectedTrackID) { _, _ in
                    guard let track = selectedTrack else {
                        selectedCueIndex = nil
                        return
                    }

                    updateActiveCue(in: track)

                    if let selectedCueIndex {
                        DispatchQueue.main.async {
                            proxy.scrollTo(
                                selectedCueIndex,
                                anchor: .center
                            )
                        }
                    }
                }
            }

            if let selectedCueIndex,
               track.cues.indices.contains(selectedCueIndex) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)

                    Text("Currently playing")
                        .font(.caption)

                    Spacer()

                    Text(
                        "\(selectedCueIndex + 1) / \(track.cues.count)"
                    )
                    .font(.caption.monospacedDigit())
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            }
        }
    }

    private func cueNavigationButton(
        systemImage: String,
        direction: Int,
        accessibilityLabel: String
    ) -> some View {
        Button {
            moveSelectedCue(by: direction)
        } label: {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 28)
        }
        .buttonStyle(.bordered)
        .disabled(!canMoveSelectedCue(by: direction))
        .accessibilityLabel(accessibilityLabel)
    }

    private func canMoveSelectedCue(
        by direction: Int
    ) -> Bool {
        guard let track = selectedTrack,
              !track.cues.isEmpty else {
            return false
        }

        let current =
            activeCueIndex(in: track)
            ?? nearestCueIndex(in: track)
            ?? 0

        return track.cues.indices.contains(
            current + direction
        )
        }

    private func moveSelectedCue(
        by direction: Int
    ) {
        guard let track = selectedTrack,
              !track.cues.isEmpty else {
            return
        }

        let current =
            activeCueIndex(in: track)
            ?? nearestCueIndex(in: track)
            ?? 0

        let target = min(
            max(current + direction, 0),
            track.cues.count - 1
        )

        selectCue(
            at: target,
            cue: track.cues[target]
        )
    }

    private func selectCue(
        at index: Int,
        cue: SubtitleCue
    ) {
        let offset =
            session.subtitleStudioPosition
            - cue.startTime

        offsetTenths = min(
            3000,
            max(
                -3000,
                Int((offset * 10).rounded())
            )
        )

        selectedVersionID = nil
        selectedCueIndex = index
    }

    private func nearestCueIndex(
        in track: SubtitleStudioTrack
    ) -> Int? {
        guard !track.cues.isEmpty else { return nil }

        // Convert the current video time back into the subtitle file's timeline.
        let subtitleTime =
            session.subtitleStudioPosition
            - Double(offsetTenths) / 10

        return track.cues.indices.min { lhs, rhs in
            abs(track.cues[lhs].startTime - subtitleTime)
                < abs(track.cues[rhs].startTime - subtitleTime)
        }
    }

    private func activeCueIndex(
        in track: SubtitleStudioTrack
    ) -> Int? {
        let subtitleTime =
            session.subtitleStudioPosition
            - Double(offsetTenths) / 10

        return track.cues.firstIndex { cue in
            cue.startTime <= subtitleTime
                && subtitleTime < cue.endTime
        }
    }

    private func updateActiveCue(
        in track: SubtitleStudioTrack
    ) {
        selectedCueIndex = activeCueIndex(in: track)
    }

    private func cueTimeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else {
            return "0:00"
        }

        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                secs
            )
        }

        return String(
            format: "%d:%02d",
            minutes,
            secs
        )
    }

    private var subtitleVersionMenu: some View {
        SubtitleStudioVersionMenu(
            options: versionsForSelectedTrack.map { version in
                SubtitleStudioVersionMenuOption(
                    id: version.id,
                    title: versionName(version),
                    offsetTenths: version.offsetTenths
                )
            },
            selectedID: selectedVersionID,
            selectedTitle: selectedVersionName,
            onSelectOriginal: {
                selectedVersionID = nil
                offsetTenths = 0
            },
            onSelectVersion: { versionID, versionOffsetTenths in
                selectedVersionID = versionID
                offsetTenths = versionOffsetTenths
            }
        )
    }

    private var selectedSubtitleCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "captions.bubble.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text("Editing Subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(
                    selectedTrack?.source.userFacingDisplayName
                        ?? selectedTrack?.displayName
                        ?? "Selected Subtitle"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 8)

            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.white.opacity(0.06),
            in: RoundedRectangle(
                cornerRadius: 14,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 14,
                style: .continuous
            )
            .stroke(
                Color.white.opacity(0.08),
                lineWidth: 1
            )
        }
    }

    private var selectedTrack: SubtitleStudioTrack? {
        session.subtitleStudioTracks.first { $0.id == selectedTrackID }
    }

    private var versionsForSelectedTrack: [SubtitleSyncVersion] {
        guard let source = selectedTrack?.source else { return [] }
        return library.subtitleSyncVersions(for: request)
            .filter { source.matchesSyncKey($0.subtitleKey) }
    }

    private var selectedVersionName: String {
        guard let selectedVersionID,
              let version = versionsForSelectedTrack.first(where: { $0.id == selectedVersionID }) else {
            return "Original"
        }
        return versionName(version)
    }

    private var offsetText: String {
        String(format: "%+.1f seconds", Double(offsetTenths) / 10)
    }

    private func timingButton(
        systemImage: String,
        change: Int,
        accessibilityLabel: String
    ) -> some View {
        Button {
            offsetTenths = min(3000, max(-3000, offsetTenths + change))
            selectedVersionID = nil
        } label: {
            Image(systemName: systemImage)
                .frame(width: 44, height: 28)
        }
        .buttonStyle(.borderedProminent)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Moves subtitles by 0.1 seconds")
    }

    private func versionName(_ version: SubtitleSyncVersion) -> String {
        let date = version.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "\(String(format: "%+.1fs", version.offset)) · \(date)"
    }

    private func cancel() {
        Task {
            await session.cancelSubtitleStudio()
            dismiss()
        }
    }

    private func save() {
        guard let subtitle = selectedTrack?.source else { return }
        isSaving = true
        guard let version = library.saveSubtitleSyncVersion(
            subtitle: subtitle,
            offset: Double(offsetTenths) / 10,
            for: request
        ) else {
            isSaving = false
            return
        }
        Task {
            await session.applySubtitleSyncVersions(
                library.subtitleSyncVersions(for: request),
                selecting: version.id
            )
            dismiss()
        }
    }
}

struct SubtitleStudioPreview: View {
    @ObservedObject var session: PlayerSession
    let selectedTrack: SubtitleStudioTrack?
    let offsetTenths: Int

    var body: some View {
        VideoPlayer(player: session.player) {
            ZStack {
                VStack {
                    Spacer()
                    if let previewText {
                        Text(previewText)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
                            .shadow(color: .black.opacity(0.8), radius: 3)
                            .padding(.horizontal, 30)
                            .padding(.bottom, 44)
                    }
                }

                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .padding(18)
                        .background(.black.opacity(0.62), in: Circle())
                        .accessibilityLabel("Loading video preview")
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var isLoading: Bool {
        session.isBuffering || session.isSubtitleStudioSeeking
    }

    private var previewText: String? {
        guard let selectedTrack,
              let text = selectedTrack.text(
                at: session.subtitleStudioPosition,
                offset: Double(offsetTenths) / 10
              ) else { return nil }
        return SubtitleDirectionFormatter.displayText(
            text,
            languageCode: selectedTrack.source.languageCode
        )
    }
}

struct SubtitleStudioPlaybackControls: View {
    @ObservedObject var session: PlayerSession
    let isCompact: Bool
    let onReset: () -> Void

    var body: some View {
        Group {
            if isCompact {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        playbackButton
                        Text(timeText(session.subtitleStudioPosition))
                            .font(.caption.monospacedDigit())
                        Spacer(minLength: 0)
                        Text(timeText(session.duration))
                            .font(.caption.monospacedDigit())
                        resetButton
                    }
                    playbackSlider
                }
            } else {
                HStack(spacing: 12) {
                    playbackButton
                    Text(timeText(session.subtitleStudioPosition))
                        .font(.caption.monospacedDigit())
                    playbackSlider
                    Text(timeText(session.duration))
                        .font(.caption.monospacedDigit())
                    resetButton
                }
            }
        }
    }

    private var playbackButton: some View {
        Button {
            session.toggleStudioPlayback()
        } label: {
            Image(systemName: session.player.timeControlStatus == .paused ? "play.fill" : "pause.fill")
                .frame(width: 28)
        }
        .buttonStyle(.borderedProminent)
    }

    private var playbackSlider: some View {
        Slider(
            value: Binding(
                get: { min(session.subtitleStudioPosition, max(session.duration, 0)) },
                set: { session.seek(to: $0) }
            ),
            in: 0...max(session.duration, 1)
        )
    }

    private var resetButton: some View {
        Button("Reset", action: onReset)
            .buttonStyle(.bordered)
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

enum SourceSwitchStatus: Equatable {
    case switching(String)
    case succeeded(String)
    case failed

    var title: String {
        switch self {
        case .switching:
            return "Switching source…"
        case .succeeded:
            return "Source switched"
        case .failed:
            return "Couldn't switch source"
        }
    }

    var subtitle: String {
        switch self {
        case .switching(let source),
             .succeeded(let source):
            return source
        case .failed:
            return "Continuing previous source"
        }
    }

    var systemImage: String {
        switch self {
        case .switching:
            return "arrow.trianglehead.2.clockwise.rotate.90"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    var isLoading: Bool {
        if case .switching = self { return true }
        return false
    }
}

struct PendingEpisodeLoad: Equatable {
    let previousRequest: PlaybackRequest
    let request: PlaybackRequest
    let previousSkipSegments: [PlaybackSkipSegment]
    let previousSkipSegmentsContentID: String?
}

struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var library: LibraryStore
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
    @StateObject private var model: PlayerViewModel
    @StateObject private var session = PlayerSession()
    @State private var nextRequest: PlaybackRequest?
    @State private var finishedContentID: String?
    @State private var progressSaveSuspendedForContentID: String?
    @State private var skipSegments:
        [PlaybackSkipSegment] = []

    @State private var skipSegmentsContentID:
        String?
    @State private var subtitleStudioContext: SubtitleStudioContext?
    @State private var sourceSwitchStatus: SourceSwitchStatus?
    @State private var sourceSwitchTask: Task<Void, Never>?
    @State private var sourceSwitchRequestID = UUID()
    @State private var pendingEpisodeLoad: PendingEpisodeLoad?
    @State private var episodeLoadTask: Task<Void, Never>?

    init(request: PlaybackRequest, nextRequest: PlaybackRequest?) {
        _model = StateObject(wrappedValue: PlayerViewModel(request: request))
        _nextRequest = State(initialValue: nextRequest)
    }

    var body: some View {
        NativePlayerController(
            player: session.player,
            isZoomedToFill: library.isPlayerZoomedToFill(for: model.request),
            isBuffering: session.isBuffering || model.isLoading,
            playbackErrorMessage: session.playbackErrorMessage ?? (model.source == nil ? model.errorMessage : nil),
            availableQualities: session.availableQualities,
            selectedQuality: session.selectedQuality,
            streams: model.streams,
            selectedSourceID: model.selectedSourceID,
            automaticSource: model.rememberedSource == nil,
            isSearchingForSources: model.isSearching,
            onSourceChanged: { id, quality in
                // The newest user choice always wins.
                //
                // Invalidate the old ViewModel operation and the old PlayerSession
                // preparation before cancelling its Task. Crucially,
                // supersedeSourceSwitch() keeps the currently-playing source snapshot.
                model.supersedeSourceSelection()
                session.supersedeSourceSwitch()

                sourceSwitchTask?.cancel()

                let requestID = UUID()
                sourceSwitchRequestID = requestID

                // Selecting the source that is already playing is just an
                // in-place quality change. If another switch was pending,
                // cancel it completely and stay on the current source.
                if let id,
                   id == model.selectedSourceID {

                    session.cancelSourceSwitch(
                        resumePrevious: true
                    )

                    model.rememberCurrentSource(
                        library: library
                    )

                    session.setQuality(quality)

                    withAnimation {
                        sourceSwitchStatus = nil
                    }

                    sourceSwitchTask = nil
                    return
                }

                let requestedSourceName: String

                if let id,
                   let stream = model.streams.first(
                        where: { $0.id == id }
                   ) {

                    let sourceName =
                        stream.candidate.providerName

                    let qualityName =
                        quality?.title
                        ?? stream.candidate.displayMetadata?.quality

                    if let qualityName {
                        requestedSourceName =
                            "\(sourceName) • \(qualityName)"
                    } else {
                        requestedSourceName =
                            sourceName
                    }
                } else {
                    requestedSourceName =
                        "Choosing best available source"
                }

                withAnimation {
                    sourceSwitchStatus =
                        .switching(requestedSourceName)
                }

                saveProgress()

                // This only snapshots the current item the first time.
                // If another switch is already pending, the original snapshot survives.
                session.beginSourceSwitch()

                sourceSwitchTask = Task {
                    let switched = await model.selectSource(
                        id,
                        quality: quality,
                        library: library
                    ) { stream, choice in

                        guard !Task.isCancelled,
                              sourceSwitchRequestID == requestID else {
                            return false
                        }

                        return await session.switchSource(
                            stream,
                            externalSubtitles:
                                model.allSubtitles,
                            quality: choice,
                            useQualityChoice: id != nil
                        )
                    }

                    // Anything belonging to an older tap stops here.
                    guard !Task.isCancelled,
                          sourceSwitchRequestID == requestID else {
                        return
                    }

                    if switched {
                        session.updateExternalSubtitles(model.allSubtitles)
                        let actualSourceName: String

                        if let selectedSourceID =
                                model.selectedSourceID,
                           let stream = model.streams.first(
                                where: {
                                    $0.id == selectedSourceID
                                }
                           ) {

                            let sourceName =
                                stream.candidate.providerName

                            let qualityName =
                                session.selectedQuality?.title
                                ?? stream.candidate
                                    .displayMetadata?.quality

                            if let qualityName {
                                actualSourceName =
                                    "\(sourceName) • \(qualityName)"
                            } else {
                                actualSourceName =
                                    sourceName
                            }
                        } else {
                            actualSourceName =
                                requestedSourceName
                        }

                        withAnimation {
                            sourceSwitchStatus =
                                .succeeded(actualSourceName)
                        }

                        try? await Task.sleep(
                            for: .seconds(1.4)
                        )

                        guard !Task.isCancelled,
                              sourceSwitchRequestID == requestID else {
                            return
                        }

                        withAnimation {
                            sourceSwitchStatus = nil
                        }
                    } else {
                        session.cancelSourceSwitch(
                            resumePrevious: true
                        )

                        withAnimation {
                            sourceSwitchStatus = .failed
                        }

                        try? await Task.sleep(
                            for: .seconds(2)
                        )

                        guard !Task.isCancelled,
                              sourceSwitchRequestID == requestID else {
                            return
                        }

                        withAnimation {
                            sourceSwitchStatus = nil
                        }
                    }

                    if sourceSwitchRequestID == requestID {
                        sourceSwitchTask = nil
                    }
                }
            },
            subtitleTimingOffset: session.subtitleTimingOffset,
            canAdjustSubtitleTiming: session.canOpenSubtitleStudio,
            onQualityChanged: { session.setQuality($0) },
            onAdjustSubtitleTiming: { session.adjustSubtitleTiming(by: $0) },
            onOpenSubtitleSync: { openSubtitleStudio() },
            onRetryPlayback: {
                model.resetRecovery()
                if model.source == nil {
                    Task {
                        await model.load(environment: environment,
                            enabledSubtitleProviderIDs: enabledSubtitleProviderIDs,
                            audioLanguage: animeAudioLanguage, backupAudioLanguage: animeBackupAudioLanguage,
                            qualityHeight: defaultQualityHeight)
                    }
                } else { session.retryPlayback() }
            },
            onZoomChanged: {
                library.updatePlayerZoomedToFill($0, for: model.request)
            },
            onWillDismiss: {
                AppOrientationController.shared.endPlayback()
            },
            onDismiss: {
                saveProgress(markNearEndFinished: true)
                dismiss()
            }
        )
        .overlay(alignment: .top) {
            if let sourceSwitchStatus {
                sourceSwitchOverlay(
                    sourceSwitchStatus
                )
                .padding(.top, 54)
                .transition(
                    .move(edge: .top)
                        .combined(
                            with: .opacity
                        )
                )
                .zIndex(100)
            } else if let pendingEpisodeLoad {
                playbackStatusOverlay(
                    title: "Loading next episode…",
                    subtitle: playbackLoadingSubtitle(
                        for: pendingEpisodeLoad.request
                    ),
                    isLoading: true,
                    cancelAccessibilityLabel: "Cancel next episode loading",
                    onCancel: cancelPendingEpisodeLoad
                )
                .padding(.top, 54)
                .transition(
                    .move(edge: .top)
                        .combined(with: .opacity)
                )
                .zIndex(100)
            } else if model.isLoading || session.isBuffering {
                playbackStatusOverlay(
                    title: "Loading video…",
                    subtitle: playbackLoadingSubtitle(
                        for: model.request
                    ),
                    isLoading: true,
                    cancelAccessibilityLabel: "Close player",
                    onCancel: closePlayerDuringLoading
                )
                .padding(.top, 54)
                .transition(
                    .move(edge: .top)
                        .combined(with: .opacity)
                )
                .zIndex(100)
            }
        }
        .overlay(
            alignment: .bottomTrailing
        ) {
            if pendingEpisodeLoad == nil,
               let segment = activeSkipSegment
            {
                skipButton(
                    for: segment
                )
                .padding(
                    .trailing,
                    28
                )
                .padding(
                    .bottom,
                    136
                )
                .transition(
                    .move(edge: .trailing)
                        .combined(
                            with: .opacity
                        )
                )
                .zIndex(90)
            }
        }
        .animation(
            .easeInOut(
                duration: 0.22
            ),
            value:
                activeSkipSegment?.id
        )
        .animation(
            .easeInOut(duration: 0.22),
            value: sourceSwitchStatus
        )
        .animation(
            .easeInOut(duration: 0.22),
            value: pendingEpisodeLoad
        )
        .background(.black)
        .ignoresSafeArea()
        .task {
            library.markPlaybackStarted(request: model.request)
            await model.load(environment: environment,
                enabledSubtitleProviderIDs: enabledSubtitleProviderIDs,
                audioLanguage: animeAudioLanguage, backupAudioLanguage: animeBackupAudioLanguage,
                qualityHeight: defaultQualityHeight)
        }
        .task(id: model.sourceRevision) {
            guard let source = model.source else { return }
            let playbackRequest = model.request
            let subtitleLoadingMode = SubtitleLoadingMode(
                rawValue: subtitleLoadingModeRawValue
            ) ?? .fast
            let savedSubtitleVisibility = library.subtitleVisibilityPreference(
                for: playbackRequest
            )
            let subtitlesEnabled = savedSubtitleVisibility ?? subtitlesEnabledByDefault
            let visibilitySource = savedSubtitleVisibility.map { $0 ? "on" : "off" } ?? "unset"
            SubtitleDiagnostics.logger.info(
                "SUBTITLE PERF startup policy content=\(model.request.contentID, privacy: .public) savedVisibility=\(visibilitySource, privacy: .public) defaultVisibility=\(self.subtitlesEnabledByDefault) enabled=\(subtitlesEnabled) primary=\(self.primarySubtitleLanguage, privacy: .public) discovered=\(model.thirdPartySubtitles.count)"
            )
            if subtitleLoadingMode == .completeBeforePlayback && subtitlesEnabled {
                await model.waitForSubtitleDiscovery()
            }
            let initialPlaybackRate = library.playbackRate(
                for: playbackRequest,
                defaultRate: defaultPlaybackRate
            )
            library.updatePlaybackRate(initialPlaybackRate, for: playbackRequest)
            await session.load(
                request: playbackRequest,
                source: source,
                resumeAt: library.resumePosition(for: playbackRequest),
                primarySubtitleLanguage: primarySubtitleLanguage,
                secondarySubtitleLanguage: secondarySubtitleLanguage,
                audioLanguage: audioLanguage,
                externalSubtitles: model.allSubtitles,
                subtitleSyncVersions: library.subtitleSyncVersions(for: playbackRequest),
                automaticallySelectLatestSubtitleSync: autoSelectLatestSubtitleSync,
                subtitlesEnabled: subtitlesEnabled,
                defaultQualityHeight: defaultQualityHeight,
                defaultPlaybackRate: Float(initialPlaybackRate),
                subtitleLoadingMode: subtitleLoadingMode,
                subtitleSelectionPreference: library.subtitleSelectionPreference(
                    for: playbackRequest
                )
            )
            guard !Task.isCancelled,
                  model.request.contentID == playbackRequest.contentID else { return }
            if progressSaveSuspendedForContentID == playbackRequest.contentID {
                progressSaveSuspendedForContentID = nil
            }
            session.updateExternalSubtitles(model.allSubtitles)
            session.onEnded = { handlePlaybackEnded() }
            await loadSkipSegmentsWhenReady(
                for: playbackRequest
            )

        }
        .task(id: model.subtitleRevision) {
            guard model.source != nil else { return }
            session.updateExternalSubtitles(model.allSubtitles)
        }
        .task(id: model.request.contentID) {
            if let nextRequest, !library.isWatched(nextRequest) { return }
            nextRequest = await resolveNextRequest(after: model.request)
        }
        .task { await saveProgressEverySecond() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                session.prepareForForegroundResume()
            case .background:
                saveProgress()
                session.prepareForBackground()
            case .inactive:
                saveProgress()
            @unknown default:
                saveProgress()
            }
        }
        .onChange(of: session.playbackRate) { _, rate in
            library.updatePlaybackRate(rate, for: model.request)
        }
        .onChange(of: model.isLoading) { _, _ in
            finishPendingEpisodeLoadIfReady()
        }
        .onChange(of: session.isBuffering) { _, _ in
            finishPendingEpisodeLoadIfReady()
        }
        .onChange(of: session.duration) { _, _ in
            finishPendingEpisodeLoadIfReady()
        }
        .onChange(of: session.activeContentID) { _, _ in
            finishPendingEpisodeLoadIfReady()
        }
        .onAppear {
            session.onSubtitleVisibilityChanged = { isEnabled in
                library.updateSubtitleVisibilityPreference(isEnabled, for: model.request)
            }
            session.onSubtitleSelectionChanged = { preference in
                library.updateSubtitleSelectionPreference(preference, for: model.request)
            }
            session.onSourceRefreshNeeded = {
                saveProgress()
                return await model.recover { stream in
                    await session.switchSource(stream, externalSubtitles: model.allSubtitles)
                }
            }
            AppOrientationController.shared.beginPlayback(using: playerOrientation)
        }
        .onDisappear {
            session.onSubtitleVisibilityChanged = nil
            session.onSubtitleSelectionChanged = nil
            session.onSourceRefreshNeeded = nil

            sourceSwitchTask?.cancel()
            sourceSwitchTask = nil
            episodeLoadTask?.cancel()
            episodeLoadTask = nil

            model.cancel()

            saveProgress(
                markNearEndFinished: true
            )

            session.stop()
            AppOrientationController.shared.endPlayback()
        }
        .statusBarHidden()
        .fullScreenCover(item: $subtitleStudioContext) { context in
            SubtitleSyncStudioView(
                session: session,
                request: model.request,
                initialContext: context
            )
            .environmentObject(library)
        }
        .errorAlert(Binding(get: { model.source == nil ? nil : model.errorMessage },
            set: { model.errorMessage = $0 }))
    }

    private func cancelPendingSourceSwitch() {
        guard case .switching = sourceSwitchStatus else {
            return
        }

        // Immediately make the current request stale so that even if its
        // async work finishes after cancellation, it cannot affect playback.
        sourceSwitchRequestID = UUID()

        model.supersedeSourceSelection()
        session.supersedeSourceSwitch()

        sourceSwitchTask?.cancel()
        sourceSwitchTask = nil

        // Drop the pending replacement while keeping/resuming the source
        // that was playing before the switch started.
        session.cancelSourceSwitch(
            resumePrevious: true
        )

        withAnimation {
            sourceSwitchStatus = nil
        }
    }

    @ViewBuilder
    private func skipButton(
        for segment:
            PlaybackSkipSegment
    ) -> some View {
        Button {
            handleSkip(
                segment
            )
        } label: {
            HStack(
                spacing: 9
            ) {
                Text(
                    skipButtonTitle(
                        for: segment
                    )
                )
                .font(
                    .subheadline
                        .weight(
                            .semibold
                        )
                )

                Image(
                    systemName:
                        "forward.end.fill"
                )
                .font(
                    .caption
                        .weight(.bold)
                )
            }
            .foregroundStyle(.white)
            .padding(
                .horizontal,
                17
            )
            .frame(
                minHeight: 44
            )
            .background {
                RoundedRectangle(
                    cornerRadius: 10,
                    style: .continuous
                )
                .fill(
                    Color.black
                        .opacity(0.72)
                )
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: 10,
                    style: .continuous
                )
                .stroke(
                    Color.white
                        .opacity(0.28),
                    lineWidth: 1
                )
            }
            .shadow(
                color:
                    .black.opacity(0.35),
                radius: 8,
                y: 3
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            skipButtonTitle(
                for: segment
            )
        )
    }

    private func skipButtonTitle(
        for segment: PlaybackSkipSegment
    ) -> String {
        switch segment.kind {
        case .intro:
            return "Skip Intro"

        case .recap:
            return "Skip Recap"

        case .preview:
            return "Skip Preview"

        case .outro:
            if let nextRequest,
               !library.isWatched(nextRequest) {
                return "Next Episode"
            }

            return "Skip Credits"
        }
    }

    private func handleSkip(
        _ segment:
            PlaybackSkipSegment
    ) {
        switch segment.kind {
        case .outro:
            if let nextRequest,
               !library.isWatched(
                    nextRequest
               )
            {
                completeCurrentPlayback(
                    autoPlayNext: true
                )

                return
            }

            session.seekForPlayback(
                to: segment.end
            )

        case .intro,
             .recap,
             .preview:
            session.seekForPlayback(
                to: segment.end
            )
        }
    }

    private func sourceSwitchOverlay(
        _ status: SourceSwitchStatus
    ) -> some View {
        playbackStatusOverlay(
            title: status.title,
            subtitle: status.subtitle,
            isLoading: status.isLoading,
            systemImage: status.systemImage,
            accentColor: status == .failed ? .orange : .green,
            cancelAccessibilityLabel: "Cancel source switch",
            onCancel: {
                if case .switching = status {
                    cancelPendingSourceSwitch()
                }
            }
        )
    }

    private func playbackStatusOverlay(
        title: String,
        subtitle: String,
        isLoading: Bool,
        systemImage: String = "arrow.trianglehead.2.clockwise.rotate.90",
        accentColor: Color = .white,
        cancelAccessibilityLabel: String,
        onCancel: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            } else {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if isLoading {
                Divider()
                    .frame(height: 24)
                    .overlay(
                        Color.white.opacity(0.18)
                    )
                    .padding(.leading, 2)

                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(
                            width: 30,
                            height: 30
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    cancelAccessibilityLabel
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            .ultraThinMaterial,
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(
                    Color.white.opacity(0.12),
                    lineWidth: 1
                )
        }
        .shadow(
            color: .black.opacity(0.35),
            radius: 12,
            y: 5
        )
    }

    private func loadSkipSegmentsWhenReady(
        for request: PlaybackRequest
    ) async {
        let contentID =
            request.contentID

        if skipSegmentsContentID
            != contentID
        {
            skipSegments = []
            skipSegmentsContentID =
                contentID
        }

        // AVPlayer can take a short moment
        // after item replacement before the
        // final duration becomes available.
        for _ in 0..<40 {
            guard !Task.isCancelled,
                  model.request.contentID
                    == contentID else {
                return
            }

            let duration =
                session.duration

            if duration.isFinite,
               duration > 10
            {
                let segments =
                    await environment
                        .playbackSkipSegments(
                            for: request,
                            duration:
                                duration
                        )

                guard !Task.isCancelled,
                      model.request
                        .contentID
                        == contentID else {
                    return
                }

                withAnimation(
                    .easeInOut(
                        duration: 0.2
                    )
                ) {
                    skipSegments =
                        segments

                    skipSegmentsContentID =
                        contentID
                }

                return
            }

            do {
                try await Task.sleep(
                    for:
                        .milliseconds(250)
                )
            } catch {
                return
            }
        }
    }

    private var activeSkipSegment:
        PlaybackSkipSegment?
    {
        let position =
            session.position

        let active =
            skipSegments.filter {
                $0.contains(position)
            }

        guard !active.isEmpty else {
            return nil
        }

        // If databases contain overlapping
        // segments, prefer the action that
        // makes most sense to the viewer.
        let priority:
            [
                PlaybackSkipSegmentKind:
                    Int
            ] = [
                .recap: 0,
                .intro: 1,
                .outro: 2,
                .preview: 3,
            ]

        return active.min {
            priority[$0.kind, default: 99]
            <
            priority[$1.kind, default: 99]
        }
    }

    private func saveProgress(markNearEndFinished: Bool = false) {
        guard finishedContentID != model.request.contentID else { return }
        guard progressSaveSuspendedForContentID != model.request.contentID else { return }

        if let knownEndCreditsStart {
            if PlaybackCompletionPolicy.shouldFinishEpisodeOnExit(
                request: model.request,
                position: session.position,
                duration: session.duration,
                knownEndCreditsStart: knownEndCreditsStart
            ) {
                completeCurrentPlayback(autoPlayNext: false)
                return
            }
        } else if markNearEndFinished,
                  PlaybackCompletionPolicy.shouldFinishEpisodeOnExit(
                      request: model.request,
                      position: session.position,
                      duration: session.duration
                  ) {
            completeCurrentPlayback(autoPlayNext: false)
            return
        }

        library.updateProgress(request: model.request, position: session.position, duration: session.duration)
    }

    private var knownEndCreditsStart: TimeInterval? {
        guard let start = skipSegments.first(where: { $0.kind == .outro })?.start,
              start.isFinite,
              start > 0,
              session.duration.isFinite,
              start < session.duration else { return nil }
        return start
    }

    private func saveProgressEverySecond() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            saveProgress()
        }
    }

    private func handlePlaybackEnded() {
        completeCurrentPlayback(autoPlayNext: autoNext)
    }

    private func completeCurrentPlayback(autoPlayNext: Bool) {
        let completedRequest = model.request
        let queuedNextRequest = nextRequest
        finishedContentID = completedRequest.contentID
        library.markFinished(request: completedRequest, nextRequest: queuedNextRequest)

        if let queuedNextRequest {
            guard autoPlayNext else { return }
            playNext(queuedNextRequest)
            return
        }

        Task {
            let resolvedNextRequest = await resolveNextRequest(after: completedRequest)
            library.markFinished(request: completedRequest, nextRequest: resolvedNextRequest)
            guard autoPlayNext,
                  let resolvedNextRequest,
                  model.request.contentID == completedRequest.contentID else { return }
            playNext(resolvedNextRequest)
        }
    }

    private func playNext(_ request: PlaybackRequest) {
        guard pendingEpisodeLoad == nil else { return }
        let previousRequest = model.request
        pendingEpisodeLoad = PendingEpisodeLoad(
            previousRequest: previousRequest,
            request: request,
            previousSkipSegments: skipSegments,
            previousSkipSegmentsContentID: skipSegmentsContentID
        )
        progressSaveSuspendedForContentID = request.contentID
        session.resetProgressTracking()
        nextRequest = nil
        library.markPlaybackStarted(request: request)

        episodeLoadTask?.cancel()
        episodeLoadTask = Task {
            let loaded = await model.play(request, environment: environment,
                enabledSubtitleProviderIDs: enabledSubtitleProviderIDs,
                audioLanguage: animeAudioLanguage, backupAudioLanguage: animeBackupAudioLanguage,
                qualityHeight: defaultQualityHeight)

            guard !Task.isCancelled else { return }
            guard loaded else {
                cancelPendingEpisodeLoad()
                return
            }

            finishedContentID = nil
        }
    }

    private func finishPendingEpisodeLoadIfReady() {
        guard let pendingEpisodeLoad,
              model.request.contentID == pendingEpisodeLoad.request.contentID,
              session.activeContentID == pendingEpisodeLoad.request.contentID,
              !model.isLoading,
              !session.isBuffering,
              session.duration.isFinite,
              session.duration > 0 else { return }

        model.commitPendingPlayback()
        episodeLoadTask = nil
        self.pendingEpisodeLoad = nil
    }

    private func cancelPendingEpisodeLoad() {
        guard let pendingEpisodeLoad else { return }
        episodeLoadTask?.cancel()
        episodeLoadTask = nil
        model.cancelPendingPlayback()
        nextRequest = pendingEpisodeLoad.request
        progressSaveSuspendedForContentID = nil
        finishedContentID = pendingEpisodeLoad.previousRequest.contentID
        skipSegments = pendingEpisodeLoad.previousSkipSegments
        skipSegmentsContentID = pendingEpisodeLoad.previousSkipSegmentsContentID
        self.pendingEpisodeLoad = nil
    }

    private func closePlayerDuringLoading() {
        episodeLoadTask?.cancel()
        episodeLoadTask = nil
        model.cancel()
        session.stop()
        AppOrientationController.shared.endPlayback()
        dismiss()
    }

    private func playbackLoadingSubtitle(
        for request: PlaybackRequest
    ) -> String {
        guard let episode = request.episode else {
            return request.media.title
        }
        return "Season \(episode.seasonNumber) Episode \(episode.number)"
    }

    private func resolveNextRequest(after request: PlaybackRequest) async -> PlaybackRequest? {
        await nextUnwatchedPlaybackRequest(
            after: request,
            environment: environment,
            library: library
        )
    }

    private var enabledSubtitleProviderIDs: Set<String> {
        var providers: Set<String> = []

        if subDLSubtitlesEnabled {
            providers.insert("subdl")
        }

        if wizdomSubtitlesEnabled {
            providers.insert("wizdom")
        }

        if ktuvitSubtitlesEnabled {
            providers.insert("ktuvit")
        }

        if externalStreamSubtitlesEnabled {
            providers.insert(
                "external-stream-subtitles"
            )
        }

        return providers
    }

    private var playerOrientation: PlayerOrientationPreference {
        PlayerOrientationPreference(rawValue: playerOrientationRawValue) ?? .autoRotate
    }

    private func openSubtitleStudio() {
        Task {
            subtitleStudioContext = await session.beginSubtitleStudio()
        }
    }
}
