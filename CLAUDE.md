# CLAUDE.md

Notes for future Claude sessions working on this codebase. Reading this once
should save an hour of rediscovery on every onboarding.

This file documents what the code *is* and the things that are easy to
misunderstand. For *how to use* the app from a user's point of view, the
README is the right starting point. Everything below assumes you've already
skimmed it.

---

## 1. What this app is

**Movie Stats** is a personal macOS SwiftUI app for taking a network-attached
movie library (typically `/Volumes/Media/...`) from "pile of scene-release
folders the user downloaded" to "canonical Plex/Jellyfin-ready library with
TMDB metadata and IMDb ratings." It's evolved well beyond the README's
original framing of "show stats about my movies":

- **Stats** — ranked size list, codec/resolution/HDR chips, classification
  (4K Remux / 1080p Encode / …).
- **TMDB matching** — match each scanned file to a canonical TMDB entry; the
  match is the prerequisite for the rename + IMDb-rating flows.
- **IMDb ratings** — bulk-loaded from `title.ratings.tsv.gz`, joined into the
  main list as a chip.
- **Cleanup tools** — images, text/nfo files, multiple-videos-per-folder,
  empty folders. Each is a separate window.
- **Rename Library** — rewrites every matched file/folder to the canonical
  `Title (Year) {tmdb-N}/Title (Year) {tmdb-N}.ext` Plex/Jellyfin form, with
  subtitle handling.
- **Import wizard** — walks a *separate* "/complete"-style staging directory
  through TMDB match → cleanup → rename → move into the library, without
  touching the live library DB until the user clicks Move to Library.
- **Ask Claude** chat panel — runs the local `claude` CLI to query the
  SQLite database in natural language.

It's built for one person to compile and run on their own Mac. Not sandboxed,
not distributed, ad-hoc signed.

---

## 2. Build / run

```sh
swift run                # dev — straight from SwiftPM, no bundling
./build-app.sh           # release — produces ./MovieStats.app (ad-hoc signed)
open MovieStats.app
./make-icon.sh           # regenerates Resources/AppIcon.{png,icns}
```

Requirements: macOS 14+, Swift 6 toolchain (Command Line Tools is enough — no
full Xcode needed). The `claude` CLI must be installed and authenticated for
the Ask Claude panel to work (the panel is hidden when not available).

`./Tools/fetch-ffprobe.sh` downloads a universal `ffprobe` binary from
evermeet.cx + osxexperts.net (Intel + Apple Silicon) and bundles it under
`Resources/ffprobe`. The .app's `MediaProbe` calls it via `Process`. **Don't
assume `ffprobe` is on the user's PATH** — they shouldn't have to install
anything.

### The .app bundle layout

```
MovieStats.app/
  Contents/
    MacOS/MovieStats          # the SwiftPM-built binary
    Resources/
      AppIcon.icns
      ffprobe                 # the bundled universal binary
    Info.plist                # CFBundleIdentifier: com.python21.MovieStats
```

The icon is **generated programmatically** by `Tools/icon-generator/main.swift`
using Core Graphics. `make-icon.sh` runs that program, sizes the output to
the various `iconutil`-required formats, and packs them into `AppIcon.icns`.

---

## 3. Architecture at a glance

```
SwiftUI Views ─→ @Observable @MainActor models ─→ Services ─→ SQLite / disk / network

AppModel ─┬─→ MovieStore (SQLite)
          ├─→ DirectoryScanner / FileScanner
          ├─→ MediaProbe (ffprobe subprocess) → MovieClassifier
          └─→ TMDBService (network) → PosterCache

Matcher / Rename ─→ MovieScope (protocol) ─→ AppModel or ImportSession

ImportSession ─→ wraps its own [MovieFile] in-memory snapshot + delegates to
                 AppModel's MovieStore for the shared TMDB cache
```

Key entities:

- **`AppModel`** (`AppModel.swift`) — the singleton-per-window state. Owns the
  `MovieStore`, holds `[MovieFile] movies`, runs the rescan + ffprobe pass,
  conforms to `MovieScope`.
- **`MovieStore`** (`Services/MovieStore.swift`) — a thin SQLite wrapper
  using the system `import SQLite3` (no Swift wrapper). Schema is documented
  inline; migrations are additive `ALTER TABLE` calls in `migrate()`.
