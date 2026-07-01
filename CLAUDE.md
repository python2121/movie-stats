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
- **Smart Import** — an automated import against a persistent *watch
  directory*. A background scan (~hourly) confident-matches the watch dir
  and turns the toolbar button blue when something's importable; the window
  then runs match → image/text cleanup planning → extras defaults → rename
  planning headlessly, leaving just a Multiple-Videos review + a Ready
  preview. Reuses the manual-import machinery underneath. See §6.19.
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
| Smart Import                 | `SmartImportModel`     | `SmartImportView`     |
| Library Reports              | `ReportsModel`         | `ReportsView`         |
| Collections                  | `CollectionsModel`     | `CollectionsView`     |
| Insights                     | — (reads AppModel)     | `InsightsView`        |
| Settings (⌘,)                | — (UserDefaults)       | `SettingsView`        |
| Ask Claude (panel, not window) | `ChatModel`          | `ChatPanel`           |

Window registration lives in `MovieStatsApp.swift`; toolbar buttons that
open them live in `ContentView.swift`'s `toolbarContent` (a customizable
`.toolbar(id:)` — every item also has a Library-menu counterpart in
`MovieStatsApp.swift`'s `LibraryCommands`, so menu and toolbar must stay
in sync when adding a tool). The main scene is a single `Window`, not a
`WindowGroup` — `AppModel` is app-wide state, so multiple main windows
would just mirror each other.

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
watched_at            REAL                -- user watch state; NULL = unwatched
personal_rating       INTEGER             -- user's own 1–5 stars
first_seen_at         REAL                -- stamped on first INSERT, never
                                          -- updated on rescan = "added" date
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

### `subtitle_files` — sidecar subtitle inventory

Keyed by `path`. One row per external subtitle file found during a rescan
(`SubtitleScanner`), with `SubtitleClassifier.parse` output baked in:
`movie_path` (nullable FK → `movies.path`), `language`, `descriptor`,
`is_sdh`, `is_forced`, `format`.

**Rebuilt wholesale on every rescan** (`replaceAllSubtitleFiles` —
DELETE + reinsert in one transaction). Attribution walks up from the
subtitle's folder to the first directory directly containing videos
(covers siblings, `Subs/`, nested per-language folders), then:
basename-prefix match → sole video → NULL (orphan, kept but
unattributed). Consequence of the rebuild-on-rescan design:
`movie_path` goes stale between a Rename Library apply and the next
rescan — the detail sheet just shows no sidecar subs until then.
That's accepted, not a bug.

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

**Subs/ promotion is universal.** Every subtitle — sibling next to the
video, entry inside an existing `subs/` / `subtitles/` / `subtitle/` /
`sub/` / `subz/` / `s/` folder, or sibling at the scan root for a loose
top-level video — gets renamed *into* the canonical `Subs/` subfolder
of the wrapper. The applySubtitles safety net creates `Subs/` on demand
when no source layout already had one. Both the standalone Rename Library
and the import wizard use the same path. The folder name `Subs` (capital
S) is a chosen convention, not a Plex/Jellyfin spec — both platforms are
case-insensitive when scanning subtitle folders. Capital matches dominant
release-group convention; one-line change in
`SubtitleClassifier.canonicalFolderName` if a future maintainer wants
lowercase. The `subtitleFolderAliases` set drives the *input* recognition
side (any case of any alias is accepted), so source layouts in any form
get collapsed to the single canonical output.

### 6.4 The rename plan: two shapes

`RenameModel.Row.Plan` has two cases:

