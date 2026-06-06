# Movie File Renaming — Roadmap

A sketch for adding a "Rename Library" feature that brings on-disk
filenames in line with the de facto Plex / Jellyfin / Radarr standard,
using each movie's already-persisted TMDB match as the source of truth.

---

## Target naming convention

Per-movie folder + ID-embedded filename, matching Radarr's default:

```
Movies/
  Movie Title (YYYY) {tmdb-12345}/
    Movie Title (YYYY) {tmdb-12345}.mkv
    Movie Title (YYYY) {tmdb-12345}.en.srt
    Subs/
      Movie Title (YYYY) {tmdb-12345}.de.srt
      Movie Title (YYYY) {tmdb-12345}.ja.srt
```

The TMDB ID inside `{tmdb-N}` is the killer move — both Plex and Jellyfin
parse it and bypass their title-based scrapers entirely. Sidesteps every
year-disagreement / fuzzy-title issue we spent the day on.

### Title sanitization rules

Applied to the composed `"{Title} ({Year}) {tmdb-N}"` string before it
hits disk:

| Character | Action | Reason |
|---|---|---|
| `:` | replace with ` -` | banned on Windows / SMB |
| `/`, `\` | replace with `-` | path separators |
| `?`, `*`, `<`, `>`, `\|`, `"` | strip | filesystem-illegal on Windows |
| Trailing `.` or ` ` | strip | invalid on Windows |
| Multiple spaces | collapse to one | cosmetic |
| Unicode / diacritics | **preserve** | UTF-8 works on APFS/NTFS/SMB-modern; never transliterate `é→e` |
| Length cap | 200 chars total | filesystem 255-byte limit |
| `&`, `!`, `'`, `,`, parens | preserve | legal everywhere, common in titles |

---

## Cases to handle

### 1. Loose video at the top level (no folder)

```
Movies/SomeFilm.2019.1080p.mkv
```

Create `Movies/Movie Title (2019) {tmdb-N}/`, move the video into it,
rename in place.

### 2. Video inside a folder (typical)

```
Movies/SomeFolder/SomeFilm.2019.1080p.mkv
```

Rename the containing folder *and* the video. End state matches case 1.

### 3. Sidecar `.srt` in the same folder as the video

Rename the SRT so its base matches the video and any detected language
tag survives in ISO 639-1 form:

| Before | After |
|---|---|
| `SomeFilm.2019.srt` | `Movie Title (2019) {tmdb-N}.srt` |
| `SomeFilm.2019.eng.srt` | `Movie Title (2019) {tmdb-N}.en.srt` |
| `SomeFilm.2019.fra.forced.srt` | `Movie Title (2019) {tmdb-N}.fr.forced.srt` |

Plex / Jellyfin auto-detect `.en.srt` etc. from the base name; preserve
that information when it's already there.

### 4. Subfolder full of `.srt` files

**Canonical folder name:** `Subs`. There's no formal RFC, but `Subs/`
is the dominant convention — release groups, scene tools, Radarr,
FileBot, TinyMediaManager all produce it, and both Plex and Jellyfin
scan it without configuration. `Subtitles` works too but is rarer.

- Rename whatever the folder is called (`SUB`, `Subtitles`, `subs`, `s`)
  to canonical `Subs`.
- Inside, rename each `.srt` to `{video_base}.{lang}.srt` when the
  language is detectable from the filename or path; otherwise keep the
  original stem (still inside the canonical `Subs/` folder).
- Language detection: scan for ISO 639-1/2/3 codes (`en`, `eng`, `es`,
  `spa`, `fr`, `fra`, `fre`, `ja`, `jpn`, …) and normalize to the
  ISO 639-1 short form for Plex/Jellyfin.

### Cases punted to later phases

- Multiple videos in one folder (extras / specials / sample) — flag, don't touch.
- Multi-disc films (`Movie - CD1.mkv` / `CD2.mkv`) — detect, skip.
- Already-canonical files — detect via regex on the proposed pattern, skip silently.