- **`MovieScope`** (`MovieScope.swift`) — protocol that abstracts "the
  library context" so the matcher/rename can run against the live `AppModel`
  *or* a transient `ImportSession`. Both conform.
- **`ImportSession`** (`ImportSession.swift`) — `@Observable` orchestrator
  for the import wizard. In-memory snapshot of `/complete` files; its
  `setTMDBMatch` / `updatePath` patch the snapshot rather than writing to
  the persistent `movies` table.

Each tool window has its own `*Model.swift` + `*View.swift` pair:

| Window                       | Model                  | View                  |
|------------------------------|------------------------|-----------------------|
| Main library                 | `AppModel`             | `ContentView`         |
| Match Library to TMDB        | `MatcherModel`         | `MatcherView` + `MatcherSearchSheet` |
| Rename Library               | `RenameModel`          | `RenameView`          |
| Images / Text cleanup        | `FileCleanupModel`     | `FileCleanupView`     |
| Multiple Videos per Folder   | `DuplicatesModel`      | `DuplicatesView`      |
| Empty Folders                | `EmptyFoldersModel`    | `EmptyFoldersView`    |
| IMDb Ratings                 | `IMDbModel`            | `IMDbView`            |
| Import                       | `ImportSession`        | `ImportView`          |
| Ask Claude (panel, not window) | `ChatModel`          | `ChatPanel`           |

Window registration lives in `MovieStatsApp.swift`; toolbar buttons that
open them live in `ContentView.swift`'s `toolbarContent`.

---

## 4. The SQLite schema

**Path:** `~/Library/Application Support/MovieStats/moviestats.sqlite`

WAL journal mode. Three tables.

### `movies` — the library catalog

Primary key: `path`. The single source of truth for which files are in the
library and what we know about them.

```
path                  TEXT PRIMARY KEY    -- absolute on-disk path
filename              TEXT NOT NULL
size                  INTEGER NOT NULL
date_scanned          REAL NOT NULL       -- unix timestamp
parsed_title          TEXT                -- TitleParser output
parsed_year           INTEGER             -- TitleParser output
-- ffprobe metadata, nullable until probed:
width, height         INTEGER
duration              REAL
bitrate               INTEGER
video_codec           TEXT
container             TEXT
pix_fmt               TEXT
is_10bit              INTEGER             -- 0 / 1 (SQLite has no bool)
hdr_format            TEXT                -- "HDR10" / "HLG" / NULL
has_dolby_vision      INTEGER             -- 0 / 1
video_tracks          INTEGER
audio_tracks          INTEGER
subtitle_tracks       INTEGER
audio_codecs          TEXT                -- comma-joined
audio_channels        TEXT                -- comma-joined
audio_languages       TEXT                -- comma-joined
subtitle_codecs       TEXT                -- comma-joined
subtitle_languages    TEXT                -- comma-joined
movie_type            TEXT                -- MovieType.rawValue, see classifier
probed_at             REAL                -- timestamp; NULL = probe pending
tmdb_id               INTEGER             -- joined into tmdb_movies
confirmed_year        INTEGER             -- see §6.2
```

Index on `movie_type` and `tmdb_id`.

### `tmdb_movies` — TMDB metadata cache

Keyed by `tmdb_id`. **Shared across both the live library and any active
import session** — TMDB metadata is path-independent. Filling it once means
both contexts can read it back.

Stores the full TMDB detail response, with nested objects (genres, production
companies, release dates) as JSON blobs.

### `imdb_ratings` — bulk IMDb dataset

Keyed by `imdb_id` (e.g. `tt0107290`). Populated in one transaction from
`title.ratings.tsv.gz` (~1.4M rows, ~10 MB compressed). Joined into the main
movies query via `tmdb_movies.imdb_id`.

### `imdb_metadata` — single-row download timestamp

A `CHECK (id = 1)`-constrained one-row table holding `last_downloaded_at`
and `entry_count` for the IMDb dataset. UI uses this to show "Last refreshed
N days ago."

### Migrations

`MovieStore.migrate()` does additive-only schema changes — adds any new
column from a hardcoded list that doesn't already exist. Adding a column =
add an entry to that list. **Never drop columns** — old databases stay valid.

