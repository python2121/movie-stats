import AppKit
import Charts
import QuickLook
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chatModel
    @Environment(\.openWindow) private var openWindow

    @State private var searchText = ""
    @State private var searchExpanded = false
    @FocusState private var searchFocused: Bool
    @State private var selectedMovie: MovieFile?
    @State private var sortMode: SortMode = .sizeDescending
    @State private var selectedTypes: Set<String> = []  // empty = all
    @State private var matchFilter: MatchFilter = .all
    @State private var watchFilter: WatchFilter = .all
    @State private var selectedGenres: Set<String> = []  // empty = all
    @State private var selectedDecades: Set<Int> = []    // empty = all
    @AppStorage("libraryViewMode") private var viewMode: ViewMode = .list
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var quickLookURL: URL?
    @State private var dropTargeted = false
    @State private var chatOpen = false
    /// Persisted between launches so the panel re-opens at the user's last
    /// chosen width. Default = `panelMinWidth` so a fresh install opens at
    /// the narrowest allowed size. Key suffix bumped to discard older saved
    /// values from earlier defaults.
    @AppStorage("aiPanelWidth_v2") private var panelWidth: Double = 280
    /// Live window width, captured via a background GeometryReader. Drives
    /// the dynamic max-panel-width calculation so the charts row never gets
    /// squeezed past its readable minimum.
    @State private var availableWidth: Double = 0
    /// Floor on the panel width.
    private static let panelMinWidth: Double = 280
    /// Hard ceiling on the panel width regardless of how big the window is.
    private static let panelAbsoluteMaxWidth: Double = 900
    /// Absolute smallest mainColumn we'll let the layout demand — used to
    /// compute the window's own minimum when the chat panel is open. Charts
    /// will be cramped at this size, but the app stays usable.
    private static let mainColumnAbsoluteMinWidth: Double = 690
    /// Threshold below which the two chart legends start bleeding past the
    /// card edges. Used only as the drag-clamp for the panel — never as a
    /// window minimum, so opening the panel doesn't force the window past
    /// this point. Bump up if you see legend text wrap, down if there's slack.
    private static let mainColumnMinWidth: Double = 1020

    /// Handle width — needs to be in the maxPanelWidth math so the panel
    /// can't push mainColumn past its minimum by exactly 6pt.
    private static let handleWidth: Double = 6

    /// The largest the side panel is allowed to be right now, given the
    /// current window width. Falls back to the absolute max while we haven't
    /// yet received a window-width measurement.
    private var maxPanelWidth: Double {
        guard availableWidth > 0 else { return Self.panelAbsoluteMaxWidth }
        let dynamicMax = max(Self.panelMinWidth, availableWidth - Self.mainColumnMinWidth - Self.handleWidth)
        return min(Self.panelAbsoluteMaxWidth, dynamicMax)
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case sizeDescending = "Largest First"
        case titleAscending = "Title A→Z"
        case ratingDescending = "Highest Rated"
        case yearDescending = "Newest First"
        case recentlyAdded = "Recently Added"
        case recentlyWatched = "Recently Watched"
        var id: String { rawValue }
    }

    /// Filters the main list by whether a file has been matched to a TMDB
    /// record. Driven by `MovieFile.tmdbId`.
    enum MatchFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case matched = "Matched"
        case unmatched = "Unmatched"
        var id: String { rawValue }
    }

    enum WatchFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case watched = "Watched"
        case unwatched = "Unwatched"
        var id: String { rawValue }
    }

    enum ViewMode: String {
        case list, grid
    }

    var body: some View {
        HStack(spacing: 0) {
            mainColumn

            if chatOpen {
                HStack(spacing: 0) {
                    ResizeHandle(
                        currentWidth: panelWidth,
                        onResize: { proposed in
                            panelWidth = max(Self.panelMinWidth, min(maxPanelWidth, proposed))
                        },
                        onDragEnded: {}
                    )
                    ChatPanel(model: chatModel) { chatOpen = false }
                        .frame(width: panelWidth)
                }
                .transition(.move(edge: .trailing))
            }
        }
        .frame(
            // Drives `.windowResizability(.contentMinSize)`. When the chat
            // panel is open, lift the window-min just enough that the panel
            // can fit alongside the *absolute* mainColumn floor — not the
            // chart-comfort threshold. That way opening the panel from a
            // moderately-narrow window doesn't snap the window much larger.
            minWidth: chatOpen
                ? Self.mainColumnAbsoluteMinWidth + Self.handleWidth + Self.panelMinWidth
                : Self.mainColumnAbsoluteMinWidth,
            minHeight: 380
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: chatOpen)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: AvailableWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(AvailableWidthKey.self) { newWidth in
            availableWidth = newWidth
            // If the user shrinks the window, pull the panel in so the charts
            // stay readable.
            let cap = maxPanelWidth
            if panelWidth > cap { panelWidth = cap }
        }
        .toolbar(id: "main") { toolbarContent }
        // Window-wide ⌘F — expands (or refocuses) the list filter field.
        .background(
            Button("") {
                searchExpanded = true
                searchFocused = true
            }
            .keyboardShortcut("f")
            .opacity(0)
            .accessibilityHidden(true)
        )
        // Dropping a folder anywhere on the window scans it as the library.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return false }
            model.setDirectory(url.path)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .navigationSubtitle(librarySubtitle)
        .sheet(isPresented: Binding(
            get: { model.isScanning || model.isProbing },
            set: { _ in }
        )) {
            ScanProgressSheet()
                .environment(model)
        }
        .sheet(item: $selectedMovie) { movie in
            MovieDetailSheet(movie: movie) { selectedMovie = nil }
                .background(DismissOnOutsideClick {
                    Task { @MainActor in selectedMovie = nil }
                })
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 8) {
                    CompactStatCard(title: "Movies", value: "\(model.movieCount)", systemImage: "film")
                    CompactStatCard(title: "Unwatched", value: "\(model.unwatchedCount)", systemImage: "eye.slash")
                    CompactStatCard(title: "Over 20 GB", value: "\(model.largeMovieCount)", systemImage: "externaldrive.badge.exclamationmark")
                    CompactStatCard(title: "Total Size", value: byteString(model.totalSize), systemImage: "internaldrive")
                }
                .frame(width: 170)
                .frame(maxHeight: .infinity)

                CategoryPieCard(title: "By movie count", slices: countSlices, valueKind: .count)
                    .frame(maxWidth: .infinity)

                CategoryPieCard(title: "By total size", slices: sizeSlices, valueKind: .bytes)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 200)

            if !model.ffprobeAvailable {
                Label(
                    "ffprobe not found — install ffmpeg via Homebrew to detect movie types.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            movieList
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Subviews

    /// Ranked list of every movie, largest first, with its size. The original
    /// size rank is preserved when the search filter narrows the list.
    private var movieList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.movies.isEmpty {
                Spacer()
                Text(model.hasDirectory
                    ? "No movies found."
                    : "Open a directory (⌘O) or drop a folder here to begin scanning.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                HStack(spacing: 10) {
                    Text("Library Details")
                        .font(.headline)
                    Spacer()
                    viewModePicker
                    sortMenu
                    filterMenu
                    searchControl
                }

                let rows = displayRows
                if rows.isEmpty {
                    Spacer()
                    Text(searchText.isEmpty ? "No movies match the current filters." : "No matches for \"\(searchText)\".")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer()
                } else if viewMode == .grid {
                    movieGrid(rows)
                } else {
                    movieRows(rows)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .quickLookPreview($quickLookURL)
    }

    private func movieRows(_ rows: [MovieRow]) -> some View {
        List {
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    Text("\(row.rank)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 28, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.representative.displayTitle)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            chips(for: row)
                        }
                        Text(row.representative.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if row.representative.watchedAt != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help(watchedTooltip(row.representative))
                    }
                    personalStars(for: row.representative)
                    if row.qualityVariantCount > 1 {
                        copyCountChip(row.qualityVariantCount)
                    }
                    Text(byteString(row.bestQualityTotalSize))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    imdbRatingChip(for: row.representative)
                    playControl(for: row)
                }
                .help(rowTooltip(row))
                .contentShape(Rectangle())
                .onTapGesture { selectedMovie = row.representative }
                .contextMenu { movieContextMenu(row) }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    /// Hover tooltip for a library row. Single-file rows mirror the
    /// pre-grouping behavior (just the path); multi-quality rows list
    /// every file so the user can spot which variants are bundled
    /// without opening the detail sheet.
    private func rowTooltip(_ row: MovieRow) -> String {
        guard row.fileCount > 1 else { return row.representative.path }
        return row.allFiles.map(\.path).joined(separator: "\n")
    }

    /// Plex-style poster wall. Same data, filters, and context menu as the
    /// list — just rendered as cached TMDB posters.
    private func movieGrid(_ rows: [MovieRow]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 14)],
                spacing: 14
            ) {
                ForEach(rows) { row in
                    PosterCard(movie: row.representative)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedMovie = row.representative }
                        .contextMenu { movieContextMenu(row) }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.representative.displayTitle)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { selectedMovie = row.representative }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func movieContextMenu(_ row: MovieRow) -> some View {
        let movie = row.representative
        // Multi-quality / multi-part / has-extras: Play becomes a
        // submenu so the user can pick a specific copy or extra
        // without opening the detail sheet. Plain row: regular Play
        // button.
        if row.fileCount > 1 || !row.extras.isEmpty {
            Menu("Play in \(ExternalPlayer.playerName)") {
                ForEach(row.allFiles) { file in
                    Button(playMenuLabel(for: file)) {
                        ExternalPlayer.play(path: file.path)
                    }
                }
                if !row.extras.isEmpty {
                    Section("Extras") {
                        ForEach(row.extras) { extra in
                            Button(extrasPlayMenuLabel(for: extra)) {
                                ExternalPlayer.play(path: extra.path)
                            }
                        }
                    }
                }
            }
        } else {
            Button("Play in \(ExternalPlayer.playerName)") {
                ExternalPlayer.play(path: movie.path)
            }
        }
        Button(movie.watchedAt == nil ? "Mark as Watched" : "Mark as Unwatched") {
            model.setWatched(movie, watched: movie.watchedAt == nil)
        }
        Button("Quick Look") {
            quickLookURL = URL(fileURLWithPath: movie.path)
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: movie.path)]
            )
        }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(movie.path, forType: .string)
        }
    }

    /// Play affordance shown on every library list row. When the row
    /// has a single on-disk copy this is just a button. When it has
    /// multiple copies (different qualities or versions of the same
    /// matched movie), it becomes a menu of "Play <type> (<size>)"
    /// items so the user picks which copy to launch.
    @ViewBuilder
    private func playControl(for row: MovieRow) -> some View {
        // Menu appears when there's more than one playable thing —
        // either multiple parts / qualities, OR there's just one
        // main file but the movie has attributed extras, OR both.
        let needsMenu = row.fileCount > 1 || !row.extras.isEmpty
        if needsMenu {
            Menu {
                ForEach(row.allFiles) { file in
                    Button(playMenuLabel(for: file)) {
                        ExternalPlayer.play(path: file.path)
                    }
                }
                if !row.extras.isEmpty {
                    Section("Extras") {
                        ForEach(row.extras) { extra in
                            Button(extrasPlayMenuLabel(for: extra)) {
                                ExternalPlayer.play(path: extra.path)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "play.circle")
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Play \(row.representative.displayTitle) — choose a copy")
            .help("Choose a part, quality, or extra to play in \(ExternalPlayer.playerName)")
        } else {
            Button {
                ExternalPlayer.play(path: row.representative.path)
            } label: {
                Image(systemName: "play.circle")
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Play \(row.representative.displayTitle)")
            .help("Play in \(ExternalPlayer.playerName)")
        }
    }

    /// Per-extra label used inside the Play menu — strips the file
    /// extension and middle-truncates long names so the menu rows
    /// stay manageable. Just the cleaned stem; the menu's own
    /// "Extras" section header carries the category context.
    private func extrasPlayMenuLabel(for extra: ExtraFile) -> String {
        let stem = (extra.filename as NSString).deletingPathExtension
        return Self.truncatedMiddle(stem, limit: 48)
    }

    /// Middle-truncates a string to fit a character `limit`, replacing
    /// the elided middle with an ellipsis. Returns the input
    /// unchanged when it's already short enough.
    private static func truncatedMiddle(_ s: String, limit: Int) -> String {
        guard s.count > limit, limit > 1 else { return s }
        let half = (limit - 1) / 2
        let prefix = s.prefix(half)
        let suffix = s.suffix(half)
        return "\(prefix)…\(suffix)"
    }

    /// Per-copy label used inside the Play menu of a multi-quality
    /// or multi-part row. Composed as `[Part N · ][type]`, with
    /// parts shown first because disc selection usually trumps
    /// quality selection when both dimensions vary. Falls back to
    /// the filename when `movie_type` isn't set yet (an unprobed
    /// row, basically).
    private func playMenuLabel(for file: MovieFile) -> String {
        var pieces: [String] = []
        if let part = file.partNumber {
            pieces.append("Part \(part)")
        }
        if let type = file.movieType, type != MovieType.unknown.rawValue {
            pieces.append(type)
        } else if file.partNumber == nil {
            // Unprobed solo file — fall back to filename so the menu
            // item isn't blank when neither part nor type is known.
            pieces.append(file.filename)
        }
        return pieces.joined(separator: " · ")
    }

    @ViewBuilder
    private func personalStars(for movie: MovieFile) -> some View {
        if let stars = movie.personalRating, stars > 0 {
            HStack(spacing: 1) {
                ForEach(1...stars, id: \.self) { _ in
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rated \(stars) of 5 stars")
            .help("Your rating: \(stars)/5")
        }
    }

    private func watchedTooltip(_ movie: MovieFile) -> String {
        guard let date = movie.watchedAt else { return "Watched" }
        return "Watched \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Expand-on-click filter control — collapses to a magnifying glass icon
    /// when empty and unfocused, so it stops stealing focus when the user
    /// clicks elsewhere.
    @ViewBuilder
    private var searchControl: some View {
        if searchExpanded {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter…", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { searchFocused = false }
                    .onExitCommand {
                        searchText = ""
                        searchFocused = false
                        searchExpanded = false
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filter")
                    .help("Clear filter")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .frame(width: 240)
            // Focus must land after the field joins the view hierarchy —
            // setting it synchronously in onAppear silently fails on macOS.
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    searchFocused = true
                }
            }
            .onChange(of: searchFocused) { _, focused in
                if !focused {
                    searchText = ""
                    searchExpanded = false
                }
            }
        } else {
            Button {
                searchExpanded = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Filter movies")
        }
    }

    /// IMDb rating chip — yellow-star + score — shown right of the size
    /// column when the movie has a TMDB match that carries an IMDb id AND
    /// that id is present in the imported IMDb ratings dataset. Hidden
    /// otherwise (no width reserved), so unmatched / un-rated rows fall
    /// back to the existing layout.
    @ViewBuilder
    private func imdbRatingChip(for movie: MovieFile) -> some View {
        if let rating = movie.imdbRating {
            HStack(spacing: 3) {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                Text(String(format: "%.1f", rating))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.yellow.opacity(0.15), in: Capsule())
            .fixedSize()
            .help(ratingTooltip(rating: rating, votes: movie.imdbVotes))
        }
    }

    /// Used by `imdbRatingChip` so the hover-help wording follows whether
    /// we have a vote count to show.
    private func ratingTooltip(rating: Double, votes: Int?) -> String {
        let base = String(format: "IMDb: %.1f / 10", rating)
        guard let votes else { return base }
        let formatted = NumberFormatter.localizedString(
            from: NSNumber(value: votes), number: .decimal
        )
        return "\(base)  (\(formatted) votes)"
    }

    /// Edition / type / HDR / DV / 10-bit pills shown next to a movie's
    /// filename. For multi-file rows the type / HDR pills are the
    /// **union** across every file in the group so a "4K Remux + 1080p"
    /// pair shows both classifier chips; DV and 10-bit fire if *any*
    /// file in the group has them. The edition chip (when set)
    /// renders first, leftmost, in a unique indigo so it reads as a
    /// distinct "which cut is this?" annotation rather than a
    /// quality attribute.
    @ViewBuilder
    private func chips(for row: MovieRow) -> some View {
        if let edition = row.customEdition, !edition.isEmpty {
            Chip(text: edition, color: .indigo)
        }
        if row.isMultiPart {
            Chip(text: "\(row.partNumbers.count) parts", color: .pink)
                .help("Multi-disc release — \(row.partNumbers.count) parts of the same movie. Plex / Jellyfin play them back-to-back; the row's Play menu lets you pick a specific disc.")
        }
        ForEach(row.movieTypes, id: \.self) { type in
            Chip(text: type, color: .blue)
        }
        if row.anyDolbyVision {
            Chip(text: "Dolby Vision", color: .purple)
        }
        ForEach(row.hdrFormats, id: \.self) { hdr in
            Chip(text: hdr, color: .orange)
        }
        if row.any10Bit {
            Chip(text: "10-bit", color: .teal)
        }
    }

    /// Small gray-on-outlined pill showing how many on-disk files this
    /// row represents. Same shape as `imdbRatingChip` (capsule, text-
    /// only, no icon) but in neutral gray so it doesn't compete with
    /// the rating's yellow. Rendered only when count > 1 — a solo file
    /// just shows the size with no chip to its left.
    private func copyCountChip(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.gray.opacity(0.18), in: Capsule())
            .fixedSize()
            .help("\(count) on-disk files for this entry — multiple quality / version copies.")
    }

    // MARK: - Pie chart slices

    private var countSlices: [CategorySlice] {
        categorySlices(value: { _ in 1.0 })
    }

    private var sizeSlices: [CategorySlice] {
        categorySlices(value: { Double($0.size) })
    }

    /// Groups `model.movies` by `movieType`, sums each group's contribution
    /// via `value`, and returns slices in a stable category order. Skips empty
    /// categories so the chart isn't cluttered.
    private func categorySlices(value: (MovieFile) -> Double) -> [CategorySlice] {
        let grouped = Dictionary(grouping: model.movies) { movie -> String in
            movie.movieType ?? "Unprobed"
        }
        let ordered = MovieType.allCases.map(\.rawValue) + ["Unprobed"]
        return ordered.compactMap { type in
            guard let bucket = grouped[type], !bucket.isEmpty else { return nil }
            let total = bucket.reduce(0.0) { $0 + value($1) }
            guard total > 0 else { return nil }
            return CategorySlice(type: type, value: total, color: Self.color(forCategory: type))
        }
    }

    private static func color(forCategory type: String) -> Color {
        switch type {
        case MovieType.uhdRemux.rawValue:     return .orange
        case MovieType.bluRayRemux.rawValue:  return .blue
        case MovieType.uhdEncode.rawValue:    return .red
        case MovieType.fullHDEncode.rawValue: return .teal
        case MovieType.hdEncode.rawValue:     return .green
        case MovieType.sd.rawValue:           return .brown
        case MovieType.unknown.rawValue:      return .gray
        case "Unprobed":                      return Color(white: 0.55)
        default:                              return .secondary
        }
    }

    /// Movies that survive every active filter (type / match / watch /
    /// genre / decade / search). No sort applied — the sorting unit
    /// is the *grouped row*, not the file, so it runs in
    /// `displayRows` after files have been collapsed into rows.
    /// Surfaced for non-list consumers (e.g. `pickRandomMovie`'s
    /// candidate pool) that just want the filtered file set.
    private var filteredMovies: [MovieFile] {
        var result: [MovieFile] = model.movies

        if !selectedTypes.isEmpty {
            result = result.filter { movie in
                selectedTypes.contains(movie.movieType ?? "Unprobed")
            }
        }

        switch matchFilter {
        case .all: break
        case .matched: result = result.filter { $0.tmdbId != nil }
        case .unmatched: result = result.filter { $0.tmdbId == nil }
        }

        switch watchFilter {
        case .all: break
        case .watched: result = result.filter { $0.watchedAt != nil }
        case .unwatched: result = result.filter { $0.watchedAt == nil }
        }

        if !selectedGenres.isEmpty {
            result = result.filter { movie in
                movie.genres.contains { selectedGenres.contains($0) }
            }
        }

        if !selectedDecades.isEmpty {
            result = result.filter { movie in
                guard let year = movie.effectiveYear else { return false }
                return selectedDecades.contains((year / 10) * 10)
            }
        }

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let needle = trimmed.lowercased()
            result = result.filter {
                $0.displayTitle.lowercased().contains(needle)
                    || $0.filename.lowercased().contains(needle)
            }
        }

        return result
    }

    /// The list shown in the main library view: filtered files
    /// collapsed into `(tmdbId, customEdition)` slots, sorted at the
    /// row level (size sort uses each row's best-quality total, not
    /// any one file's size), then ranked 1…N by sorted position.
    /// Replaces the older filter→sort→group pipeline that ranked
    /// rows by their first-file's position in the file-level sort —
    /// which broke for multi-part movies where the row's true size
    /// was the sum of its parts.
    private var displayRows: [MovieRow] {
        var groups: [String: [MovieFile]] = [:]
        var order: [String] = []
        for movie in filteredMovies {
            let key: String
            if let id = movie.tmdbId {
                let edition = (movie.customEdition ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                key = "tmdb:\(id)|\(edition)"
            } else {
                // Unmatched files can't be canonically grouped — give
                // each its own bucket keyed by path so iteration stays
                // stable across renders.
                key = "unmatched:\(movie.path)"
            }
            if groups[key] == nil {
                groups[key] = []
                order.append(key)
            }
            groups[key]!.append(movie)
        }

        // Index extras by TMDB id so each row picks up its own
        // attributed set in O(1) instead of scanning the global list
        // for every row.
        let extrasByTMDB: [Int: [ExtraFile]] = Dictionary(
            grouping: model.extras.filter { $0.parentTMDBId != nil },
            by: { $0.parentTMDBId! }
        )

        // Build unranked rows; intra-row file order is **quality-
        // major** — best quality bucket first, parts ascending
        // within a bucket, size descending as the tiebreak. So a 2-
        // disc 4K + 2-disc 1080p library row reads
        // `Part 1 (4K) → Part 2 (4K) → Part 1 (1080p) → Part 2 (1080p)`
        // in the Play menu. MovieType.allCases is the canonical
        // best→worst ordering (4K UHD Remux > 1080p Blu-ray Remux >
        // 4K Encode > 1080p Encode > 720p Encode > SD).
        let typeOrder: [String: Int] = Dictionary(
            uniqueKeysWithValues: MovieType.allCases.enumerated().map {
                ($1.rawValue, $0)
            }
        )
        let unranked: [MovieRow] = order.map { key in
            let files = groups[key]!
            let rep = files.max(by: { $0.size < $1.size }) ?? files[0]
            let sorted = files.sorted { a, b in
                let ai = a.movieType.flatMap { typeOrder[$0] } ?? Int.max
                let bi = b.movieType.flatMap { typeOrder[$0] } ?? Int.max
                if ai != bi { return ai < bi }
                switch (a.partNumber, b.partNumber) {
                case let (lhs?, rhs?) where lhs != rhs: return lhs < rhs
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.size > b.size
                }
            }
            let rowExtras = rep.tmdbId.flatMap { extrasByTMDB[$0] } ?? []
            let sortedExtras = rowExtras.sorted {
                $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }
            return MovieRow(
                rank: 0,
                representative: rep,
                allFiles: sorted,
                extras: sortedExtras
            )
        }

        // Sort the rows. Non-size sorts use the representative file's
        // attribute — for a (tmdbId, edition) group those are the
        // same across every file. Size sort uses the row's
        // best-quality total so multi-part movies sit at the rank
        // their on-disk size actually warrants.
        let sorted: [MovieRow]
        switch sortMode {
        case .sizeDescending:
            sorted = unranked.sorted { $0.bestQualityTotalSize > $1.bestQualityTotalSize }
        case .titleAscending:
            sorted = unranked.sorted {
                $0.representative.sortTitle
                    .localizedStandardCompare($1.representative.sortTitle) == .orderedAscending
            }
        case .ratingDescending:
            sorted = unranked.sorted { a, b in
                let ar = a.representative.imdbRating ?? -1
                let br = b.representative.imdbRating ?? -1
                if ar != br { return ar > br }
                return a.bestQualityTotalSize > b.bestQualityTotalSize
            }
        case .yearDescending:
            sorted = unranked.sorted { a, b in
                let ay = a.representative.effectiveYear ?? 0
                let by = b.representative.effectiveYear ?? 0
                if ay != by { return ay > by }
                return a.bestQualityTotalSize > b.bestQualityTotalSize
            }
        case .recentlyAdded:
            sorted = unranked.sorted {
                ($0.representative.firstSeenAt ?? .distantPast)
                    > ($1.representative.firstSeenAt ?? .distantPast)
            }
        case .recentlyWatched:
            sorted = unranked.sorted { a, b in
                let aw = a.representative.watchedAt ?? .distantPast
                let bw = b.representative.watchedAt ?? .distantPast
                if aw != bw { return aw > bw }
                return (a.representative.firstSeenAt ?? .distantPast)
                    > (b.representative.firstSeenAt ?? .distantPast)
            }
        }

        return sorted.enumerated().map { idx, row in
            MovieRow(
                rank: idx + 1,
                representative: row.representative,
                allFiles: row.allFiles,
                extras: row.extras
            )
        }
    }

    /// Sort order selector — small dropdown showing the current choice.
    private var sortMenu: some View {
        Menu {
            ForEach(SortMode.allCases) { mode in
                Button {
                    sortMode = mode
                } label: {
                    if mode == sortMode {
                        Label(mode.rawValue, systemImage: "checkmark")
                    } else {
                        Text(mode.rawValue)
                    }
                }
            }
        } label: {
            Label("Sort: \(sortMode.rawValue)", systemImage: "arrow.up.arrow.down")
                .font(.callout)
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// List ⟷ poster-wall switch, persisted across launches.
    private var viewModePicker: some View {
        Picker("View", selection: $viewMode) {
            Image(systemName: "list.bullet").tag(ViewMode.list)
                .help("List")
            Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
                .help("Poster wall")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// All library filters consolidated in a single menu so the controls
    /// row stays compact as filters accumulate.
    private var filterMenu: some View {
        Menu {
            Menu("Type") {
                ForEach(MovieType.allCases, id: \.rawValue) { type in
                    setToggle(type.rawValue, set: $selectedTypes)
                }
                setToggle("Unprobed", set: $selectedTypes)
            }
            Menu("Genre") {
                ForEach(allGenres, id: \.self) { genre in
                    setToggle(genre, set: $selectedGenres)
                }
            }
            Menu("Decade") {
                ForEach(allDecades, id: \.self) { decade in
                    Toggle("\(String(decade))s", isOn: Binding(
                        get: { selectedDecades.contains(decade) },
                        set: { on in
                            if on { selectedDecades.insert(decade) }
                            else { selectedDecades.remove(decade) }
                        }
                    ))
                }
            }
            Picker("TMDB Match", selection: $matchFilter) {
                ForEach(MatchFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Watched", selection: $watchFilter) {
                ForEach(WatchFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            Divider()
            Button("Clear All Filters") {
                selectedTypes.removeAll()
                selectedGenres.removeAll()
                selectedDecades.removeAll()
                matchFilter = .all
                watchFilter = .all
            }
            .disabled(activeFilterCount == 0)
        } label: {
            Label(
                activeFilterCount == 0 ? "Filters" : "Filters (\(activeFilterCount))",
                systemImage: "line.3.horizontal.decrease.circle"
            )
            .font(.callout)
            .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func setToggle(_ name: String, set: Binding<Set<String>>) -> some View {
        Toggle(name, isOn: Binding(
            get: { set.wrappedValue.contains(name) },
            set: { on in
                if on { set.wrappedValue.insert(name) }
                else { set.wrappedValue.remove(name) }
            }
        ))
    }

    private var activeFilterCount: Int {
        var count = selectedTypes.count + selectedGenres.count + selectedDecades.count
        if matchFilter != .all { count += 1 }
        if watchFilter != .all { count += 1 }
        return count
    }

    private var allGenres: [String] {
        Set(model.movies.flatMap(\.genres)).sorted()
    }

    private var allDecades: [Int] {
        Set(model.movies.compactMap { movie in
            movie.effectiveYear.map { ($0 / 10) * 10 }
        }).sorted(by: >)
    }

    /// Customizable (right-click → Customize Toolbar…) toolbar. Every action
    /// here is also reachable from the Library menu, so removing an item
    /// never strands the user.
    @ToolbarContentBuilder
    private var toolbarContent: some CustomizableToolbarContent {
        libraryToolbarItems
        toolWindowToolbarItems
        analysisToolbarItems
    }

    @ToolbarContentBuilder
    private var analysisToolbarItems: some CustomizableToolbarContent {
        ToolbarItem(id: "reports") {
            Button {
                openWindow(id: "reports")
            } label: {
                Label("Reports", systemImage: "checklist")
            }
            .disabled(!model.hasDirectory)
            .help("Library health reports: missing English subs, upgrade candidates, duplicates, and more")
        }

        ToolbarItem(id: "collections", showsByDefault: false) {
            Button {
                openWindow(id: "collections")
            } label: {
                Label("Collections", systemImage: "square.stack.3d.up")
            }
            .disabled(!model.hasDirectory)
            .help("Franchise completeness — what's missing from each TMDB collection you own part of")
        }

        ToolbarItem(id: "insights") {
            Button {
                openWindow(id: "insights")
            } label: {
                Label("Insights", systemImage: "chart.bar.xaxis")
            }
            .disabled(!model.hasDirectory)
            .help("Decade, genre, rating, and watch-progress analytics")
        }

    }

    @ToolbarContentBuilder
    private var libraryToolbarItems: some CustomizableToolbarContent {
        ToolbarItem(id: "open-directory") {
            Button {
                model.chooseDirectory()
            } label: {
                Label("Open Directory", systemImage: "folder")
            }
            .help("Choose a directory to scan")
        }

        ToolbarItem(id: "rescan") {
            Button {
                Task { await model.rescan() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(!model.hasDirectory || model.isScanning)
            .help("Rescan the current directory")
        }

        ToolbarItem(id: "reprobe", showsByDefault: false) {
            Button {
                Task { await model.reprobeAll() }
            } label: {
                Label("Reprobe", systemImage: "waveform.badge.magnifyingglass")
            }
            .disabled(!model.hasDirectory || model.isScanning || model.isProbing)
            .help("Re-read codec/resolution/HDR for every movie")
        }

        ToolbarItem(id: "import") {
            Button {
                openWindow(id: "import")
            } label: {
                Label("Import", systemImage: "tray.and.arrow.down")
            }
            .help("Walk a /complete-style folder through TMDB matching, cleanup, rename, and move into the library")
        }
    }

    @ToolbarContentBuilder
    private var toolWindowToolbarItems: some CustomizableToolbarContent {
        ToolbarItem(id: "scan-images", showsByDefault: false) {
            Button {
                openWindow(id: CleanupCategory.images.id)
            } label: {
                Label("Scan Images", systemImage: "photo.on.rectangle")
            }
            .disabled(!model.hasDirectory)
            .help("Scan this directory for images")
        }

        ToolbarItem(id: "scan-text", showsByDefault: false) {
            Button {
                openWindow(id: CleanupCategory.text.id)
            } label: {
                Label("Scan Text Files", systemImage: "doc.text")
            }
            .disabled(!model.hasDirectory)
            .help("Scan this directory for .txt and .nfo files")
        }

        ToolbarItem(id: "duplicates", showsByDefault: false) {
            Button {
                openWindow(id: "duplicates")
            } label: {
                Label("Find Duplicates", systemImage: "rectangle.stack.badge.play")
            }
            .disabled(!model.hasDirectory)
            .help("Find folders containing more than one video file")
        }

        ToolbarItem(id: "empty-folders", showsByDefault: false) {
            Button {
                openWindow(id: "empty-folders")
            } label: {
                Label("Find Empty Folders", systemImage: "folder.badge.minus")
            }
            .disabled(!model.hasDirectory)
            .help("Find folders that contain no files")
        }

        ToolbarItem(id: "tmdb-matcher") {
            Button {
                openWindow(id: "tmdb-matcher")
            } label: {
                Label("Match TMDB", systemImage: "popcorn")
            }
            .disabled(!model.hasDirectory)
            .help("Match unmatched movies to TMDB and cache the metadata")
        }

        ToolbarItem(id: "rename-library") {
            Button {
                openWindow(id: "rename-library")
            } label: {
                Label("Rename Library", systemImage: "pencil.line")
            }
            .disabled(!model.hasDirectory)
            .help("Rename matched movies into the canonical Plex / Jellyfin folder + filename format")
        }

        ToolbarItem(id: "imdb-ratings", showsByDefault: false) {
            Button {
                openWindow(id: "imdb-ratings")
            } label: {
                Label("IMDb Ratings", systemImage: "star.bubble")
            }
            .help("Download / refresh the IMDb bulk ratings dataset")
        }

        ToolbarItem(id: "surprise-me") {
            Button {
                pickRandomMovie()
            } label: {
                Label("Surprise Me", systemImage: "dice")
            }
            .disabled(model.movies.isEmpty)
            .help("Pick something to watch tonight — random, weighted toward unwatched, well-rated movies. Respects the current filters.")
        }

        ToolbarItem(id: "ask-claude") {
            if chatModel.hasClaudeCode {
                Button {
                    chatOpen.toggle()
                } label: {
                    Label("Ask Claude", systemImage: "sparkles")
                }
                .help(chatOpen ? "Close the Ask Claude panel" : "Ask Claude about your library")
            }
        }
    }

    /// "What should I watch tonight?" — weighted random pick from the
    /// currently-filtered movies, preferring unwatched titles and skewing
    /// toward higher IMDb ratings. Opens the pick's detail sheet.
    private func pickRandomMovie() {
        let pool = filteredMovies
        guard !pool.isEmpty else { return }
        let unwatched = pool.filter { $0.watchedAt == nil }
        let candidates = unwatched.isEmpty ? pool : unwatched
        let weighted = candidates.map { ($0, max(($0.imdbRating ?? 6.0) - 4.0, 0.5)) }
        let total = weighted.reduce(0.0) { $0 + $1.1 }
        var remaining = Double.random(in: 0..<total)
        for (movie, weight) in weighted {
            remaining -= weight
            if remaining <= 0 {
                selectedMovie = movie
                return
            }
        }
        selectedMovie = candidates.last
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Title-bar subtitle: plain text to the left of the toolbar icons —
    /// counts plus the library path (tilde-abbreviated to keep it short).
    private var librarySubtitle: String {
        var parts: [String] = []
        if model.movieCount > 0 {
            parts.append("\(model.movieCount) movies · \(byteString(model.totalSize))")
        }
        if model.hasDirectory {
            parts.append((model.directoryPath as NSString).abbreviatingWithTildeInPath)
        }
        return parts.joined(separator: " — ")
    }
}

/// In-window detail popup. Shows every metadata field we've collected for the
/// selected movie in an aligned two-column grid, with audio + subtitle tracks
/// broken out into their own tables below, plus a live TMDB lookup at the
/// bottom. Triggered by clicking a row in the main movie list; dismisses on
/// click-outside, Escape, or Done.
private struct MovieDetailSheet: View {
    /// The file the list/poster click handed us. Drives the initial
    /// active selection and the unique key for the sheet's task work;
    /// the user can flip to a sibling file via the multi-file
    /// switcher below the title, which sets `selectedFileID`.
    private let seedMovie: MovieFile
    let onClose: () -> Void

    init(movie: MovieFile, onClose: @escaping () -> Void) {
        self.seedMovie = movie
        self.onClose = onClose
    }

    enum TMDBState {
        case idle
        case loading
        case unmatched
        case loaded(TMDBMovieDetail)
        case failed(String)
    }

    @Environment(AppModel.self) private var appModel
    @State private var tmdbState: TMDBState = .idle
    @State private var externalSubtitles: [SubtitleFile] = []
    /// Bonus videos (deleted scenes, featurettes, etc.) attributed to
    /// any library file sharing this movie's TMDB id — unioned
    /// across alternate editions (Theatrical / Director's Cut /
    /// Despecialized) since extras belong to the *movie*, not to a
    /// specific cut. Loaded on appear; the file switcher above
    /// shouldn't change what shows here.
    @State private var extras: [ExtraFile] = []
    @State private var isWatched = false
    @State private var personalStars = 0
    @State private var fetchingTrailer = false
    @State private var trailerError: String?
    /// The currently-shown file in the sheet's per-file sections.
    /// `nil` falls back to `seedMovie`. Updated by the file switcher
    /// when this movie's group has multiple on-disk copies.
    @State private var selectedFileID: String?

    /// Every on-disk file that belongs to the same library row as
    /// `seedMovie` — same TMDB id, same custom edition. Sorted parts
    /// ascending first, then qualities largest-first, so the
    /// switcher reads `Part 1 → Part 2 → …` with each part's best
    /// quality on top. Unmatched seeds return just themselves (no
    /// siblings to group with).
    private var groupFiles: [MovieFile] {
        guard let tmdbId = seedMovie.tmdbId else { return [seedMovie] }
        let editionSlot: (String?) -> String = {
            ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let seedEdition = editionSlot(seedMovie.customEdition)
        let siblings = appModel.movies.filter {
            $0.tmdbId == tmdbId && editionSlot($0.customEdition) == seedEdition
        }
        if siblings.isEmpty { return [seedMovie] }
        return siblings.sorted { a, b in
            switch (a.partNumber, b.partNumber) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs < rhs
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.size > b.size
            }
        }
    }

    /// The file every per-file detail (grid, audio/subtitle tracks,
    /// external subs) is rendered against. Driven by the switcher's
    /// `selectedFileID`, with `seedMovie` as the fallback so the rest
    /// of the body keeps using `movie.X` unchanged.
    private var movie: MovieFile {
        if let id = selectedFileID,
           let match = groupFiles.first(where: { $0.id == id })
        {
            return match
        }
        return seedMovie
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(movie.displayTitle)
                    .font(.title3.bold())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(movie.filename)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(movie.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(.bottom, 14)

            if groupFiles.count > 1 {
                fileSwitcher(files: groupFiles)
                    .padding(.bottom, 14)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // File-info grid (left) + TMDB details (right), side by
                    // side at the top so the right-hand whitespace of the
                    // popup carries useful content instead of going empty.
                    // Audio + subtitle track tables stay full-width below.
                    HStack(alignment: .top, spacing: 20) {
                        Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 8) {
                            detailRow("Type", movie.movieType ?? "—")
                            detailRow("Size", ByteCountFormatter.string(fromByteCount: movie.size, countStyle: .file))
                            detailRow("Resolution", resolutionText)
                            detailRow("Duration", durationText)
                            detailRow("Bitrate", bitrateText)
                            detailRow("Video Codec", (movie.videoCodec ?? "—").uppercased())
                            detailRow("Container", movie.container ?? "—")
                            detailRow("Pixel Format", movie.pixFmt ?? "—")
                            detailRow("Bit Depth", movie.is10Bit ? "10-bit" : "8-bit")
                            detailRow("HDR", movie.hdrFormat ?? "—")
                            detailRow("Dolby Vision", movie.hasDolbyVision ? "Yes" : "No")
                            detailRow("Video Tracks", String(movie.videoTracks))
                            detailRow("Audio Tracks", String(movie.audioTracks))
                            detailRow("Subtitle Tracks", String(movie.subtitleTracks))
                            detailRow("Last Scanned", dateText(movie.dateScanned))
                            detailRow("Last Probed", movie.probedAt.map(dateText) ?? "—")
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                        Divider()

                        tmdbSection
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }

                    if !extras.isEmpty {
                        Divider()
                        extrasTable
                    }

                    // Audio + subtitle tracks side by side. When only one
                    // side has data, drop the divider and let it take the
                    // full width on its own.
                    if !movie.audioCodecs.isEmpty || !movie.subtitleCodecs.isEmpty {
                        Divider()
                        HStack(alignment: .top, spacing: 20) {
                            if !movie.audioCodecs.isEmpty {
                                audioTracksTable
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                            if !movie.audioCodecs.isEmpty && !movie.subtitleCodecs.isEmpty {
                                Divider()
                            }
                            if !movie.subtitleCodecs.isEmpty {
                                subtitleTracksTable
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                    }

                    if !externalSubtitles.isEmpty {
                        Divider()
                        externalSubtitlesTable
                    }
                }
                .padding(.vertical, 14)
            }
            .frame(maxHeight: 500)

            Divider()

            HStack(spacing: 14) {
                if groupFiles.count > 1 {
                    Menu {
                        ForEach(groupFiles) { file in
                            Button(detailPlayMenuLabel(for: file)) {
                                ExternalPlayer.play(path: file.path)
                            }
                        }
                    } label: {
                        Label("Play in \(ExternalPlayer.playerName)", systemImage: "play.fill")
                    }
                    .help("Pick a part / quality to launch in \(ExternalPlayer.playerName).")
                } else {
                    Button {
                        ExternalPlayer.play(path: movie.path)
                    } label: {
                        Label("Play in \(ExternalPlayer.playerName)", systemImage: "play.fill")
                    }
                }
                if movie.tmdbId != nil {
                    Button {
                        watchTrailer()
                    } label: {
                        if fetchingTrailer {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Trailer", systemImage: "movieclapper")
                        }
                    }
                    .disabled(fetchingTrailer)
                    .help("Find this movie's trailer on TMDB and open it on YouTube")
                }
                if let trailerError {
                    Text(trailerError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Toggle("Watched", isOn: Binding(
                    get: { isWatched },
                    set: { on in
                        isWatched = on
                        appModel.setWatched(movie, watched: on)
                    }
                ))
                .toggleStyle(.checkbox)
                starPicker
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        .padding(28)
        .frame(width: 760)
        .onExitCommand { onClose() }
        .task(id: movie.id) {
            isWatched = movie.watchedAt != nil
            personalStars = movie.personalRating ?? 0
            guard let store = appModel.store else { return }
            externalSubtitles = (try? store.subtitleFiles(forMoviePath: movie.path)) ?? []
            // Extras are attributed at import time to a *specific*
            // matched movie file. The library may have several files
            // for the same TMDB id (4K + 1080p of the same edition
            // collapse into one row via `groupFiles`; alternate
            // *editions* like Director's Cut stay as their own
            // rows). Either way the extras belong to the movie, not
            // to a cut — walk every library file sharing this TMDB
            // id, union their attributed rows, and dedupe by path.
            // Unmatched seed → just this file's attributed extras
            // (typically empty).
            var seen = Set<String>()
            var collected: [ExtraFile] = []
            let lookupPaths: [String]
            if let tmdbID = seedMovie.tmdbId {
                lookupPaths = appModel.movies
                    .filter { $0.tmdbId == tmdbID }
                    .map(\.path)
            } else {
                lookupPaths = [seedMovie.path]
            }
            for lookupPath in lookupPaths {
                let rows = (try? store.extras(forMoviePath: lookupPath)) ?? []
                for row in rows where !seen.contains(row.path) {
                    seen.insert(row.path)
                    collected.append(row)
                }
            }
            extras = collected.sorted {
                $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }
        }
    }

    private func watchTrailer() {
        guard let tmdbID = movie.tmdbId else { return }
        fetchingTrailer = true
        trailerError = nil
        Task {
            defer { fetchingTrailer = false }
            do {
                if let url = try await TMDBService.trailer(forID: tmdbID)?.youtubeURL {
                    NSWorkspace.shared.open(url)
                } else {
                    trailerError = "No trailer on TMDB."
                }
            } catch {
                trailerError = error.localizedDescription
            }
        }
    }

    /// Click a star to rate 1–5; click the current rating again to clear it.
    private var starPicker: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    let newValue = personalStars == star ? 0 : star
                    personalStars = newValue
                    appModel.setPersonalRating(movie, rating: newValue == 0 ? nil : newValue)
                } label: {
                    Image(systemName: star <= personalStars ? "star.fill" : "star")
                        .foregroundStyle(star <= personalStars ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rate \(star) star\(star == 1 ? "" : "s")")
            }
        }
        .help("Your rating — click the same star again to clear")
    }

    // MARK: - Multi-file switcher

    /// Stacked card list shown only when a row owns more than one
    /// on-disk file (multi-quality copies of the same TMDB id +
    /// edition). Each card surfaces filename + a concise chip
    /// summary; clicking flips the rest of the sheet to that file's
    /// data.
    @ViewBuilder
    private func fileSwitcher(files: [MovieFile]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files (\(files.count))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(files) { file in
                    fileSwitcherCard(file: file, isActive: file.id == movie.id)
                }
            }
        }
    }

    /// One row in the multi-file switcher. The active row gets an
    /// accent background and a filled radio mark; inactive rows stay
    /// quaternary. Whole card is the hit target.
    @ViewBuilder
    private func fileSwitcherCard(file: MovieFile, isActive: Bool) -> some View {
        Button {
            selectedFileID = file.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .font(.callout)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.filename)
                        .font(.callout.weight(isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    fileSwitcherSummary(file: file)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive
                          ? Color.accentColor.opacity(0.12)
                          : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isActive
                                  ? Color.accentColor.opacity(0.45)
                                  : Color.clear,
                                  lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(file.path)
    }

    /// Inline chip + bullet summary used inside each switcher card —
    /// the same chip palette as the main library list (`Chip`) plus
    /// resolution / codec / size as light bullet text. Designed to
    /// fit on one line for typical libraries; truncates at the right
    /// edge otherwise.
    @ViewBuilder
    private func fileSwitcherSummary(file: MovieFile) -> some View {
        let resolution: String? = {
            if let w = file.width, let h = file.height, w > 0, h > 0 {
                return "\(w)×\(h)"
            }
            return nil
        }()
        let codec = file.videoCodec?.uppercased()
        let size = ByteCountFormatter.string(
            fromByteCount: file.size, countStyle: .file
        )
        HStack(spacing: 6) {
            if let part = file.partNumber {
                Chip(text: "Part \(part)", color: .pink)
            }
            if let type = file.movieType, type != MovieType.unknown.rawValue {
                Chip(text: type, color: .secondary)
            }
            if file.hasDolbyVision { Chip(text: "DV", color: .blue) }
            if let hdr = file.hdrFormat { Chip(text: hdr, color: .orange) }
            if file.is10Bit { Chip(text: "10-bit", color: .purple) }
            bulletText(
                [resolution, codec, size].compactMap { $0 }
            )
        }
    }

    /// Joins non-empty fragments with " • " separators and renders
    /// them as one secondary caption line — used by the switcher
    /// summary to keep resolution / codec / size visually grouped.
    @ViewBuilder
    private func bulletText(_ fragments: [String]) -> some View {
        Text(fragments.joined(separator: " • "))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    // MARK: - Track tables

    /// Per-track audio table: index, language, codec, channels. One row per
    /// stream — never collapsed, scrolls naturally inside the parent ScrollView.
    private var audioTracksTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text("#").gridColumnAlignment(.trailing)
                    Text("Language")
                    Text("Codec")
                    Text("Channels")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                Divider().gridCellUnsizedAxes(.horizontal)

                ForEach(Array(movie.audioCodecs.enumerated()), id: \.offset) { idx, codec in
                    GridRow {
                        Text("\(idx + 1)")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(Self.localizedLanguage(at: idx, in: movie.audioLanguages))
                        Text(Self.audioCodecLabel(codec))
                        Text(audioChannelText(at: idx))
                            .font(.callout.monospacedDigit())
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                }
            }
        }
    }

    /// Per-track subtitle table: index, language, codec. Compact, no channel
    /// column since subtitles don't have one.
    private var subtitleTracksTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subtitles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text("#").gridColumnAlignment(.trailing)
                    Text("Language")
                    Text("Codec")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                Divider().gridCellUnsizedAxes(.horizontal)

                ForEach(Array(movie.subtitleCodecs.enumerated()), id: \.offset) { idx, codec in
                    GridRow {
                        Text("\(idx + 1)")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(Self.localizedLanguage(at: idx, in: movie.subtitleLanguages))
                        Text(Self.subtitleCodecLabel(codec))
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                }
            }
        }
    }

    /// Sidecar subtitle files on disk (from the `subtitle_files` table) —
    /// distinct from the embedded subtitle *tracks* above.
    private var externalSubtitlesTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subtitle Files (\(externalSubtitles.count))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text("#").gridColumnAlignment(.trailing)
                    Text("Language")
                    Text("Flags")
                    Text("Format")
                    Text("File")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                Divider().gridCellUnsizedAxes(.horizontal)

                ForEach(Array(externalSubtitles.enumerated()), id: \.element.id) { idx, sub in
                    GridRow {
                        Text("\(idx + 1)")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(sub.language.map { Self.localizedLanguage(code: $0) } ?? "—")
                        Text(subtitleFlags(sub))
                        Text(sub.format.uppercased())
                        Text(sub.filename)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(sub.path)
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                }
            }
        }
    }

    /// Bonus videos parked in the movie's `Other/` (or future
    /// category) subfolder. Surfaced from the `extras` table that
    /// the import wizard's Rename step writes. Each row gets a Play
    /// button that launches the file in the external player.
    private var extrasTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Extras (\(extras.count))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text("#").gridColumnAlignment(.trailing)
                    Text("Category")
                    Text("Size").gridColumnAlignment(.trailing)
                    Text("File")
                    Text("").gridColumnAlignment(.center)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                Divider().gridCellUnsizedAxes(.horizontal)

                ForEach(Array(extras.enumerated()), id: \.element.id) { idx, extra in
                    GridRow {
                        Text("\(idx + 1)")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(extra.category)
                        Text(ByteCountFormatter.string(fromByteCount: extra.size, countStyle: .file))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text((extra.filename as NSString).deletingPathExtension)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(extra.path)
                        Button {
                            ExternalPlayer.play(path: extra.path)
                        } label: {
                            Image(systemName: "play.circle")
                                .imageScale(.medium)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Play \((extra.filename as NSString).deletingPathExtension)")
                        .help("Play in \(ExternalPlayer.playerName)")
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                }
            }
        }
    }

    /// Per-file label for the detail-sheet Play menu — mirrors the
    /// library-list `playMenuLabel` so the user sees the same
    /// `[Part N · ][quality · ]<size>` composition in both places.
    /// Falls back to the filename for unprobed solo files so the
    /// menu item isn't just a bare size.
    private func detailPlayMenuLabel(for file: MovieFile) -> String {
        var pieces: [String] = []
        if let part = file.partNumber {
            pieces.append("Part \(part)")
        }
        if let type = file.movieType, type != MovieType.unknown.rawValue {
            pieces.append(type)
        } else if file.partNumber == nil {
            pieces.append(file.filename)
        }
        pieces.append(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
        return pieces.joined(separator: " · ")
    }

    private func subtitleFlags(_ sub: SubtitleFile) -> String {
        var flags: [String] = []
        if let descriptor = sub.descriptor { flags.append(descriptor) }
        if sub.isSDH { flags.append("SDH") }
        if sub.isForced { flags.append("forced") }
        return flags.isEmpty ? "—" : flags.joined(separator: ", ")
    }

    private func audioChannelText(at idx: Int) -> String {
        let channels = idx < movie.audioChannels.count ? movie.audioChannels[idx] : 0
        let label = Self.channelLabel(channels)
        return label.isEmpty ? "—" : label
    }

    // MARK: - TMDB

    @ViewBuilder
    private var tmdbSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TMDB")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            switch tmdbState {
            case .idle, .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .unmatched:
                Label("Not matched yet. Use the toolbar's “Match TMDB” to look it up.",
                      systemImage: "popcorn")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .loaded(let detail):
                tmdbResult(detail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: movie.id) {
            loadTMDB()
        }
    }

    @ViewBuilder
    private func tmdbResult(_ detail: TMDBMovieDetail) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if let poster = PosterCache.loadPoster(forTMDBID: detail.id) {
                Image(nsImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(detail.title)
                        .font(.body.weight(.semibold))
                        .textSelection(.enabled)
                    if let year = detail.year {
                        Text("(\(year))")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }

                if let tagline = detail.tagline, !tagline.isEmpty {
                    Text(tagline)
                        .font(.caption.italic())
                        .foregroundStyle(.secondary)
                }

                Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 4) {
                    if let release = detail.releaseDate, !release.isEmpty {
                        detailRow("Released", release)
                    }
                    if let runtime = detail.runtime, runtime > 0 {
                        detailRow("Runtime", "\(runtime) min")
                    }
                    if let avg = detail.voteAverage, let count = detail.voteCount, count > 0 {
                        detailRow("Rating", String(format: "%.1f / 10  (%d votes)", avg, count))
                    }
                    if let genres = detail.genres, !genres.isEmpty {
                        detailRow("Genres", genres.map(\.name).joined(separator: ", "))
                    }
                    if let original = detail.originalTitle, original != detail.title {
                        detailRow("Original Title", original)
                    }
                    if let status = detail.status, !status.isEmpty {
                        detailRow("Status", status)
                    }
                    if let imdb = detail.imdbID, !imdb.isEmpty {
                        detailLinkRow("IMDb", imdb, url: "https://www.imdb.com/title/\(imdb)/")
                    }
                    detailLinkRow("TMDB ID", String(detail.id), url: "https://www.themoviedb.org/movie/\(detail.id)")
                }

                if let overview = detail.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Reads the cached TMDB detail from the local DB (no live API call). The
    /// matcher window is responsible for populating that DB.
    private func loadTMDB() {
        guard let tmdbID = movie.tmdbId else {
            tmdbState = .unmatched
            return
        }
        tmdbState = .loading
        do {
            if let detail = try appModel.store?.tmdbDetail(forID: tmdbID) {
                tmdbState = .loaded(detail)
            } else {
                tmdbState = .failed("TMDB cache empty for id \(tmdbID).")
            }
        } catch {
            tmdbState = .failed(error.localizedDescription)
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func detailLinkRow(_ label: String, _ value: String, url: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            if let destination = URL(string: url) {
                Link(value, destination: destination)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(url)
            } else {
                Text(value)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Field formatters

    private var resolutionText: String {
        guard let w = movie.width, let h = movie.height, w > 0, h > 0 else { return "—" }
        return "\(w)×\(h)"
    }

    private var durationText: String {
        guard let seconds = movie.durationSeconds, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    private var bitrateText: String {
        guard let bitrate = movie.bitrate, bitrate > 0 else { return "—" }
        let mbps = Double(bitrate) / 1_000_000
        return String(format: "%.1f Mbps", mbps)
    }

    /// Up to this many tracks, list each one individually with its codec; past
    /// it, fall back to a grouped count so long subtitle/audio lists stay
    /// readable.
    private static let detailedListThreshold = 5

    private var audioTracksDetail: String {
        Self.tracksDetail(
            total: movie.audioTracks,
            codecs: movie.audioCodecs,
            languages: movie.audioLanguages,
            codecLabeler: Self.audioCodecLabel,
            perTrackSuffix: { idx in
                let ch = idx < movie.audioChannels.count ? movie.audioChannels[idx] : 0
                return Self.channelLabel(ch)
            }
        )
    }

    private var subtitleTracksDetail: String {
        Self.tracksDetail(
            total: movie.subtitleTracks,
            codecs: movie.subtitleCodecs,
            languages: movie.subtitleLanguages,
            codecLabeler: Self.subtitleCodecLabel,
            perTrackSuffix: { _ in "" }
        )
    }

    /// Shared formatter for audio + subtitle track lists. Short lists are
    /// shown per-track; long lists are grouped — by language when at least one
    /// track is tagged with a real language, by codec when every track is
    /// `und` (so the file gives us nothing to group on language-wise).
    private static func tracksDetail(
        total: Int,
        codecs: [String],
        languages: [String],
        codecLabeler: (String) -> String,
        perTrackSuffix: (Int) -> String
    ) -> String {
        guard total > 0 else { return "0" }
        guard !codecs.isEmpty else { return "\(total)" }

        if codecs.count <= detailedListThreshold {
            let parts = codecs.enumerated().map { idx, codec in
                let lang = localizedLanguage(at: idx, in: languages)
                let codecLabel = codecLabeler(codec)
                let suffix = perTrackSuffix(idx)
                var bits: [String] = []
                if lang != "Unknown" { bits.append(lang) }
                bits.append(codecLabel)
                if !suffix.isEmpty { bits.append(suffix) }
                return bits.joined(separator: " ")
            }
            return "\(total) — \(parts.joined(separator: ", "))"
        }

        let hasKnownLanguage = languages.contains { code in
            let lower = code.lowercased()
            return !lower.isEmpty && lower != "und" && lower != "unknown"
        }
        let grouped = hasKnownLanguage
            ? groupedByLanguage(languages, totalTracks: codecs.count)
            : groupedByCodec(codecs, labeler: codecLabeler)
        return "\(total) — \(grouped)"
    }

    /// Groups raw ISO 639 codes into "English ×40, French ×12, Unknown ×3"
    /// summary text, ordered by descending count. `totalTracks` is the number
    /// of stream entries — when `languages` is shorter (legacy DB rows), the
    /// remainder is counted as Unknown.
    private static func groupedByLanguage(_ languages: [String], totalTracks: Int) -> String {
        var counts: [String: Int] = [:]
        for i in 0..<totalTracks {
            let code = i < languages.count ? languages[i] : "und"
            let name = localizedLanguage(code: code)
            counts[name, default: 0] += 1
        }
        return counts
            .sorted { ($0.value, $0.key) > ($1.value, $1.key) }
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: ", ")
    }

    /// Falls back for files where every track is `und` — groups by codec so
    /// the user still sees something useful (e.g. "SRT ×47, PGS ×16").
    private static func groupedByCodec(_ codecs: [String], labeler: (String) -> String) -> String {
        var counts: [String: Int] = [:]
        for codec in codecs {
            counts[labeler(codec), default: 0] += 1
        }
        return counts
            .sorted { ($0.value, $0.key) > ($1.value, $1.key) }
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: ", ")
    }

    /// Friendly display names for the codec strings ffprobe emits. Falls back
    /// to the raw value uppercased so an unknown codec is still legible.
    private static func subtitleCodecLabel(_ codec: String) -> String {
        switch codec.lowercased() {
        case "subrip":             return "SRT"
        case "hdmv_pgs_subtitle":  return "PGS"
        case "dvd_subtitle":       return "VobSub"
        case "ass":                return "ASS"
        case "ssa":                return "SSA"
        case "mov_text":           return "MOV Text"
        case "webvtt":             return "WebVTT"
        case "":                   return "?"
        default:                   return codec
        }
    }

    private static func audioCodecLabel(_ codec: String) -> String {
        switch codec.lowercased() {
        case "truehd":             return "TrueHD"
        case "dts":                return "DTS"
        case "eac3":               return "E-AC-3"
        case "ac3":                return "AC-3"
        case "aac":                return "AAC"
        case "flac":               return "FLAC"
        case "mp3":                return "MP3"
        case "opus":               return "Opus"
        case "vorbis":             return "Vorbis"
        case "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le":
            return "PCM"
        case "":                   return "?"
        default:                   return codec.uppercased()
        }
    }

    private static func localizedLanguage(at index: Int, in languages: [String]) -> String {
        let code = index < languages.count ? languages[index] : "und"
        return localizedLanguage(code: code)
    }

    private static func localizedLanguage(code: String) -> String {
        let normalized = code.lowercased()
        guard !normalized.isEmpty, normalized != "und" else { return "Unknown" }
        if let name = Locale(identifier: "en_US").localizedString(forLanguageCode: normalized) {
            return name.capitalized
        }
        return normalized.uppercased()
    }

    private static func channelLabel(_ count: Int) -> String {
        switch count {
        case 0: return ""
        case 1: return "1.0"
        case 2: return "2.0"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return "\(count)ch"
        }
    }

    private func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

/// Modal progress sheet shown for the duration of a library scan + probe.
/// Two phases: indeterminate during the directory walk, then a determinate
/// progress bar with the file currently being probed.
private struct ScanProgressSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scanning library")
                .font(.headline)

            if model.isScanning {
                ProgressView()
                    .progressViewStyle(.linear)
                Text("Scanning directory for movie files…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView(
                    value: Double(model.probedCount),
                    total: Double(max(model.probeTotal, 1))
                )
                .progressViewStyle(.linear)

                HStack {
                    Text("Reading metadata")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.probedCount) / \(model.probeTotal)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let path = model.currentProbePath {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                if model.cancelRequested {
                    Text("Finishing the files already in flight…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.cancelScan() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.cancelRequested)
                    .help("Stop after the files currently being read — already-probed metadata is kept, and the next Rescan resumes from here")
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }
}

/// One tile in the poster wall: cached TMDB poster (or a placeholder for
/// unmatched movies), title, year, size, and a watched badge.
private struct PosterCard: View {
    let movie: MovieFile
    @State private var posterImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                poster
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if movie.watchedAt != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .green)
                        .padding(6)
                        .help("Watched")
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(movie.displayTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: movie.size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let rating = movie.imdbRating {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                            Text(String(format: "%.1f", rating))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .help(movie.path)
        .task(id: movie.id) {
            guard let id = movie.tmdbId else { return }
            posterImage = PosterCache.loadPoster(forTMDBID: id)
            // Matches confirmed before poster caching existed have no local
            // artwork — fetch lazily as the cell scrolls into view.
            if posterImage == nil, let path = movie.posterPath {
                if await PosterCache.downloadIfNeeded(tmdbID: id, posterPath: path) {
                    posterImage = PosterCache.loadPoster(forTMDBID: id)
                }
            }
        }
    }

    @ViewBuilder
    private var poster: some View {
        if let image = posterImage {
            Image(nsImage: image)
                .resizable()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.6))
                VStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(movie.displayTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 8)
                }
            }
        }
    }
}

/// A small capsule tag rendered next to a movie's filename to surface a
/// classification or flag (type, HDR, DV, 10-bit).
private struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .fixedSize()
    }
}

/// One library-table row, possibly representing several on-disk files
/// (different qualities of the same TMDB id + edition). The
/// representative is the largest file in the group and drives most of
/// the row's appearance (title, path, rating, click target); the
/// aggregated accessors below merge attributes across every file so
/// the user sees the full quality picture without duplicate rows.
struct MovieRow: Identifiable {
    let rank: Int
    let representative: MovieFile
    let allFiles: [MovieFile]
    /// Bonus videos attributed to this movie's TMDB id (unioned
    /// across editions — extras belong to the *movie*, not a cut).
    /// Empty for unmatched rows or movies with no recorded extras.
    /// Sorted by filename for stable ordering in the Play menu.
    let extras: [ExtraFile]

    var id: String { representative.id }
    var fileCount: Int { allFiles.count }
    /// Sum of every file's size in the group, for the size column.
    /// Multi-quality entries report total disk usage rather than just
    /// the representative's footprint.
    var totalSize: Int64 { allFiles.reduce(Int64(0)) { $0 + $1.size } }
    /// Custom edition (e.g. "Director's Cut") if set. Identical across
    /// every file in the group because edition is part of the
    /// grouping key.
    var customEdition: String? { representative.customEdition }

    /// All distinct classifier buckets present in the group, ordered
    /// as in `MovieType.allCases` so the row's chip cluster reads
    /// best-quality-first regardless of which file was the
    /// representative. "Unknown" is excluded — that bucket means
    /// "haven't probed yet" and isn't a meaningful chip.
    var movieTypes: [String] {
        let present = Set(allFiles.compactMap(\.movieType))
            .filter { $0 != MovieType.unknown.rawValue }
        return MovieType.allCases.map(\.rawValue).filter { present.contains($0) }
    }
    var anyDolbyVision: Bool { allFiles.contains(where: { $0.hasDolbyVision }) }
    /// Unique HDR formats present across the group, sorted so chip
    /// order doesn't reshuffle from one render to the next.
    var hdrFormats: [String] {
        Array(Set(allFiles.compactMap(\.hdrFormat))).sorted()
    }
    var any10Bit: Bool { allFiles.contains(where: { $0.is10Bit }) }

    /// Unique disc / part numbers present in the group, sorted. A row
    /// containing only single-file movies returns `[]`; a 2-disc set
    /// returns `[1, 2]`. Drives the multi-part chip + Play menu.
    var partNumbers: [Int] {
        Array(Set(allFiles.compactMap(\.partNumber))).sorted()
    }
    /// True iff this row spans multiple discs / parts of the same
    /// movie. Mixed groups (some files with parts, some without) also
    /// count — they're still a multi-part presentation.
    var isMultiPart: Bool { partNumbers.count >= 2 }

    /// Number of distinct quality buckets present in the group (4K
    /// UHD Remux, 1080p Encode, …). Unprobed rows contribute
    /// nothing to the count. Drives the right-hand count chip — that
    /// chip is reserved for multi-quality rows; multi-part-only rows
    /// already carry the left-hand "N parts" chip and shouldn't get
    /// counted on the right too.
    var qualityVariantCount: Int {
        Set(allFiles.compactMap(\.movieType))
            .filter { $0 != MovieType.unknown.rawValue }
            .count
    }

    /// Best quality bucket present in the group, chosen by
    /// `MovieType.allCases` order (4K UHD Remux > 1080p Blu-ray Remux
    /// > 4K Encode > 1080p Encode > 720p Encode > SD). nil when
    /// nothing in the group has been probed yet.
    var bestMovieType: String? {
        let present = Set(allFiles.compactMap(\.movieType))
            .filter { $0 != MovieType.unknown.rawValue }
        return MovieType.allCases
            .map(\.rawValue)
            .first(where: { present.contains($0) })
    }

    /// Files at the row's best quality bucket. The "redundant
    /// lower-quality copies" answer to the question "how big is this
    /// movie on disk?" — those are sibling versions, not part of the
    /// canonical answer. Falls back to every file when no probe data
    /// is available yet, so partial states still show a meaningful
    /// size.
    var bestQualityFiles: [MovieFile] {
        guard let best = bestMovieType else { return allFiles }
        return allFiles.filter { $0.movieType == best }
    }

    /// Size shown in the library table + used by the size-descending
    /// sort. Sum of every part of the row's best quality variant —
    /// excludes lower-quality redundant copies (and, separately,
    /// extras, which aren't in `allFiles` to begin with).
    var bestQualityTotalSize: Int64 {
        bestQualityFiles.reduce(Int64(0)) { $0 + $1.size }
    }
}

/// Compact stat tile used in the narrow left column. Icon + small caption +
/// rounded value, in one horizontal row.
private struct CompactStatCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One wedge in a category pie chart.
private struct CategorySlice: Identifiable {
    let type: String
    let value: Double
    let color: Color
    var id: String { type }
}

/// Donut chart tile showing how a metric splits across the library categories.
/// The legend on the right lists each category with its raw value next to the
/// label (count or human-readable size depending on `valueKind`).
private struct CategoryPieCard: View {
    enum ValueKind { case count, bytes }

    let title: String
    let slices: [CategorySlice]
    let valueKind: ValueKind

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if slices.isEmpty {
                Spacer()
                Text("No data yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("Share", slice.value),
                        innerRadius: .ratio(0.55),
                        angularInset: 1.5
                    )
                    .cornerRadius(2)
                    .foregroundStyle(by: .value("Category", slice.type))
                }
                .chartForegroundStyleScale(
                    domain: slices.map(\.type),
                    range: slices.map(\.color)
                )
                .chartLegend(position: .trailing, alignment: .center, spacing: 6) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(slices) { slice in
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(slice.color)
                                    .frame(width: 8, height: 8)
                                Text(slice.type)
                                    .font(.caption)
                                    .foregroundColor(Color.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text(formattedValue(slice))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(Color.secondary)
                            }
                        }
                    }
                    .frame(width: 180)
                    .tint(Color.primary)
                    .foregroundColor(Color.primary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func formattedValue(_ slice: CategorySlice) -> String {
        switch valueKind {
        case .count:
            return "\(Int(slice.value))"
        case .bytes:
            return ByteCountFormatter.string(fromByteCount: Int64(slice.value), countStyle: .file)
        }
    }
}

/// PreferenceKey used to bubble the window/host width up to `ContentView` so
/// the AI panel's max resize width can be clamped against it.
private struct AvailableWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
