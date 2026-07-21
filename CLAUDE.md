# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

**arrtop** (`arr_top`) is a Crystal **application**: a `top`-style terminal UI
for the Sonarr/Radarr download → import pipeline. It polls the *arr queue, sorts
by what's actively importing, and draws progress bars — including **import (copy)
progress** the *arr API doesn't expose, read from the destination file on disk.

- Repo: **`github.com/mjblack/arr_top`** (private, for now). Binary/target is
  **`arrtop`**; module is `ArrTop`.
- Language/toolchain: Crystal `>= 1.20.2`.

## Build — always via the Makefile

The binary **MUST** be built with **`-Dpreview_mt`** (multi-threaded runtime;
arrtop's fibers — queue polling + per-import file watching — run across threads).
The Makefile bakes in the flag; never hand-run `crystal build` without it.

- `make build` → `bin/arrtop` (`-Dpreview_mt`) · `make release` (optimized)
- `make test` (`crystal spec`) · `make check` (format --check) · `make lint`
  (ameba) · `make format` · `make run ARGS="…"` · `make clean`

## Dependencies

Reuse our own shards (both **public** on GitHub — no token needed):

- **`sonarr`** (`github: mjblack/sonarr`, 0.2.0) — typed Sonarr API v3 client.
- **`radarr`** (`github: mjblack/radarr`, 0.1.1) — typed Radarr API v3 client.

No qBittorrent/download-client dependency: arrtop works from the *arr queue plus
the destination file on disk, not the download client. `ameba` is the dev/lint dep.

## Design (validated against a live Radarr)

- **Queue (API):** `GET /api/v3/queue` (via the shards) gives
  `trackedDownloadState` (the sort key), and `size`/`sizeleft`/`timeleft` for
  **download** bars.
- **Import (disk):** for an item whose state is `importing`, the API gives the
  **destination folder** (`movie.path` / `series.path`) and the **copy target**
  (`queue.size`); it does NOT give copy progress (`sizeleft: 0`, `hasFile:
  false`). Read the growing destination file's size on disk → `import% = bytes /
  size`. Completion = `movie.hasFile`/`episodeFile` flips true. Implemented in
  **`src/arr_top/import_watch.cr`** — `ImportWatch.progress(dest_folder, target)`
  → `ImportProgress?` — with these load-bearing details:
  - **Recursive walk** of the folder (Sonarr drops the file in a `Season NN/`
    subfolder), collecting regular files.
  - **Never `Dir.glob`.** *arr folder names contain glob metacharacters
    (`… {tmdb-329} [Bluray-1080p]`) that `Dir.glob` would misread as patterns, so
    the walk is manual (`Dir.children` + `File.info`), each FS call rescued
    (files vanish mid-copy; dirs can be unreadable → skip).
  - **Most-recent-mtime** wins among video files (extension set), not
    largest-size — during an upgrade the old full file sits beside the new
    partial one and "largest" would pick the wrong one.
  - `percent` clamps to `[0, 100]`. Off-host (folder missing/unreadable) or
    file-not-yet-created → `nil`; the CLI renders that as `—` in the `IMPORT%`
    column (`Log.debug`, not error — off-host is expected, must never crash).
- **Must run on the *arr host.** The import bar reads the file the *arr is
  writing; only the writing host's kernel reports its size in real time.
  Watching over NFS from another client is coarse (writer-flush granularity) even
  with `actimeo=0` — the limit is the writer's flush cadence, not reader cache.
  An API-only mode (download bars + import state, no copy %) can run anywhere.

## Config, CLI, and logging

- **`src/arr_top/config.cr`** — `ArrTop::Config` is both `YAML::Serializable` and
  `JSON::Serializable` (same shape in both). Top-level `backends : Array(Backend)`;
  each `Backend` has `name`, `type` (`BackendType` enum, serialized lowercase
  `sonarr`/`radarr`, parsed leniently via `BackendTypeConverter` so an unknown
  value becomes `nil` and surfaces as a validation error, not a parse crash),
  `url`, and `api_key`. `Config.from_file` picks the parser by extension
  (`.yaml`/`.yml` → YAML, `.json` → JSON, else YAML-then-JSON), wrapping
  `File::Error` as `Config::Error`. `#validate`/`#validation_errors` require ≥1
  backend and non-blank `name`/`url`/`api_key` + a recognized `type` per backend.
  Optional top-level **`refresh`** (`String?`) sets the TUI redraw interval —
  `#refresh_span : Time::Span` parses `<int>s` / `<int>ms` / a bare integer
  (seconds), defaulting to **2s**; an unparseable-when-set value is a validation
  error.
- **`src/arr_top/cli.cr`** — `CLI.run` resolves the config path (`config_path`:
  `-c`/`--config` → `ARR_TOP_CONFIG` → first of `./config.yaml,.yml,.json` →
  `nil`), loads + validates, sets up logging, and builds backends
  (`build_backends` maps `type` → `SonarrBackend`/`RadarrBackend`, preserving
  order). It then **runs the TUI when `STDOUT.tty?`** (and `--once`/`-1` was not
  given); otherwise — piped/redirected stdout, CI, or `--once` — it prints the
  one-shot plain snapshot table (with the live `IMPORT%` column;
  `—` off-host / non-importing). Snapshot writes are wrapped in `rescue
  IO::Error` so `arrtop | head` (closed stdout) exits quietly.
  `--help`/`--version` short-circuit. `config_path`/`build_backends`/`tui?`/
  `once?` are `self.` methods so they're unit-tested offline.

## TUI (`src/arr_top/{tui,terminal,render,import_rate}.cr`)

The full-screen live view. **`TUI#run`** loops poll → draw → wait: it polls
`Poller#rows`, computes live `ImportWatch.progress` + an ETA per `Importing`
row, builds one frame (header, red `⚠` lines for `Poller#errors`, one row each,
capped to the terminal height) and writes it in a single `print` (cursor-home +
per-line clear-to-EOL + clear-to-EOS) to avoid flicker. It redraws every
`refresh` **or** the instant a key arrives — a reader fiber feeds keypresses to a
channel that the loop `select`s against `timeout(@refresh)` (needs
`-Dpreview_mt`). `q`/`Q`/Ctrl-C quits.

- **`render.cr`** — PURE, I/O-free, and the only part under unit test: `bar`,
  `human_bytes`, `human_duration`, `truncate`, `header`, `render_row` (import bar
  from `import.percent` for `Importing`, else download bar from
  `download_percent`; width-aware so a line never wraps).
- **`import_rate.cr`** — `ImportRateTracker#eta(dest_folder, progress)` derives a
  best-effort import ETA from two successive disk readings
  (`remaining ÷ bytes-per-sec`), keyed by `dest_folder`, using `Time.monotonic`
  (the `now` is injectable for tests); `nil` until it has two samples or on a
  file/rate reset. Download rows use the API's `timeleft`/`eta` instead.
- **`terminal.cr`** — low-level control. `Terminal.size` reads `TIOCGWINSZ` via a
  bound `LibC.ioctl` each redraw (so resize needs no `SIGWINCH`), falling back to
  `{24, 80}`. `#start` enters the alt screen + hides the cursor + puts STDIN in
  raw/no-echo (`IO::FileDescriptor#raw!`). **Terminal restore is guaranteed on
  every exit path** — the `ensure` in `run`, `SIGINT`/`SIGTERM` traps, and an
  `at_exit` backstop all call one **idempotent** `#restore` (leave alt screen,
  show cursor, cooked mode). Never leave the terminal raw/hidden.
- **`src/arr_top/logging.cr`** — `ArrTop.setup_logging` configures `::Log` to
  **stderr** (so the future TUI owns stdout), currently **pinned to Info**; the
  `level` param exists for the later configurable-level phase. `Log` sources are
  scoped `arrtop.<area>` (`arrtop.cli`, `arrtop.poller`).
- Config files are gitignored except the committed `config.example.{yaml,json}`.

## Workflow (GitHub, PR-based)

Repo `mjblack/arr_top` (private). Work on feature branches, open PRs, CI must be
green before merge. Coordinator owns git/PRs; subagents implement on branches.

## Gotchas

- `shard.lock` **is** committed (this is an application).
- Always build with the Makefile so `-Dpreview_mt` is never dropped.
- Dependencies (`sonarr`, `radarr`) are public, so CI needs no token.
