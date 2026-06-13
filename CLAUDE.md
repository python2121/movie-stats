# Movie Stats

A macOS app for managing a movie library on disk — typically a network
share. Point it at a directory, and it indexes every file, matches each
one to TMDB, surfaces cleanup work, renames to canonical Plex / Jellyfin
form, and imports new releases.

![Movie Stats main window](Screenshot%20Movie%20Stats.png)

Library state — paths, sizes, ffprobed metadata, TMDB matches, IMDb
ratings, watch state, subtitle inventory, bonus content — lives in a
single SQLite database under `~/Library/Application Support/MovieStats/`,
so the app is instant on relaunch and queryable from the built-in
**Ask Claude** panel.

Single-user, ad-hoc-signed, unsandboxed, built for personal use against
network-attached storage.

---

## Features

- **Library overview** — totals, by-codec / by-resolution / by-HDR
  breakdowns, ranked list or Plex-style poster grid, decade / genre /
  rating / watched filters.
- **TMDB matching** — auto-match by parsed title + year with fuzzy
  fallback, per-row manual-pick sheet, optional custom-edition label
  (e.g. `4K77 v1.4`, `Director's Cut`), poster + detail caching.
- **Quality-aware grouping** — multiple files for the same
  `(tmdbId, customEdition)` slot collapse into one library row; alternate
  editions stay separate. Per-row Play menu lets the user pick a quality.
- **Rename Library** — canonicalize files, folders, and sidecar
  subtitles to `Title (Year) {tmdb-N}/Title (Year) {tmdb-N}.ext` in one
  reviewable batch. Subs into `Subs/`, extras into `Other/`,
  collision-safe `.N` suffixes when names would clash.
- **Import wizard** — staging-directory → match → cleanup → rename →
  move into library, with **Replace** confirmation for files that already
  exist in the library and **Extra** marking that routes bonus videos
  into the canonical `Other/` folder.
- **Cleanup tools** — image / text / NFO / multi-video-per-folder /
  empty-folder finders, each with previews and permanent-delete actions.
- **IMDb ratings** — bulk-loaded from IMDb's public dataset, joined into
  the library list and detail sheet as a chip.
- **Library health reports** — missing English subs, upgrade candidates,
  duplicate TMDB matches, VobSub orphans, unmatched movies, space savers.
- **Curation** — per-movie watch state + 1–5 star personal rating;
  "Surprise Me" weighted random picker; collection completeness against
  TMDB franchises; CSV export.
- **Ask Claude panel** — natural-language queries against the SQLite
  database via the local `claude` CLI, restricted to read-only sqlite3.

---

## Quick start

Requirements:

- macOS 14+
- Swift 6 toolchain (Xcode Command Line Tools is sufficient — no full IDE)
- TMDB API key (paste in MovieStats → Settings → TMDB API Key on first
  run)

### Dev iterate

```sh
swift run
```

### Release build (bundled .app)

```sh
./Tools/fetch-ffprobe.sh    # one-time: fetch universal ffprobe binary
./build-app.sh              # produces ./MovieStats.app (ad-hoc signed)
open MovieStats.app
```