Backfills run inline in `migrate()` when specific columns are added (e.g.
`parsed_title` backfills `TitleParser` results from `filename`; `confirmed_year`
backfills from `parsed_year`).

---

## 5. The MovieScope abstraction

`MovieScope` is a small protocol that decouples the matcher + rename
models from concrete `AppModel`:

```swift
@MainActor
protocol MovieScope: AnyObject {
    var movies: [MovieFile] { get }
    var directoryPath: String { get }
    var store: MovieStore? { get }
    func reloadFromStore()
    func setTMDBMatch(forPath:tmdbID:confirmedYear:) throws
    func updatePath(oldPath:newPath:newFilename:) throws
}
```

Two implementations:

- **`AppModel`** — `setTMDBMatch` / `updatePath` write through to the SQLite
  `movies` table. `reloadFromStore` re-reads.
- **`ImportSession`** — `setTMDBMatch` / `updatePath` patch the in-memory
  `[MovieFile]` snapshot (the imported files don't exist in `movies` yet).
  `reloadFromStore` is a no-op.

`MatcherModel(scope:)` and `RenameModel(scope:)` take an `any MovieScope`,
so each model's UI works against either context unchanged. The views
(`MatcherView`, `RenameView`, `FileCleanupView`, `DuplicatesView`,
`EmptyFoldersView`) accept an optional `scopedScope:` / `scopedDirectory:` +
`embedded:` pair to support being hosted inside the import wizard while
preserving their standalone-window behavior.

### The store on import: writes that look like no-ops

`MovieStore.setTMDBMatch` is `UPDATE movies SET ... WHERE path = ?`.
For an import file not yet in the table, the UPDATE silently does nothing
(no error, 0 rows affected). That's *intentional* — the `ImportSession`
overrides `setTMDBMatch` on the protocol so the call goes into memory,
not the DB. The `MatcherModel` itself still also reads from / writes the
shared `tmdb_movies` cache via `scope.store` directly, which is fine
because that table is shared global metadata.

---

## 6. Hard-won quirks (read this before you assume anything)

### 6.1 The matcher / TMDB pipeline

**TMDB has two endpoints that disagree about `release_date`.** The
`search/movie` endpoint returns one date (often the *primary* US release);
the `movie/{id}?append_to_response=release_dates` endpoint returns the full
per-country payload from which the matcher picks the earliest theatrical/
limited/premiere date. They disagree on foreign films, festival-circuit
films, and anything with a long US-vs-international gap.

`TMDBService.preferredReleaseDate` picks the earliest of types 1/2/3
(premiere / theatrical-limited / theatrical) across all country groups.
This is what the matcher displays at confirm time and what gets written to
`confirmed_year`.

**Why `confirmed_year` exists:** the search endpoint year and the details
endpoint year don't always agree, and even the details endpoint sometimes
disagrees with itself between visits if TMDB updates its catalog. The matcher
locks in the exact year the user saw at confirm time so subsequent rebuilds
of the rename plan don't silently flip a year (e.g. *Perfect Blue* 1997
festival year vs 1998 wide release).

`MovieFile.effectiveYear` precedence: `confirmedYear` → `tmdbYear` → `parsedYear`.

### 6.2 The fuzzy auto-match

The matcher auto-includes (pre-checks) rows that meet either:

1. **Exact match** — file's parsed title + year exactly equal the TMDB
   candidate's title + year (case-insensitive, with `&` / `and` interchangeable).
2. **Fuzzy-+-same-year** — normalized Levenshtein similarity ≥ 0.80 *and*
   identical year.

The `&`-vs-`and` folding is in `TitleSimilarity.normalize`.

### 6.3 Subtitle handling: descriptors, collision suffixes, idx/sub pairs

`SubtitleClassifier.parse(filename:)` extracts four things from a sub
filename: `lang`, `forced`, `sdh`, and `descriptor`. The `descriptor` is what
distinguishes multiple *same-language* tracks (commentary / simplified vs
traditional Chinese / regional Spanish / British vs American English).
Composed output: `<base>.<lang>.<descriptor>[.sdh][.forced].<ext>`.