- **`.renameFolder`** — the video already lives inside its own wrapper
  folder (parent isn't the scan root). The wrapper gets renamed; everything
  inside travels with it (video, Subs/, sidecars). This is the common case
  for an existing well-organized library.
- **`.createFolderAndMove`** — the video is loose at the scan root, *or*
  it's one of several matched movies sharing a single folder (a ripped
  "Star Wars Trilogy" folder holding three different films). In both
  cases a new wrapper folder is created **at the scan root** and the
  video is moved into it. **Only the video moves on disk** in this case;
  sibling subtitles stay where they are until `applySubtitles` moves
  each one explicitly. (This was a latent bug at one point —
  `currentSubtitlePath` used to assume siblings travelled with the
  wrapper; the fix is the `switch row.plan` block at the bottom of that
  function.) For the loose-at-root case sidecars are claimed from the
  pre-indexed scan-root subtitle list; for the split-from-shared-folder
  case they're claimed from the shared folder by filename-stem prefix.

  **Multi-movie folder split + husk auto-prune.** Until June 2026 a
  folder containing more than one matched movie was *silently skipped*
  by the planner (`siblings > 1 → continue`) — renaming a shared wrapper
  would clobber the other films, and there was no UI signal it happened,
  so those movies just never renamed. Now each video in such a folder is
  split out via `.createFolderAndMove` to its own scan-root wrapper. The
  `.mkv`/`_2.mp4` alternate-encode pairs in these folders flow through
  the normal multi-quality `[qualityTag]` post-pass and duplicate-target
  detection unchanged. After Apply, the emptied source folder is
  **permanently deleted** (§6.8) — but *only* when its shallow contents
  are all hidden dotfiles (`containsOnlyHiddenEntries`); a leftover
  unmatched video, orphan subtitle, or untouched subfolder keeps it
  alive. The guard `oldFolderPath != scanRoot` ensures the library root
  itself is never a prune candidate. This is the standalone Rename
  window's *only* delete path.

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

### 6.6.1 The Multiple Videos finder: library scope vs import scope

`DuplicatesModel.group` has two behaviors keyed on the
`includeRootLevel` flag.

**Library scope** (`includeRootLevel == false`, the standalone window's
default):

- Buckets by first path component beneath the scan root.
- Skips videos that live directly at the scan root — multiple loose
  top-level movies in `/movies/` are independent movies, not duplicates.
- Keeps only buckets with `count > 1`. Single-video movie folders
  aren't "duplicates" worth flagging.

**Import scope** (`includeRootLevel == true`, passed by the import
wizard):

- Buckets by first path component beneath the scan root, **and** root-
  level loose videos go into a synthetic group keyed by the scan root.
- Drops the `count > 1` filter entirely — *every* video in the source
  is shown, even singletons. The user wants a full inventory so they
  can prune extras, not just multi-video folders.
- Reason it's the wider net: extras don't always cluster. A release
  like Deliverance has the main MKV at the source root and exactly one
  nested extra three folders deep, in its own subfolder. Two single-
  entry buckets — both would be hidden by `count > 1`, so the user
  would never see the extra to delete it.

Sub-folder-nested videos still form their own buckets keyed by the
subfolder, so the folder context is preserved. The per-group "select
all but the largest" shortcut still spares the main movie (largest)
and checks every extra in a multi-video bucket — useful when a release
has a real `Extras/` folder with multiple files inside.

### 6.6.2 Move to Library: only-what-we-touched

The Move to Library step in the import wizard moves *only the top-level
items beneath the source that the import is responsible for*, not every
top-level item in the source directory. Tracked-item detection: for
each entry in `session.movies`, compute its first path component
beneath `sourceDirectory` and add that name to a Set. Move only those
items.

This matters because:

- A single-movie source like Deliverance often has a manually-organized
  `Extras-Grym/` subfolder next to the canonical wrapper we created.
  Pre-fix behavior was `contentsOfDirectory.sorted()` — every top-level
  item moved, including the extras subfolder we never touched.
- Likewise leftover NFOs / posters / `.DS_Store` were getting dragged
  across.

The fix keeps the move tight: after rename, each movie's path is
`<source>/<canonical-wrapper>/<canonical>.ext` — its first component
beneath source is the wrapper, so the wrapper moves. Anything outside
that set stays in the source where the user put it. The user can then
clean up extras manually or via the multi-video step on a re-import.

Edge case: if a video is *unmatched* (no TMDB match, so rename didn't
process it), its path is the original loose-at-root path and only that
single file moves — its sidecars don't come along. In practice the
user is expected to match before moving; we don't try to harvest
strays.

The auto-prune toggle (§6.7) continues to fire only when the source
directory ends up empty of non-hidden entries, which now means
"every wrapper we created has moved out AND there's nothing else the
user added." Cleaner outcome than the pre-fix behavior, which always
left source empty (because everything moved).

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

**Duplicate replacement:** `ImportSession.duplicateConflicts` flags any
imported movie whose confirmed TMDB id already exists in the live library.
The Ready step lists the conflicts (existing path / size / type), and Move
to Library routes through a Replace-and-Move / Cancel confirmation instead
of moving directly. `replaceExistingCopies()` deletes each library copy —
the whole wrapper folder when it's inside the library root and contains no
*other* library movie, otherwise just the video plus its attributed
`subtitle_files` rows — then deletes the `movies` row. Only after that
does the normal `moveToLibrary()` run, so the path-level "already exists
at destination" skip never fires for replaced items.

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

