# Movie Stats

A small, personal macOS app that scans a directory (including subfolders) for
movie files and shows stats about them. Scan results are stored in a local
SQLite database so stats are available instantly on restart without rescanning.

## Features

- **Open Directory** — pick a folder; it scans immediately.
- **Rescan** — re-crawl the current folder and refresh the stored snapshot.
- Two placeholder toolbar buttons for future features.
- Main window stats: number of movies, number larger than 20 GB, total size.

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

## How it works

- **`DirectoryScanner`** recursively walks the chosen folder with
  `FileManager.enumerator` and keeps files with known movie extensions.
- **`MovieStore`** is a tiny, dependency-free wrapper over the system SQLite
  library. The `movies` table (`path`, `filename`, `size`, `date_scanned`) is
  the single source of truth and is where future per-file metadata will live as
  new columns.
- **`AppModel`** owns the store, runs scans off the main actor, and exposes the
  derived stats the SwiftUI views render.

The database lives at
`~/Library/Application Support/MovieStats/moviestats.sqlite`.

## Notes

- The app is **not sandboxed**, which keeps things simple for personal use: the
  chosen folder stays readable across restarts without security-scoped
  bookmarks.
- The build is ad-hoc signed — fine for running on your own machine.
