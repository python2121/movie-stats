# Movie Stats

A personal macOS app for managing a movie library that lives on disk —
typically a network share. Point it at a directory, it indexes everything,
matches each file to TMDB, lets you clean up cruft, rename to canonical
Plex/Jellyfin form, and import new releases.

The library state — paths, sizes, ffprobed metadata, TMDB matches, IMDb
ratings — lives in a local SQLite database in
`~/Library/Application Support/MovieStats/`, so the app is instant on
relaunch with no rescan needed.

> **Scope:** built for personal use — compiled and run on your own machine,
> not distributed.

---

## Main window

Pick a folder and the app crawls it (recursively) for movie files, then
shows:

- **Movies** — total count.
- **Larger than 20 GB** — count of files over that threshold.
- **Total Size** — combined size of the library.
- **Movies by size** — ranked list of every movie. Each row shows the
  canonical title (from TMDB once matched, otherwise the filename-parsed
  title), the file path, the file size, and chips for codec / resolution /
  HDR / Dolby Vision / 10-bit / IMDb rating / cleanup category.

A movie is any file whose extension is one of:
`mp4, mkv, avi, mov, m4v, wmv, flv, webm, mpg, mpeg, m2ts, ts, vob, ogv`.

Each row has a play button (and a context-menu item) that opens the file
in [IINA](https://iina.io) when it's installed, falling back to the system
default player otherwise.

Rescans also inventory every sidecar subtitle file (`.srt`, `.sup`,
`.idx/.sub`, …) into the database — language, SDH / forced flags, and
which movie each one belongs to — shown in the movie detail sheet and
queryable from the Ask Claude panel.

### Watching & curation

- **Watch state + your own 1–5 star rating** per movie (context menu or the
  detail sheet) — independent of IMDb/TMDB scores, persisted in the library
  database, exported in the CSV.
- **Poster wall** — toggle the main list into a Plex-style grid of cached
  TMDB posters; missing artwork is fetched lazily as you scroll.
- **Filters** — type, genre, decade, TMDB-match, and watched state, all in
  one Filters menu; sort by size, title (ignoring "The"), IMDb rating,
  year, recently added, or recently watched.
- **Surprise Me** (🎲 toolbar) — weighted random pick of something
  unwatched and well-rated, respecting the current filters.
- **Library Reports** (⌥⌘1) — missing English subtitles, upgrade
  candidates (great movies in bad encodes), duplicate TMDB matches,
  VobSub orphans, unmatched movies, and "space savers" (big files with
  low ratings), with permanent-delete actions where it's safe.
- **Collections** (⌥⌘2) — franchise completeness against TMDB: "you own
  2 of 4 John Wick movies", with links to the missing ones.
- **Insights** (⌥⌘3) — charts: movies by decade, top genres, IMDb rating
  distribution, watch progress by quality type, plus total-runtime and
  average-size headline stats.
- **Trailer button** in the detail sheet (opens the TMDB-listed YouTube
  trailer), plus IMDb / TMDB links, and **Quick Look** from any row's
  context menu.
- Scans keep the Mac awake (no more dead SMB walks) and post a
  notification when they finish in the background.

Filtering options in the toolbar: by TMDB-match status (All / Matched /
Unmatched) and by classification bucket (4K Remux, 1080p Encode, …).

### What gets indexed per movie

Beyond `path / filename / size`, every file gets `ffprobe`'d for:

- Width / height / duration / bitrate
- Video codec / container / pixel format
- 10-bit / HDR format / Dolby Vision
- Audio + subtitle track counts, codecs, channels, languages

These drive the chips in the main list and feed into a classifier that
assigns each movie a category: **4K UHD Remux / 1080p Blu-ray Remux /
4K Encode / 1080p Encode / 720p Encode / SD**.

### TMDB matching

Once you've set a TMDB API key (MovieStats → Settings…, ⌘,), the **Match TMDB**
toolbar button opens a window that finds every unmatched file, searches
TMDB for it, and shows the best auto-match as a sortable table. Auto-match
rules:

- **Exact** — filename's parsed title + year matches the candidate (case-
  insensitive, with `&` / `and` interchangeable). Pre-checked.
- **Fuzzy** — normalized Levenshtein similarity ≥ 0.80 AND identical year.
  Pre-checked.
- **Manual** — click any row's match candidate to override via a search
  sheet that hits TMDB directly.

Confirming writes the TMDB id (and a locked-in `confirmed_year`, separate
from `tmdb_year` so foreign-film year drift doesn't silently flip your
naming on the next rescan) and caches the full TMDB metadata, including
poster art, into the local DB.

### IMDb ratings

The **IMDb Ratings** toolbar button opens a small dialog that downloads
IMDb's public bulk ratings dataset (`title.ratings.tsv.gz`, ~10 MB),
decompresses it, and bulk-inserts ~1.4M ratings into the local DB. Joined
into the main movies query via `tmdb_movies.imdb_id`. Shows up as a yellow-
star chip next to each matched movie.

The dialog shows when the dataset was last refreshed and lets you re-pull
on demand. The dataset is free, no API key, no rate limit.

