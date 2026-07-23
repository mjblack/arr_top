# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.4] - 2026-07-23

### Fixed

- Season-pack per-episode progress now works against a live Sonarr (v0.3.3's
  attempt did not): the queue is fetched with episode data, so each episode is
  matched to its own destination file. The actively-copying episode shows a live
  bar, already-copied episodes show 100%, and not-yet-started episodes show
  pending — instead of every episode showing the same percentage.

### Added

- A **SIZE** column for each entry. While importing it shows the on-disk vs total
  bytes as a pair (e.g. `1.9/2.9 GB`, `0/2.9 GB` at the start); otherwise it shows
  just the size to import (e.g. `2.9 GB`). Present in both the TUI and the
  `--once` snapshot.

## [0.3.3] - 2026-07-22

### Fixed

- Season-pack imports now show a correct **per-episode** bar instead of the same
  bar on every episode. Each episode row matches its own destination file by its
  `SxxEyy` token: the episode currently copying shows a live bar, an
  already-imported episode shows 100%, and one whose file does not exist yet is
  shown as **pending** (no bar).

### Changed

- The media column shows the episode for Sonarr rows (e.g. `The Show S02E03`),
  not just the series name, and its header label is now **MEDIA** (it holds both
  movies and episodes).

## [0.3.2] - 2026-07-22

### Fixed

- The queue-poller fiber no longer dies on a backend error (e.g. a socket
  error). A failed poll is caught, logged, and retried on the next refresh, so
  updates resume once the backend recovers instead of the view freezing.
- A stalled import copy (no bytes gained between refreshes) now reports
  `0 B/s` instead of the header speed briefly disappearing.

### Changed

- The header transfer rate is labeled **Import Speed** (and the `↓` arrow
  removed) so it isn't mistaken for the download client's (qBittorrent) download
  rate.

## [0.3.1] - 2026-07-22

### Added

- Release GitHub Actions workflow that builds native **`.deb`** and **`.rpm`**
  packages (via nfpm) and attaches them to the GitHub release. Each installs the
  `arrtop` binary to `/usr/bin/arrtop`, a man page to
  `/usr/share/man/man1/arrtop.1`, and an example config to
  `/etc/arr_top/config.yaml.example`.
- Config lookup now also checks **`/etc/arr_top`**: the resolution order is
  `--config` → `$ARR_TOP_CONFIG` → `./config.{yaml,yml,json}` →
  `/etc/arr_top/config.{yaml,yml,json}` → none (a local config still wins over the
  system one).
- A man page, `arrtop(1)`.

## [0.3.0] - 2026-07-22

### Changed

- **Redesigned TUI.** The full-screen view is now framed in a double-line box
  with a header (app title, queue-counts summary, and an aggregated import
  transfer speed), a column-label row, and a divider.
- Columns are now **Movie · Torrent · Status · Progress**. The **Movie** column
  shows the media name (`series.title` / `movie.title`), distinct from the
  torrent/release title; both name columns are fixed-width and truncated.
- Progress uses a bracketed **block bar** (`█`) — light-blue filled, light-grey
  remainder (color-only distinction, so it renders consistently across fonts).
  Bars show only for `downloading`/`importing`; `importPending` (backlog) shows
  no bar or percent.
- **Status colors**: importing = green, pending = purple, downloading = blue,
  failed/warning = red.

### Added

- A configurable color `Theme` (`src/arr_top/theme.cr`) holding all colors and the
  bar glyphs, auto-disabled under `NO_COLOR` or on a non-TTY. Exposing it via the
  config file is planned future work; for now it uses the built-in default.
- `QueueRow#media_name`; `ImportRateTracker#measure` exposes the copy rate (for the
  header's aggregated transfer speed) alongside the ETA.

## [0.2.0] - 2026-07-22

First tagged release. A `top`-style terminal UI for the Sonarr/Radarr
download → import pipeline, sorted by what's actively importing.

### Added

- **Typed queue poller.** Aggregates the queues of any number of Sonarr/Radarr
  backends into a normalized `QueueRow` model, sorted importing-first. Per-backend
  errors are surfaced without failing the whole view.
- **Import disk-watch.** For a row that is `importing`, reads the growing
  destination file on disk to compute a live **copy percentage** the *arr API
  does not expose (`ImportWatch`), plus an ETA derived from the measured copy
  rate (`ImportRateTracker`). Runs a manual, glob-safe recursive walk and degrades
  to "unknown" off-host rather than crashing.
- **Full-screen TUI.** Fiber-driven polling (a slow/hung backend never blocks the
  UI or keyboard-quit), download + import progress bars, resize handling, and a
  guaranteed terminal restore on quit / exception / SIGINT / SIGTERM / at_exit.
  Falls back to a plain snapshot on a non-TTY; `--once`/`-1` prints one snapshot.
- **Config + CLI.** YAML or JSON config (`--config`, `ARR_TOP_CONFIG`, or the
  first of `./config.{yaml,yml,json}`), `--help`/`--version`, and stderr logging.
- Built with `-Dpreview_mt`; depends on the public `sonarr` (0.2.1) and `radarr`
  (0.1.2) shards, which add a configurable HTTP client timeout.