When two subtitles compose to the same target name, the `UniqueTargetAllocator`
hands out `.2`, `.3`, … suffixes before the extension. **Lossless** — no
sub ever gets dropped. The user can manually rename the suffixed file to
something like `.commentary.srt` later.

**Sibling-vs-Subs/ priority:** the rename planner runs the sibling subtitle
pass *before* the Subs/ container pass, so a sibling subtitle next to the
video wins the un-suffixed primary name on collision. Rationale: sibling
subs are a stronger user-intent signal than whatever the release group
shipped in `Subs/`.

**VobSub (.idx/.sub) pairs** are recognized as subtitle files and renamed to
the same `<base>` stem. The pairing is by basename convention (the `.idx`
references its sibling `.sub` by basename, not by path), so renaming both
to the same new stem keeps the link intact.

**Multi-token SDH detection:** `Hearing Impaired` / `Hearing_Impaired` /
`Hearing-Impaired` (any separator) is detected as SDH via a token-pair scan
*before* the per-token loop. The single-token `hearingimpaired` is also in
`sdhTags` for the no-separator case. `hi` is intentionally *not* an SDH tag
because it's also the ISO 639-1 code for Hindi.

**Subs-folder canonicalization:** any of `subs/`, `subtitles/`, `subtitle/`,
`sub/`, `subz/`, `s/` gets renamed to `Subs/` during apply. If a wrapper
folder has both a Subs-style folder AND sibling subs at the video level,
the siblings get consolidated *into* `Subs/`. Both layouts are tolerated;
the consolidation only happens when both exist.

### 6.4 The rename plan: two shapes

`RenameModel.Row.Plan` has two cases:

