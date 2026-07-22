# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
