# Movie Stats

A small, personal macOS app for taking stock of a movie library that lives on
disk (typically a network drive). You point it at a directory, it recursively
scans every file and subfolder, and it reports stats about the movies it finds.
Results are stored in a local SQLite database, so the stats are available
instantly on the next launch without rescanning.

Beyond the movie stats, it includes a few **cleanup tools** for tidying up a
media folder: surfacing stray images, leftover `.txt`/`.nfo` files, and folders
that contain more than one video.

> **Scope:** built for personal use — to be compiled and run on your own
> machine, not distributed.

---

## Main window

Pick a folder and the app crawls it (including all subfolders) for movie files,
then shows:

- **Movies** — total number of movie files found.
- **Larger than 20 GB** — how many of those exceed 20 GiB (a quick way to spot
  the heavyweights).
- **Total Size** — combined size of the whole library.
- **Movies by size** — a ranked list of every movie, largest first, each row
  showing the filename, full path, and size.

A movie is any file whose extension is one of:
`mp4, mkv, avi, mov, m4v, wmv, flv, webm, mpg, mpeg, m2ts, ts, vob, ogv`.

### Toolbar

- **Open Directory** — choose a folder to scan; scanning starts immediately.
- **Rescan** — re-crawl the current folder and refresh the stored snapshot.
- **Scan Images** — opens the Images cleanup window (below).
- **Scan Text Files** — opens the Text & NFO cleanup window (below).
- **Find Duplicates** — opens the Multiple Videos per Folder window (below).

The most recently opened directory is remembered across restarts, so **Rescan**
and the cleanup tools target the same folder after relaunching.

---

## Cleanup tools

Each tool opens in its own window, scans the current directory (recursively),
and lets you select files with per-row checkboxes and delete them. A few shared
behaviors:

- **Select All / Deselect All** toggles the whole list.
- Deleting shows a **confirmation dialog** and a **progress bar** while it runs,
  then **refreshes** the list to reflect what remains.
- **Deletes are permanent** — files are *not* moved to the Trash. This is
  deliberate: the app targets network volumes, which generally don't support a
  Trash. The confirmation dialog spells this out.
- Press **Escape** to close any of these windows.

### Images

Lists every image file in the directory in a table: a checkbox, a small
**thumbnail preview**, the filename + full path, and the size. Use it to find
and remove stray cover art, screenshots, etc.

Recognized image extensions:
`jpg, jpeg, png, gif, bmp, tiff, tif, heic, heif, webp, raw, cr2, nef, arw, dng, svg`.

### Text & NFO Files

Same table layout as Images, but for `.txt` and `.nfo` files, with a short
**text snippet preview** (the first few lines) instead of a thumbnail. Handy for
clearing out leftover metadata/readme files.

### Multiple Videos per Folder

Finds top-level folders that contain **more than one** video file, and groups
them so it's clear which belong together. Videos are bucketed by their
**top-level subfolder** under the scanned root — even if they're nested at
different depths.

For example, scanning `/media` where:

```
/media/videofolder/video.avi
/media/videofolder/subfolder/video2.avi
```

surfaces `videofolder` as having **2 videos**, even though the two files live in
different subfolders. The window shows each such folder as a section (with a
count) listing its videos (largest first), with checkboxes to delete the ones
you don't want.

---

## Building

This project builds with just the **Command Line Tools** — no full Xcode
required. It uses Swift Package Manager plus a small bundling script.

```sh
./build-app.sh        # builds and produces ./MovieStats.app
open MovieStats.app
```

To run during development without bundling:

```sh
swift run
```

### App icon

The icon (a retro TV with a film reel on screen) is generated programmatically
with Core Graphics, so it's fully reproducible:

```sh
./make-icon.sh        # renders Resources/AppIcon.png and builds AppIcon.icns
```

`build-app.sh` copies the resulting `AppIcon.icns` into the app bundle. The
generator source lives in `Tools/icon-generator/main.swift`.

---

## How it works

- **`FileScanner`** recursively walks a folder with `FileManager.enumerator`,
  returning files whose extension is in a given set. `DirectoryScanner` (movies),
  `ImageScanner`/`CleanupCategory` (images, text), and the duplicate finder all
  build on it.
- **`MovieStore`** is a tiny, dependency-free wrapper over the system SQLite
  library. The `movies` table (`path`, `filename`, `size`, `date_scanned`) is
  the single source of truth for movie stats and is where future per-file
  metadata will live as new columns.
- **`AppModel`** owns the store, runs scans off the main actor (so the UI stays
  responsive), and exposes the derived stats the SwiftUI views render.
- **`FileCleanupModel` / `DuplicatesModel`** back the cleanup windows: scanning,
  selection, and permanent deletion with progress.
- Previews are produced off the main actor — image thumbnails via `Thumbnailer`
  (ImageIO downsampling, so large photos don't blow up memory) and text snippets
  via `TextPreview` (reads only the first chunk of the file).

The movie database lives at
`~/Library/Application Support/MovieStats/moviestats.sqlite`.

### Project layout

```
Sources/MovieStats/
  MovieStatsApp.swift     # @main App; defines the main + cleanup windows
  ContentView.swift       # main window: toolbar + stats + ranked list
  AppModel.swift          # owns the store, scanning, derived stats
  CleanupCategory.swift   # describes a cleanup file type (images, text)
  FileCleanupModel.swift  # scan/select/delete for Images and Text windows
  FileCleanupView.swift   # shared UI for Images and Text windows
  DuplicatesModel.swift   # groups videos by top-level folder
  DuplicatesView.swift    # Multiple Videos per Folder window
  Models/
    MovieFile.swift       # a scanned movie (path, filename, size, dateScanned)
  Services/
    FileScanner.swift     # shared recursive directory walk
    DirectoryScanner.swift# movie-extension scan
    MovieStore.swift      # SQLite persistence
    Thumbnailer.swift     # image thumbnails (ImageIO)
    TextPreview.swift     # text-file snippet previews
Tools/icon-generator/     # Core Graphics app-icon generator
```

---

## Notes

- The app is **not sandboxed**, which keeps things simple for personal use: the
  chosen folder stays readable across restarts without security-scoped
  bookmarks.
- The build is ad-hoc signed — fine for running on your own machine.
- Future direction: read movie **metadata** (resolution, codec, runtime, …) and
  surface it alongside the basic stats; the SQLite schema is designed to grow
  into this by adding columns.