---

## UX

Destructive disk operations. Mirror the existing cleanup-tool UX:

1. New **"Rename Library"** toolbar button + dedicated window.
2. Window lists every matched movie (`tmdbId != nil`) in a 3-column table:
   - Current path (file or folder)
   - Proposed path
   - Per-row checkbox (default checked when proposed ≠ current)
3. Header shows count + sanity line: "N rows would be renamed".
4. Footer: **Select All / Deselect All** (consistent with the matcher),
   **Apply** (borderedProminent), **Cancel**.
5. Apply triggers a confirmation modal with the existing destructive
   language ("These changes are permanent and not undoable").
6. Apply runs serially with a progress bar + currently-acting path. Each
   row's failure is captured and surfaced inline; the loop continues.

---

## Persistence

`movies.path` is the primary key in SQLite. Each successful rename has
to update the row's `path` and `filename` in the same transaction the
rename runs in, or the `tmdb_id` link orphans.

Add to `MovieStore`:

```swift
func updatePath(oldPath: String, newPath: String, newFilename: String) throws
```

Called from the renamer immediately after each successful `FileManager.moveItem`.

---

## Implementation sketch

### New files

- `Sources/MovieStats/RenameModel.swift` — `@Observable` model; builds
  the rename plan from `appModel.movies`, exposes `rows: [RenameRow]`,
  drives Apply serially.
- `Sources/MovieStats/RenameView.swift` — the new window UI; mirrors
  the MatcherView pattern.
- `Sources/MovieStats/Services/FilenameSanitizer.swift` — pure functions
  for composing + sanitizing the canonical filename. Testable in
  isolation.
- `Sources/MovieStats/Services/SubtitleClassifier.swift` — language code
  detection in subtitle filenames.

### Wired into existing files

- `MovieStatsApp.swift` — register the new `Window`.
- `ContentView.swift` — add a "Rename Library" toolbar button next to
  "Match TMDB".
- `Services/MovieStore.swift` — `updatePath(...)` method.

---

## Risks & open questions

1. **Network volumes**: most movies live on a NAS. Same-volume renames
   use `rename(2)` (atomic, fast); cross-volume copies-then-deletes
   (slow, not atomic). `FileManager.moveItem` handles both; surface
   slow ones.
2. **Case-insensitive filesystems** (default APFS): `Avatar.mkv` →
   `avatar.mkv` is a no-op. Detect and skip.
3. **Collection folders** (e.g. `Marvel/Avengers (2012).mkv`): the
   user-organized layer above the per-movie folder should be respected.
   Only rename the *immediate* movie folder + the file inside it; never
   flatten upward.
4. **TMDB title vs filename's parsed title**: the proposed name uses the
   TMDB-canonical title, not the user's parsed one. Surface in the
   preview so the user can compare.
5. **Missing `tmdb_movies` row** for a path that has `tmdb_id` set:
   skip the row, surface a warning.
6. **Backup / undo**: not in scope for v1. Phase 4 could write an
   append-only log of `(oldPath, newPath, ts)` we could replay in
   reverse.

---

## Phase plan

**Phase 1 — preview-only MVP**
- `FilenameSanitizer` with unit tests
- `RenameModel` plan generator (no execution)
- `RenameView` showing the proposed renames; **no Apply yet**
- Lets us eyeball what would happen across the whole library before
  any byte hits disk.

**Phase 2 — execution**
- Apply with serial execution + progress + per-row error reporting
- `MovieStore.updatePath`
- Confirmation modal

**Phase 3 — subtitles**
- Sidecar `.srt` renames
- `Subs/` folder canonicalization
- `SubtitleClassifier` language detection

**Phase 4 — polish**
- Edition tag handling (`{edition-Director's Cut}` etc.)
- Multi-disc detection + handling
- Move log + reverse-replay undo