Stored in `UserDefaults` under `tmdbAPIKey`. Set in the Settings window
(⌘, — `SettingsView.swift`), which also shows the Application Support data
location. The app accepts either a v3 key or a v4 read-access token (it
picks one by length heuristic in `TMDBService.apiKey`).

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

### 6.18 The curation layer (watch state, reports, collections)

Added June 2026, cribbing from Plex / Radarr / tinyMediaManager:

- **Watch state + stars** live on the `movies` row (`watched_at`,
  `personal_rating`). `AppModel.setWatched` / `setPersonalRating` write
  through and patch the in-memory array in place — no reload.
- **Reports** (`ReportsModel`) are pure functions over
  `appModel.movies` + `subtitle_files`; nothing is persisted. The
  Delete File action there is a *permanent* delete (§6.8) followed by a
  DB row delete + report recompute.
- **Collections** fetches `/collection/{id}` live on window open; counts
  exclude unreleased parts so a franchise with an announced sequel still
  reads "complete".
- **Poster wall** loads from `PosterCache` and lazily backfills missing
  artwork via `MovieFile.posterPath` as cells scroll into view (matches
  confirmed before poster caching existed have no cached JPG).
- **first_seen_at** is the "added to library" timestamp — set once on
  INSERT, deliberately not touched by the rescan upsert. `date_scanned`
  is useless for that purpose because every rescan rewrites it.
- The toolbar is customizable (`.toolbar(id:)`); cleanup/maintenance
  items ship `showsByDefault: false` to keep the default bar sane. Every
  toolbar action also lives in the Library menu — keep both in sync.
- **Window shortcuts use ⌥⌘1/2/3, not ⇧⌘** — ⇧⌘3/4/5 are the system
  screenshot shortcuts and never reach the app.
- **The scan sheet is cancellable** (`AppModel.cancelRequested`): Cancel
  stops scheduling new ffprobe tasks; in-flight ones finish; unprobed
  rows keep `probed_at` NULL so the next Rescan resumes where it left
  off. Escape maps to Cancel via `.keyboardShortcut(.cancelAction)`.
- Menu-item ellipsis rule applied: "…" only on items needing further
  input (Open Directory…, Import…); informational windows (Reports,
  Collections, Insights) get none. The default Help menu is removed
  (no help book ships).

### 6.19 Smart Import (automated import against a watch directory)

Added June 2026. Automates the §6.7 import wizard against a persistent
**watch directory** (a `/complete`-style staging dir, separate from the
library). Three pieces:

- **`SmartImportScanner`** (`Services/SmartImportScanner.swift`) — pure
  background detection. Walks the watch dir and returns an `Outcome`: the
  paths that confidently auto-match TMDB plus a `searchFailures` count of
  TMDB lookups that *errored* (network / rate limit) rather than returning
  no results — so a dead network isn't mistaken for "nothing importable"
  (the toolbar wand goes orange when failures > 0 and nothing is pending).
  Matching uses the *same* rule as the interactive matcher
  (`MatcherModel.Row.isConfidentMatch` — the exact `Title (Year)`
  match or fuzzy ≥0.80 + same year, extracted to a shared static so the
  two can't drift). One search call per video, search-endpoint year (no
  per-row details fetch). No DB writes / deletes / renames.

- **`SmartImportMonitor`** (`SmartImportMonitor.swift`) — app-level
  `@Observable`, created once in `MovieStatsApp` and injected via
  `.environment` into the main window, the Smart Import window, and
  Settings. Owns `watchDirectory` (UserDefaults key
  `smartImportWatchDirectory`) and `pendingMatchCount`. `start()` runs a
  sleeping `Task` loop (not a `Timer` — avoids the `@Sendable` capture
  headache under Swift 6) that scans on launch and every hour; the app also
  re-scans on `scenePhase == .active` (foreground) so a download added
  mid-session lights the button promptly instead of waiting up to an hour,
  and the window's `prepare()` pushes its fresh count back via
  `updatePendingCount`. `scanNow` coalesces concurrent calls so a
  post-import refresh that collides with the poll isn't dropped.
  `hasPending` (count > 0) drives the **blue toolbar button** in
  `ContentView` (`.tint(.blue)`); gray otherwise.