- **`.renameFolder`** — the video already lives inside its own wrapper
  folder (parent isn't the scan root). The wrapper gets renamed; everything
  inside travels with it (video, Subs/, sidecars). This is the common case
  for an existing well-organized library.
- **`.createFolderAndMove`** — the video is loose at the scan root. We
  create a new wrapper folder inside the scan root and move the video into
  it. **Only the video moves on disk** in this case; sibling subtitles at
  the scan root stay where they are until `applySubtitles` moves each one
  explicitly. (This was a latent bug at one point — `currentSubtitlePath`
  used to assume siblings travelled with the wrapper; the fix is the
  `switch row.plan` block at the bottom of that function.)

**Wrapper-folder boundary:** the planner uses `scope.directoryPath` as the
scan root and refuses to rename it. So if the user picks
`/complete/Some.Movie/` as the import source, the source dir *itself*
won't be renamed — instead a nested wrapper is created inside it. The
recommended pattern in the import wizard is to pick the *parent* dir
(`/complete/`), so each release folder under it gets renamed in place.

### 6.5 Duplicate-target detection

When two source files matched to the same TMDB id, both rows propose the
identical destination path. The rename planner detects this (group by
`newPath`, flag every group > 1), marks both rows with `duplicateConflict`,
unchecks them by default, and sorts them to the top of the table with a red
`duplicate` chip. The conservative collision check still protects the
second one from overwriting the first if the user re-checks anyway —
`targetFolderExists` throws.

### 6.6 The "skip already-canonical rows" filter

After plan-build, rows where the video is already at its proposed path *and*
every subtitle is at its proposed path are silently dropped. So opening
the Rename window a second time after Apply doesn't show 500 rows of
"nothing to do." Defined in the no-op filter at the bottom of
`RenameModel.reload()`.

### 6.7 The import wizard's source-dir cases

- **Parent-dir source** (`/complete/` containing release folders): each
  movie's parent ≠ scan root → `.renameFolder` plan. Folders are renamed
  in place. Move to Library moves each canonical folder into the library.
  Clean.
- **Single-movie source** (`/complete/Some.Release/`): movie's parent = scan
  root → `.createFolderAndMove` plan. A nested canonical wrapper is created
  inside the source dir. Move to Library moves the nested wrapper into the
  library. The source dir is left behind as an empty husk.

The Ready step has an opt-in **Delete the source directory afterwards if
it's left empty** toggle. Triggers only when the source has no non-hidden
entries remaining post-move. Permanent delete (no Trash on network volumes).

### 6.8 Permanent deletes, no Trash

Every "Delete Selected" / "Move to Library" / auto-prune operation uses
`FileManager.removeItem` directly. **Files are not sent to the Trash.**
This is intentional because the app targets network volumes (SMB / AFP),
which generally don't have a Trash. Every confirmation dialog says this
explicitly. Don't change it without thinking hard.

### 6.9 The Escape-key dance in RenameView

The `Table` widget grabs first-responder focus on render and swallows
`Escape` before `.onExitCommand` can fire. The fix is a hidden
`Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)` in
`.background` — it registers a window-wide shortcut the Table can't
intercept. Don't remove it.

The same workaround is *only* applied where needed. The simpler views
(`FileCleanupView`, `EmptyFoldersView`, `DuplicatesView`) work with plain
`.onExitCommand`.

### 6.10 The Ask Claude panel

`ChatPanel` is overlaid on top of the main window (not a separate window).
It talks to the local `claude` CLI via `ClaudeCodeRunner`, which spawns
the CLI in `--print --output-format stream-json` mode and parses each
event. Claude is told the schema in a system prompt and **restricted to
`sqlite3` Bash usage only** via Claude Code's tool-permissions flags.

The session ID from the first turn's `system/init` event is captured and
passed via `--resume` on subsequent turns, so prior context is preserved
without the app having to manage transcript state.

`ClaudeCodeRunner.locateBinary()` checks `~/.claude/local/claude` first
(the npm-global install location Anthropic ships), then Homebrew paths,
then `which claude`. If not found, the toolbar button hides itself.

### 6.11 The IMDb dataset workflow

`IMDbDatasetService` downloads `title.ratings.tsv.gz` (~10 MB) to a temp
file, shells out to `gunzip` for decompression (Swift's `Compression`
framework handles raw zlib but not the gzip wrapper), parses the TSV, and
hands rows to `MovieStore.replaceAllIMDbRatings` in a single transaction.

**Why bulk-load and not API?** IMDb has no public rating API anymore. The
bulk dataset is free, no API key, official IMDb-published. Updated daily;
the app shows "Last refreshed N days ago" and lets the user refresh on
demand.

**Why not `title.basics.tsv.gz`?** Considered for canonical-year fallback,
but it's ~200 MB compared to ratings' ~10 MB, and TMDB already gives us
the year reliably enough. Not worth the bytes.

### 6.12 The chat schema prompt

The `ChatModel.systemPrompt` includes the full schemas of `movies`,
`tmdb_movies`, `imdb_ratings`, `imdb_metadata`. When you add a column, *also*
update the schema in that prompt so Claude's queries stay correct. The prompt
also dictates the rules for joining (use `COALESCE` precedence:
`confirmed_year → tmdb_year → parsed_year`).

### 6.13 The TMDB API key

Stored in `UserDefaults` under `tmdbAPIKey`. Set via the **File → TMDB API
Key…** menu item, which pops an NSAlert with a secure text field. The app
accepts either a v3 key or a v4 read-access token (it picks one by length
heuristic in `TMDBService.apiKey`).

If the key is missing, the matcher's "Has API Key" indicator goes red and
scanning is disabled.

### 6.14 ffprobe concurrency

`AppModel.probeMissing` runs at most **6 concurrent ffprobe processes**
(`probeConcurrency`). ffprobe is mostly I/O-bound on reading file headers,
so small N keeps a network volume from thrashing. Don't crank this number
without testing on the user's setup — high concurrency over SMB starts
timing out.

### 6.15 The poster cache

`PosterCache` stores poster JPGs under
`~/Library/Application Support/MovieStats/posters/<tmdb-id>.jpg`. The matcher
saves at confirm time; the detail popover reads. There's no expiry — posters
basically never change.

The cache directory is created lazily.

### 6.16 The directory-path persistence

`AppModel.directoryPath` is `UserDefaults`-backed under `selectedDirectoryPath`.
So the library root survives restarts without needing security-scoped
bookmarks (the app is unsandboxed). Don't add sandboxing.

### 6.17 The auto-memory cap

This is a Claude-side concern, not app code. `MEMORY.md` indexes
human-readable memories Claude has accumulated about this user. Lines after
200 get truncated when the index is auto-loaded into context, so keep
entries one line each. (This is about the Claude memory system, mentioned
here only because it sometimes shows up in conversation context.)

---

## 7. Common code patterns

- **`@Observable @MainActor`** for state holders. SwiftUI observes them
  via `@Environment` injection (`.environment(model)`).
- **`@State private var model: Model?`** for window-level state that needs
  to be lazy-initialized in `onAppear`. Pattern: the view starts with `nil`,
  the first `onAppear` constructs the model using `appModel` from the
  environment. Lets the view be embeddable.
- **Async work yields to the main actor** between batches so progress bars
  paint: `await Task.yield()` every N items. Used in `RenameModel.reload`,
  `RenameModel.apply`, etc.
- **`Task.detached(priority: .userInitiated)`** for CPU- or I/O-bound work
  that should NOT block the main actor (filesystem walks, ffprobe, etc.).
  Detached so we don't drag the main actor's isolation into the closure.
- **`@MainActor` types are NOT `Sendable`** — so don't try to capture
  `AppModel` or `MovieStore` into a `Task.detached`. Pull the values you
  need first, then capture those.
- **`UPDATE` vs `INSERT OR REPLACE`** — most write paths use plain UPDATE,
  so an import file (not yet in `movies`) silently no-ops. That's by design.

---

## 8. Things that look like bugs but aren't

- **Subtitles with empty language end up as `<base>.srt`** — that's
  correct. The composed name only includes a language token when one was
  detected in the source filename. Plex/Jellyfin accept untagged sidecars.

- **`setTMDBMatch` for an import path doesn't fail** — the UPDATE returns
  0 rows affected, no error. `ImportSession.setTMDBMatch` overrides the
  protocol method to patch the in-memory snapshot instead. See §5.

- **The Rename window doesn't refresh after Apply** — it does, but the
  no-op filter (§6.6) silently hides every row that now matches its
  proposed path. If you applied all rows successfully, the table will be
  empty next time you open the window. That's success, not breakage.

- **Renamed files inside the Subs/ folder show up under a different folder
  on next reload** — the rename canonicalizes `subs/` / `subtitles/` →
  `Subs/`. After Apply, the folder is `Subs/`. On reload, the planner sees
  it's already canonical and skips re-canonicalizing.

- **The Chat panel shows "Querying database…" but doesn't return** — most
  likely the `claude` CLI isn't installed or isn't authenticated against
  Anthropic. Run `claude` from the terminal to confirm.

- **Loose top-level renames leave a husk source folder during import** —
  see §6.7. Either pick the parent dir as source, or check the auto-prune
  box on the Ready step.

---

## 9. Things that aren't done yet / known limitations

- **Single-movie import source leaves a nested wrapper inside the source
  dir.** Auto-prune helps but doesn't *prevent* the nesting. A cleaner fix
  would be planner-side detection: when the source has exactly one video
  file at the top level, rename the source dir itself instead of creating
  a nested wrapper. Requires plumbing scope-awareness into the rename
  planner.

- **`Hearing_Impaired` works but `English-Hearing.srt` doesn't.** The
  multi-token scan requires the literal `hearing` + `impaired` pair
  adjacent. If a release uses an unusual phrasing, we miss it. Cheap to add
  more patterns to the pre-scan if it ever comes up.

- **VobSub orphans aren't flagged.** A `.idx` without its `.sub` (or vice
  versa) is dead weight but the renamer doesn't currently warn. Each half
  gets renamed independently and a missing partner stays missing. Future
  enhancement: pair-check in the planner and flag with a soft warning.