Optional: install [IINA](https://iina.io) for the Play button to launch
there instead of the system default player. Install + authenticate the
[`claude` CLI](https://docs.anthropic.com/en/docs/claude-code/overview)
for the Ask Claude panel; the panel hides itself when the binary isn't
found.

---

## Architecture

```
SwiftUI views ─→ @Observable @MainActor models ─→ services ─→ SQLite / disk / network

AppModel ─┬─→ MovieStore (SQLite)
          ├─→ DirectoryScanner / FileScanner / SubtitleScanner
          ├─→ MediaProbe (ffprobe subprocess) → MovieClassifier
          └─→ TMDBService → PosterCache

Matcher / Rename / Import ─→ MovieScope protocol ─→ AppModel or ImportSession
```

- **`AppModel`** owns the live library; SQLite-backed; drives the main
  window. Conforms to `MovieScope`.
- **`ImportSession`** owns the import wizard's in-memory snapshot;
  changes don't reach the persistent library until Move to Library
  fires. Conforms to `MovieScope`.
- **`MovieScope`** is the abstraction that lets the matcher + rename
  engine run against either context unchanged.
- **`MovieStore`** wraps `import SQLite3` directly (no Swift package).
  Tables: `movies` (the catalog), `tmdb_movies` (shared metadata cache),
  `imdb_ratings` (bulk dataset), `subtitle_files` (sidecar inventory),
  `extras` (bonus content), `imdb_metadata` (singleton timestamp).

Each tool window has its own `*Model.swift` + `*View.swift` pair under
`Sources/MovieStats/`.

---

## Conventions that are load-bearing

These constrain the design — don't change without thinking through the
consequences.

- **Permanent deletes, no Trash.** Every destructive path uses
  `FileManager.removeItem` directly. The library targets SMB / AFP
  volumes where Trash doesn't exist. Confirmation dialogs spell this
  out.
- **Additive-only schema migrations.** `MovieStore.migrate()` adds
  columns; it never drops or renames them. Databases in the wild
  predate every feature and stay valid forever.
- **No sandboxing.** The app is ad-hoc signed and runs unsandboxed.
  Library paths come from a standard `NSOpenPanel` and persist in
  `UserDefaults` — no security-scoped bookmarks.
- **`{tmdb-N}` is the canonical id-in-filename tag.** Embedded in both
  the wrapper folder *and* the file. `TMDBService.tmdbID(fromPath:)`
  reads the file's basename only — ancestor folders are ignored so
  nested files (subtitles, extras) don't inherit their wrapper's id by
  accident.
- **`Subs/` is the canonical subtitle subfolder.** Sidecar subs become
  `<wrapper>/Subs/<base>.<lang>[.descriptor][.sdh][.forced].<ext>`.
  Two subs that would compose to the same name get `.2`, `.3`, …
  suffixes (lossless). Input recognition accepts any case of `Subs`,
  `Subtitles`, `Subtitle`, `Sub`, `Subz`, `S`.
- **`Other/` is the canonical extras subfolder.** Plex's recognized
  catch-all for bonus content (also recognized by Jellyfin). The import
  wizard's Multi-Videos step routes Extra-marked videos there; the
  Rename step does the move; the `extras` table records each.
- **Multi-quality grouping** keys on `(tmdbId, customEdition)`. Two
  copies of the same edition collapse into one library row; two
  editions of the same TMDB id (Theatrical + Director's Cut) stay
  separate. Extras are attributed by TMDB id and surfaced on every
  edition of that movie.
- **`confirmed_year` is the matcher's lock-in.** TMDB's search and
  details endpoints don't always agree on release year for foreign films
  / festival-circuit releases. The matcher locks the year the user saw
  at confirm time so subsequent rebuilds of the rename plan don't
  silently flip it.
- **`first_seen_at` is the "added to library" timestamp.** Set once on
  INSERT; rescans never touch it. `date_scanned` is rewritten every
  rescan and is useless for "added" semantics.
- **`ffprobe` is bundled.** The release `.app` ships a universal binary
  fetched by `Tools/fetch-ffprobe.sh`. Never assume it's on the user's
  PATH.
- **`@MainActor` types are not `Sendable`.** `AppModel`, `MovieStore`,
  etc. can't be captured into `Task.detached` closures. Pull the
  values you need first, then capture those.

---

## Permission and timing rules in the import wizard

- **Matcher auto-commits in embedded mode.** Picking a candidate in
  the wizard's Match step writes the basic `(tmdbId, confirmedYear,
  customEdition)` straight to the session immediately — no need to
  click matcher-Confirm before advancing. Standalone library matcher
  still uses explicit Confirm as the atomic checkpoint.
- **Replace deletion is deferred to step 8 (Move to Library).** The
  Match-step confirmation dialog records consent but performs no
  destructive work. `ImportSession.performReplacements` is `private`
  and called from exactly one site: inside `moveToLibrary`, after
  every other step has succeeded. Keeping it private is load-bearing.
- **Extras relocation runs in step 7 (Rename).** The Rename Library
  table folds extras in as their own rows (pink `extra` chip,
  before/after directory-structure preview). Apply moves them into
  `<parent's canonical wrapper>/Other/` and pulls sibling subtitles
  along. Move-to-Library just walks the wrappers; extras ride along
  inside.

---

## Common code patterns

- `@Observable @MainActor` state holders, injected via
  `.environment(...)`.
- `Task.detached(priority: .userInitiated)` for filesystem walks,
  ffprobe subprocesses, and TMDB requests.
- `await Task.yield()` between rows of long synchronous work so the
  UI repaints the progress indicator.
- Plain `UPDATE` over `INSERT OR REPLACE` for path-keyed rows. Writes
  that don't match a row silently no-op — that's load-bearing for the
  import session's in-memory-vs-DB write semantics.

---

## Working in this codebase

- No comments restating what the code does. Comments are for surprising
  invariants, performance constraints, or workarounds — not narration.
- No new dependencies casually. One external package today
  (`swift-markdown-ui`); everything else is Foundation / AppKit /
  SwiftUI / `import SQLite3` / `Process`.
- Diffs over essays. Make the change; note non-obvious decisions in
  one line.
- When in doubt, read the existing per-feature files in
  `Sources/MovieStats/` — each tool ships as a paired `*Model.swift` +
  `*View.swift` and is self-contained.
