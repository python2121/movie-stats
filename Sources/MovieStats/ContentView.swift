import AppKit
import Charts
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @State private var searchText = ""
    @State private var searchExpanded = false
    @FocusState private var searchFocused: Bool
    @State private var selectedMovie: MovieFile?
    @State private var sortMode: SortMode = .sizeDescending
    @State private var selectedTypes: Set<String> = []  // empty = all

    enum SortMode: String, CaseIterable, Identifiable {
        case sizeDescending = "Largest First"
        case titleAscending = "Title A→Z"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 8) {
                    CompactStatCard(title: "Movies", value: "\(model.movieCount)", systemImage: "film")
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

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            movieList
        }
        .padding(28)
        .frame(minWidth: 600, minHeight: 380)
        .toolbar { toolbarContent }
        .sheet(isPresented: Binding(
            get: { model.isScanning || model.isProbing },
            set: { _ in }
        )) {
            ScanProgressSheet()
                .environment(model)
        }
        .sheet(item: $selectedMovie) { movie in
            MovieDetailSheet(movie: movie)
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Movie Stats")
                .font(.largeTitle.bold())
            if model.hasDirectory {
                Text(model.directoryPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.directoryPath)
            } else {
                Text("Open a directory to begin scanning for movies.")
                    .foregroundStyle(.secondary)
            }
            if !model.ffprobeAvailable {
                Label(
                    "ffprobe not found — install ffmpeg via Homebrew to detect movie types.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    /// Ranked list of every movie, largest first, with its size. The original
    /// size rank is preserved when the search filter narrows the list.
    private var movieList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.movies.isEmpty {
                Spacer()
                Text(model.hasDirectory ? "No movies found." : "No movies scanned yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                HStack(spacing: 10) {
                    Text("Library Details")
                        .font(.headline)
                    Spacer()
                    sortMenu
                    typeFilterMenu
                    searchControl
                }

                let matches = filteredMovies
                if matches.isEmpty {
                    Spacer()
                    Text("No matches for \"\(searchText)\".")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer()
                } else {
                    List {
                        ForEach(matches, id: \.movie.id) { entry in
                            HStack(spacing: 12) {
                                Text("\(entry.rank)")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 28, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(entry.movie.displayTitle)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        chips(for: entry.movie)
                                    }
                                    Text(entry.movie.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Text(byteString(entry.movie.size))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .help(entry.movie.path)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedMovie = entry.movie }
                            .contextMenu {
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting(
                                        [URL(fileURLWithPath: entry.movie.path)]
                                    )
                                }
                            }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
                    .help("Clear filter")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .frame(width: 240)
            .onAppear { searchFocused = true }
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

    /// Type/HDR/DV/10-bit pills shown next to a movie's filename.
    @ViewBuilder
    private func chips(for movie: MovieFile) -> some View {
        if let type = movie.movieType, type != MovieType.unknown.rawValue {
            Chip(text: type, color: .blue)
        }
        if movie.hasDolbyVision {
            Chip(text: "Dolby Vision", color: .purple)
        }
        if let hdr = movie.hdrFormat {
            Chip(text: hdr, color: .orange)
        }
        if movie.is10Bit {
            Chip(text: "10-bit", color: .teal)
        }
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

    /// The list shown in the main library view: applies the current sort
    /// order, type filter, and search text. The row number is the position in
    /// the currently displayed list (1, 2, 3 …), not an absolute library rank.
    private var filteredMovies: [(rank: Int, movie: MovieFile)] {
        let sorted: [MovieFile]
        switch sortMode {
        case .sizeDescending:
            sorted = model.moviesBySize
        case .titleAscending:
            sorted = model.movies.sorted {
                $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
            }
        }

        let typeFiltered: [MovieFile]
        if selectedTypes.isEmpty {
            typeFiltered = sorted
        } else {
            typeFiltered = sorted.filter { movie in
                selectedTypes.contains(movie.movieType ?? "Unprobed")
            }
        }

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let final: [MovieFile]
        if trimmed.isEmpty {
            final = typeFiltered
        } else {
            let needle = trimmed.lowercased()
            final = typeFiltered.filter {
                $0.displayTitle.lowercased().contains(needle)
                    || $0.filename.lowercased().contains(needle)
            }
        }

        return final.enumerated().map { (rank: $0.offset + 1, movie: $0.element) }
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

    /// Multi-select content-type filter. Empty selection = "All Types".
    private var typeFilterMenu: some View {
        Menu {
            Button("All Types") { selectedTypes.removeAll() }
            Divider()
            ForEach(MovieType.allCases, id: \.rawValue) { type in
                typeToggle(type.rawValue)
            }
            typeToggle("Unprobed")
        } label: {
            Label(typeFilterLabel, systemImage: "line.3.horizontal.decrease.circle")
                .font(.callout)
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func typeToggle(_ name: String) -> some View {
        Toggle(name, isOn: Binding(
            get: { selectedTypes.contains(name) },
            set: { on in
                if on { selectedTypes.insert(name) }
                else { selectedTypes.remove(name) }
            }
        ))
    }

    private var typeFilterLabel: String {
        if selectedTypes.isEmpty { return "All Types" }
        if selectedTypes.count == 1 { return selectedTypes.first ?? "1 Type" }
        return "\(selectedTypes.count) Types"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                openDirectory()
            } label: {
                Label("Open Directory", systemImage: "folder")
            }
            .help("Choose a directory to scan")

            Button {
                Task { await model.rescan() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(!model.hasDirectory || model.isScanning)
            .help("Rescan the current directory")

            Button {
                Task { await model.reprobeAll() }
            } label: {
                Label("Reprobe", systemImage: "waveform.badge.magnifyingglass")
            }
            .disabled(!model.hasDirectory || model.isScanning || model.isProbing)
            .help("Re-read codec/resolution/HDR for every movie")

            Spacer()

            Button {
                openWindow(id: CleanupCategory.images.id)
            } label: {
                Label("Scan Images", systemImage: "photo.on.rectangle")
            }
            .disabled(!model.hasDirectory)
            .help("Scan this directory for images")

            Button {
                openWindow(id: CleanupCategory.text.id)
            } label: {
                Label("Scan Text Files", systemImage: "doc.text")
            }
            .disabled(!model.hasDirectory)
            .help("Scan this directory for .txt and .nfo files")

            Button {
                openWindow(id: "duplicates")
            } label: {
                Label("Find Duplicates", systemImage: "rectangle.stack.badge.play")
            }
            .disabled(!model.hasDirectory)
            .help("Find folders containing more than one video file")

            Button {
                openWindow(id: "empty-folders")
            } label: {
                Label("Find Empty Folders", systemImage: "folder.badge.minus")
            }
            .disabled(!model.hasDirectory)
            .help("Find folders that contain no files")
        }
    }

    // MARK: - Actions

    private func openDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a directory to scan for movies"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.directoryPath = url.path
        Task { await model.rescan() }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// In-window detail popup. Shows every metadata field we've collected for the
/// selected movie in an aligned two-column grid. Triggered by clicking a row
/// in the main movie list.
private struct MovieDetailSheet: View {
    let movie: MovieFile
    @Environment(\.dismiss) private var dismiss

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

            Divider()

            ScrollView {
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
                    detailRow("Audio Tracks", audioTracksDetail)
                    detailRow("Subtitle Tracks", subtitleTracksDetail)
                    detailRow("Last Scanned", dateText(movie.dateScanned))
                    detailRow("Last Probed", movie.probedAt.map(dateText) ?? "—")
                }
                .padding(.vertical, 14)
            }
            .frame(maxHeight: 500)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        .padding(28)
        .frame(width: 760)
        .onExitCommand { dismiss() }
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
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled()
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