- **No filter for "multi-language Subs/ pack but no English"** — sometimes
  a release ships subs in 30 languages but English isn't one of them. We
  rename them correctly but the user might not notice. Possible future
  flag.

- **The Title Parser is best-effort, not perfect.** It handles a lot of
  scene-naming variants but parenthetical alternate titles
  (`Der Untergang (Downfall) (2004)`) can still trip it. The fallback is
  the matcher's manual-pick sheet (`MatcherSearchSheet`).

- **The "Tonari no Totoro" false-positive for Norwegian was solved by
  user rename, not by code.** The 2-letter `no` is a legitimate ISO 639-1
  code AND a common Japanese particle in transliterated titles. A
  position-aware language detector (only match 2-letter codes near the
  extension) would help, but hasn't been added.

---

## 10. File layout

```
Sources/MovieStats/
  MovieStatsApp.swift          @main App scene; defines every window
  ContentView.swift            main window: toolbar + stats + ranked list
  AppModel.swift               owns store, scans, probes — conforms to MovieScope
  MovieScope.swift             the protocol; AppModel + ImportSession conform
  Models/
    MovieFile.swift            in-memory shape of a movie row
  Services/
    FileScanner.swift          recursive walk, used by scanners
    DirectoryScanner.swift     movie-extension scan
    MovieStore.swift           SQLite — schema, migrations, all CRUD
    MediaProbe.swift           ffprobe subprocess + parsing
    MovieClassifier.swift      width/height/codec/size → MovieType bucket
    TMDBService.swift          search/details/release_dates HTTP
    PosterCache.swift          on-disk JPG cache for matched posters
    TitleParser.swift          filename → (title, year) best-effort
    SubtitleClassifier.swift   subtitle parsing + composing (see §6.3)
    FilenameSanitizer.swift    sanitize Title (Year) {tmdb-N} for disk
    Thumbnailer.swift          ImageIO downsampling for cleanup previews
    TextPreview.swift          short text snippet for cleanup previews
    IMDbDatasetService.swift   download + decompress + parse ratings TSV
    ClaudeCodeRunner.swift     spawns claude CLI, parses stream-json
    CSVExporter.swift          File → Export Library to CSV menu item
  CleanupCategory.swift        config object: extensions + preview kind
  FileCleanupModel.swift       images / text cleanup state
  FileCleanupView.swift        shared UI for both cleanup categories
  EmptyFoldersModel.swift      empty folder discovery
  EmptyFoldersView.swift
  DuplicatesModel.swift        multi-video-per-folder discovery
  DuplicatesView.swift
  MatcherModel.swift           TMDB match state (works against any MovieScope)
  MatcherView.swift
  MatcherSearchSheet.swift     manual-pick sheet when the auto-match is wrong
  RenameModel.swift            rename plan + apply (works against any MovieScope)
  RenameView.swift
  ImportSession.swift          wizard state (conforms to MovieScope)
  ImportView.swift             import wizard window
  IMDbModel.swift              dataset-download workflow state
  IMDbView.swift
  ChatModel.swift              Ask Claude panel state
  ChatPanel.swift              overlaid chat UI
  ChatMarkdownTheme.swift      Markdown rendering theme for chat
  ResizeHandle.swift           chat panel resize handle
  DismissOnOutsideClick.swift  utility view modifier

Tools/
  icon-generator/main.swift    Core Graphics app icon generator
  fetch-ffprobe.sh             one-time universal ffprobe build downloader

Resources/
  AppIcon.png                  generated by make-icon.sh (committed)
  AppIcon.icns                 generated by make-icon.sh (committed)
  ffprobe                      gitignored — fetched on demand

build-app.sh                   builds and bundles MovieStats.app
make-icon.sh                   regenerates AppIcon.{png,icns}
Package.swift                  SwiftPM manifest (macOS 14+, Swift 6)
```

---

## 11. When working on this codebase

- **Default to terse, comment-free code.** Existing code has comments only
  where the *why* is non-obvious (race conditions, edge cases, format
  quirks). Don't add comments that just restate what the code does.
- **Don't introduce dependencies casually.** The app uses one external
  package (`swift-markdown-ui`) and is otherwise pure Foundation /
  AppKit / SwiftUI / SQLite3. Each new dep is a thing the user has to
  worry about; ask first.
- **The user is the developer and the only end user.** Build for their
  specific workflow (network-volume Plex library, scene-release downloads,
  TMDB-driven canonical naming). Don't generalize for hypothetical users.
- **Never assume the database is empty.** Migrations must work against
  every previous schema version. Add columns; don't remove or rename.
- **Permanent deletes are the design.** Don't suggest "send to Trash" —
  Trash doesn't exist on the user's volumes.
- **The user usually wants a diff, not a tutorial.** Make the change.
  Explain non-obvious decisions briefly. Don't write paragraphs about
  what you did when the diff already shows it.