---

## Cleanup tools

Each tool opens in its own window, scans the current directory recursively,
and lets you select files with per-row checkboxes and delete them. Shared
behavior across all of them:

- **Select All / Deselect All** toggles the whole list.
- Deleting shows a confirmation dialog and a progress bar.
- **Deletes are permanent** — files are *not* moved to the Trash. The app
  targets network volumes, which don't have a Trash. Every confirmation
  spells this out.
- Press **Escape** to close the window.

### Images

Lists every image file in the directory with a thumbnail preview. Useful
for clearing out stray cover art, screenshots, etc.

Recognized image extensions:
`jpg, jpeg, png, gif, bmp, tiff, tif, heic, heif, webp, raw, cr2, nef, arw, dng, svg`.

### Text & NFO Files

Lists `.txt`, `.nfo`, and `.rtf` files with a short text-snippet preview.

### Multiple Videos per Folder

Finds top-level subfolders containing more than one video file, grouped
together so it's clear which belong together (samples, extras, etc.).
Includes a "select all but the largest" per-group shortcut.

### Empty Folders

Finds the topmost recursively-empty subfolders under the scan root,
ignoring hidden cruft like `.DS_Store`. One-click cleanup of the empty
husks left over after the other cleanup passes.

---

## Rename Library

The **Rename Library** toolbar button opens a window that builds a rename
plan for every matched movie, rewriting filenames and folders into
canonical Plex/Jellyfin form:

```
Movie Title (Year) {tmdb-12345}/
    Movie Title (Year) {tmdb-12345}.mkv
    Subs/
        Movie Title (Year) {tmdb-12345}.en.srt
        Movie Title (Year) {tmdb-12345}.de.srt
        Movie Title (Year) {tmdb-12345}.ja.srt
        Movie Title (Year) {tmdb-12345}.zh.simplified.srt
```

Highlights:

- **`{tmdb-N}` in the filename** — both Plex and Jellyfin parse this and
  bypass title-based scrapers entirely. Sidesteps fuzzy-title and year
  disagreements.
- **Title sanitization** preserves Unicode, apostrophes, ampersands, and
  exclamation marks; rewrites colons to ` - `; strips Windows-illegal
  characters (`?*<>|"`); caps the composed string at 200 chars.
- **Remux preservation** — if the original path or filename contained
  "Remux", the canonical filename ends with `[Remux]`.
- **Subtitle handling** — recognizes `.srt`, `.ass`, `.ssa`, `.sub`,
  `.idx`, `.vtt`, `.sup`, `.smi`. *Every* subtitle is renamed into the
  wrapper's `Subs/` subfolder regardless of source layout (siblings next
  to the video, contents of any `subs/` / `subtitles/` / `subz/` folder,
  loose siblings at the scan root for a top-level video — all get
  promoted to `Subs/`). Detects language tokens from filenames in 50+
  languages and 3-letter ISO codes. Detects descriptors like `commentary`,
  `director`, `simplified` / `traditional` (Chinese), `brazilian` /
  `latin` / `european` / `british` / `canadian` so two same-language
  tracks can coexist with meaningful names. Automatic `.2` / `.3` suffix
  on remaining collisions (e.g. two anonymous English tracks) so no sub
  is ever dropped.
- **VobSub `.idx` / `.sub` pairs** travel together and stay paired.
- **Duplicate-target detection** — if two source files match the same
  TMDB id, both rows get a red "duplicate" chip and start unchecked so
  you can resolve before applying.
- **Skip already-canonical rows** — opening the window after a clean
  apply doesn't show a list of "nothing to do" rows. If both video and
  every subtitle are already at canonical paths, the row is silently
  dropped from the plan.
- **Copy Preview** button — exports the entire plan as plain text for
  external review (or pasting at a language model for a sanity check).

The Apply step runs sequentially with a live "currently renaming" status
line. Each row is its own transaction in spirit: a video failure marks the
row failed and skips the subtitle pass; each subtitle failure is isolated
to that one sub so one bad rename doesn't poison the rest.

---

## Import

The **Import** toolbar button opens a wizard for bringing a `/complete`-
style staging directory into the library. Walks the user through, scoped
to the source directory:

1. **Pick Source** — choose the directory to import (e.g. `/complete/`).
2. **Match TMDB** — same UI as the standalone matcher, scoped to just the
   imported files.
3. **Images / Text / Multi-Video / Empty Folders** — same cleanup UIs,
   pointed at the import source.
4. **Rename** — same rename UI, scoped to the import source.
5. **Ready** — summary screen with the **Move to Library** button. An
   optional checkbox auto-prunes the source directory if it ends up
   empty after the move.
6. **Done** — close, or hit **Import Another** to reuse the wizard.