- **`SmartImportModel`** (`SmartImportModel.swift`) + **`SmartImportView`** —
  the per-window orchestrator + 2-pane UI. The model *composes* an
  `ImportSession` (the `MovieScope` + `moveToLibrary`), a `MatcherModel`,
  and a `RenameModel` — `ImportSession` is untouched. `prepare()` runs
  scan → confident match (`MatcherModel(autoCommitOnPick: true)` →
  `runScan()` → `confirm()`) → computes the image/text deletion plan →
  seeds extras / sample defaults; `execute()` runs all deletes → rename
  → empty-folder prune → `moveToLibrary()`.

Key decisions (match the user's spec + the clarifying answers):

- **Confident matches only.** Rows that don't auto-include stay
  `tmdbId == nil` and fall out of every downstream step — left untouched
  in the watch dir. There's no manual-match fallback here (use the regular
  Import window for stragglers).
- **Deletes are deferred to the Ready confirm.** `prepare()` only computes
  what *would* be deleted; nothing is removed until the user clicks Import
  to Library. The Ready pane shows renames before→after, TMDB matches, and
  struck-through deletions. (Permanent deletes, §6.8.)
- **Cleanup is scoped to matched-movie folders.** Image/text/empty-folder
  sweeps run only inside the one-level-deep folders that contain a matched
  movie (`trackedTopLevelDirs`), never the whole watch dir — so unmatched
  release folders are never touched. A matched *loose* file at the watch
  root contributes no folder, so it gets no surrounding cleanup and no
  extras review; `RenameModel.createFolderAndMove` wraps it and
  `moveToLibrary` moves it — the "just move the single file" outcome falls
  out of the existing plan shapes.
- **Multiple matches.** Several distinct movies (separate folders, or even
  several different films in one folder) are handled by the reused logic —
  each gets its own TMDB id, wrapper, and move (multi-movie split, §6.4).
  Two cases are *safe but skipped* (never overwritten / lost), and Smart
  Import surfaces both in the Ready preview + Export Plan rather than
  silently dropping them: (a) **two downloads of the same movie** — Smart
  Import doesn't run ffprobe, so the `[qualityTag]` split (§6.4) can't tell
  them apart; they collide on one target, `RenameModel` marks them
  `duplicateConflict` + unchecks them, and the headless `apply()` (which
  only applies `included` rows) skips them; (b) **a movie already in the
  library** (`session.duplicateConflicts`) — `moveToLibrary` won't
  overwrite, so the move is skipped *unless* the user ticks the Ready-step
  **Replace existing library copies** checkbox (`replaceExisting`), which
  marks the post-rename paths via `session.setReplace` so `moveToLibrary`
  runs its Replace flow (deletes the old copy, then moves). Both cases are
  flagged in a "Needs attention" section.
- **Per-movie include checkbox (Ready step).** Each matched movie has a
  checkbox; unchecking it leaves that movie entirely untouched. Mechanism:
  `SmartImportModel.setIncluded` drops/reinserts the movie from
  `ImportSession` (`dropMovie`/`reinsertMovie`) — dropping is load-bearing
  because `moveToLibrary` moves the containing folder of *every* movie still
  in `session.movies`, matched or not, so merely nil-ing `tmdbId` wouldn't
  stop the move. Toggling rebuilds the rename plan in place
  (`rename.reload`), and the deletion previews derive from the still-active
  folders (`effective{Image,Text,Video}Deletions` filtered to
  `activeTrackedDirs`), so an unchecked movie's images/text/samples are
  spared too. `candidateMovies` is a stable snapshot so an unchecked movie
  stays visible (unchecked) rather than vanishing.
