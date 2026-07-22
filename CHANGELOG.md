# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