None of the imported files touch the persistent library database until
**Move to Library** runs. Cancelling the wizard mid-flow leaves the library
untouched (though any cleanups / renames you already applied are real
on-disk changes — those aren't undoable).

**Recommended pattern:** pick the *parent* of one or more release folders
(e.g. `/complete/` containing multiple movie folders) so each release gets
renamed in place and moved cleanly. Picking a single release folder
(`/complete/Some.Release/`) directly also works but creates a nested
canonical wrapper inside the source — the auto-prune checkbox cleans up
the empty husk afterwards.

---

## Ask Claude

A chat panel slides in from the right of the main window when the
**Ask Claude** toolbar button is clicked. Driven by the local
[`claude`](https://claude.com/claude-code) CLI, billed against your
Anthropic subscription. Asks questions like:

- "How many 4K remuxes do I have?"
- "List my unmatched movies older than 1980."
- "What's my average IMDb rating per genre?"
- "Which movies are over 50 GB?"

Claude is given the schemas of `movies`, `tmdb_movies`, `imdb_ratings`,
and `imdb_metadata` in its system prompt and restricted to `sqlite3`
queries via Claude Code's permission flags. The session resumes between
turns so context carries forward.

The button only shows if the `claude` CLI is installed
(`~/.claude/local/claude` or on PATH).

---

## Building

Builds with just the **Command Line Tools** — no full Xcode required. Uses
Swift Package Manager plus a small bundling script.

```sh
./build-app.sh        # builds and produces ./MovieStats.app
open MovieStats.app
```

To run during development without bundling:

```sh
swift run
```

### App icon

The icon (a retro TV with a film reel on screen) is generated
programmatically with Core Graphics, so it's fully reproducible:

```sh
./make-icon.sh        # renders Resources/AppIcon.png and builds AppIcon.icns
```

`build-app.sh` copies the resulting `AppIcon.icns` into the app bundle. The
generator source lives in `Tools/icon-generator/main.swift`.

### Bundled ffprobe

`build-app.sh` expects a universal `ffprobe` binary at `Resources/ffprobe`,
which is fetched once via `./Tools/fetch-ffprobe.sh` (downloads static
arm64 + x86_64 builds and `lipo`s them together). The result is bundled
into `MovieStats.app/Contents/Resources/ffprobe` and called via `Process`,
so the running app doesn't depend on a system `ffmpeg` install.

---

## How it works

- **`FileScanner`** is a single recursive `FileManager.enumerator` walk
  parameterized by extension set. Used by the movie scanner and every
  cleanup tool.
- **`MovieStore`** is a thin wrapper over the system SQLite library
  (`import SQLite3`, no Swift wrapper). Schema is additive — `migrate()`
  adds new columns rather than dropping old ones, so previous databases
  keep working.
- **`AppModel`** owns the store, runs scans off the main actor, drives the
  ffprobe pass (capped at 6 concurrent processes — gentle on network
  volumes), and exposes derived stats the views render.
- **`MediaProbe`** spawns the bundled `ffprobe`, parses JSON output into
  a `MediaInfo` struct.
- **`MovieClassifier`** maps `(width, height, codec, size)` to a
  `MovieType` bucket (UHD Remux / Blu-ray Remux / 4K Encode / 1080p
  Encode / 720p Encode / SD).
- **`TMDBService`** handles search + detail + per-country release-date
  payloads.
- **`MovieScope`** is the abstraction that lets the matcher and renamer
  run against either the live library (`AppModel`) or a transient
  `ImportSession` without changing their logic.

### Storage

- Library DB: `~/Library/Application Support/MovieStats/moviestats.sqlite`
- Poster cache: `~/Library/Application Support/MovieStats/posters/`
- TMDB API key: `UserDefaults` under `tmdbAPIKey`
- Last-opened directory: `UserDefaults` under `selectedDirectoryPath`

### Project layout

```
Sources/MovieStats/
  MovieStatsApp.swift       @main App; registers every window
  ContentView.swift         main window: toolbar + stats + ranked list
  AppModel.swift            owns store, scans, probes
  MovieScope.swift          protocol shared by AppModel + ImportSession
  Models/MovieFile.swift    in-memory movie row
  Services/                 SQLite, ffprobe, TMDB, IMDb, classifier,
                            scanner, title parser, subtitle classifier,
                            filename sanitizer, poster cache,
                            Claude CLI runner, CSV export
  FileCleanupModel/View     image + text-file cleanup
  DuplicatesModel/View      multi-video-per-folder cleanup
  EmptyFoldersModel/View    empty-subfolder cleanup
  MatcherModel/View         TMDB matching
  MatcherSearchSheet        manual TMDB pick overrides
  RenameModel/View          canonical rename plan + apply
  ImportSession/View        import wizard
  IMDbModel/View            IMDb dataset workflow
  ChatModel/Panel           Ask Claude
Tools/
  icon-generator/main.swift Core Graphics icon generator
  fetch-ffprobe.sh          one-time ffprobe download / universal-bin merge
```

For implementation deep-dives, design decisions, and the longer list of
quirks the codebase has accumulated, see `CLAUDE.md`.

---

## Notes

- The app is **not sandboxed** — the chosen folder stays readable across
  restarts without security-scoped bookmarks.
- The build is ad-hoc signed — fine for running on your own machine.
- The app targets macOS 14+ and Swift 6.