- **The Multiple-Videos review** doesn't reuse `DuplicatesView` (whose
  delete selection is private to its own model and unreadable at Ready
  time). It reuses the genuinely reusable bits — `DuplicatesModel.group`
  for bucketing and `session.extrasMarks` / `session.parentMovie` for
  attribution — and renders a purpose-built list so the final selection is
  readable. Defaults: each non-main video → **Extra**, except ones whose
  path reads as a `sample` → **Delete**. Only subfolder buckets with a
  matched main *and* something else to decide are shown.

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
  MovieStatsApp.swift          @main App scene; every window + Library menu
  SettingsView.swift           Settings window (⌘,): TMDB key, data location
  ContentView.swift            main window: toolbar + stats + ranked list
  AppModel.swift               owns store, scans, probes — conforms to MovieScope
  MovieScope.swift             the protocol; AppModel + ImportSession conform
  Models/
    MovieFile.swift            in-memory shape of a movie row
    SubtitleFile.swift         in-memory shape of a subtitle_files row
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
    SubtitleScanner.swift      sidecar subtitle discovery + movie attribution
    ExternalPlayer.swift       play in IINA (falls back to default player)
    FilenameSanitizer.swift    sanitize Title (Year) {tmdb-N} for disk
    Thumbnailer.swift          ImageIO downsampling for cleanup previews
    TextPreview.swift          short text snippet for cleanup previews
    IMDbDatasetService.swift   download + decompress + parse ratings TSV
    SmartImportScanner.swift   background watch-dir confident-match detection
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
  SmartImportMonitor.swift     app-level watch-dir poll + blue-button state
  SmartImportModel.swift       automated import orchestrator (§6.19)
  SmartImportView.swift        smart import 2-pane window
  IMDbModel.swift              dataset-download workflow state
  IMDbView.swift
  ReportsModel.swift           library-health reports (subs/upgrades/dupes/…)
  ReportsView.swift            sidebar + findings list, with permanent delete
  CollectionsModel.swift       TMDB franchise completeness (live fetch)
  CollectionsView.swift
  InsightsView.swift           decade/genre/rating/watch-progress charts
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

Tests/MovieStatsTests/         Swift Testing suite (see §12)
  TestSupport.swift            TempDir helper (.build-rooted scratch)
  *Tests.swift                 one suite per unit + integration suites

build-app.sh                   builds and bundles MovieStats.app
run-tests.sh                   runs the suite (wires up Swift Testing under CLT)
make-icon.sh                   regenerates AppIcon.{png,icns}
Package.swift                  SwiftPM manifest (macOS 14+, Swift 6) + test target
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

---

## 12. The test suite

Run with **`./run-tests.sh`** (forwards extra args, e.g.
`./run-tests.sh --filter RenameModel`). Don't just run bare `swift test`
— it fails to find the test framework on this machine; see below.

### Framework + toolchain wiring (the non-obvious part)

Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`,
`#require`), not XCTest. The user's machine has **Command Line Tools only,
no full Xcode**, and:

- **XCTest.framework for macOS isn't in CLT at all** — XCTest is a
  non-starter here.
- **Swift Testing _is_ in CLT** (`Testing.framework` +
  `lib_TestingInterop.dylib` under `$(xcode-select -p)/Library/Developer/`)
  but SwiftPM doesn't put it on the default search path. `run-tests.sh`
  adds the `-F` framework path, plus two `-rpath`s (the framework dir and
  the `usr/lib` dir holding `lib_TestingInterop.dylib`) so the test bundle
  loads at runtime. If a full Xcode is ever selected, the script detects
  the framework isn't under the CLT layout and runs plain `swift test`.

### Two test seams in the app target

- `MovieStore.init(url:)` — designated initializer taking an explicit DB
  path; the app's `init()` is now a `convenience` that points at
  Application Support. Tests pass a throwaway temp file so they never
  touch the real library.
- `TitleSimilarity` (in `MatcherModel.swift`) was made module-internal
  (was `private`) so the suite can exercise the &/and folding + 0.80
  fuzzy threshold directly. Still file-scoped otherwise.

### Layout + what's covered

`Tests/MovieStatsTests/` — one file per unit. Pure-logic suites
(TitleParser, SubtitleClassifier, FilenameSanitizer, MovieClassifier,
TitleSimilarity, TMDB `preferredReleaseDate`, `DuplicatesModel.group`)
plus integration suites: `MovieStoreTests` (real SQLite on a temp file)
and `RenameModelTests` (full reload→apply against a real temp filesystem
via a `TestScope: MovieScope`, covering the multi-movie split + husk
prune, plan shapes, multi-quality `[qualityTag]`, and duplicate-target
detection).

**`TempDir` gotcha (`TestSupport.swift`):** scratch dirs are created under
the package's `.build/` (gitignored, auto-removed in `deinit`), **not** the
system temp dir. macOS temp lives under `/var/folders`, a symlink to
`/private/var`; `DirectoryScanner` normalizes its root with
`standardizedFileURL` (which rewrites `/private/var` → `/var`) while
`FileManager`'s enumerator yields the resolved `/private/var`, so a
temp-dir root can never satisfy the scanner's own prefix check and the
extras filter silently no-ops. A `/Users/...` root (under `.build`) has no
such symlink, matching production roots like `/Volumes/Media`. If you add
filesystem tests, keep using `TempDir`.
