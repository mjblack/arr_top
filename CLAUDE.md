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
  size`. Completion = `movie.hasFile`/`episodeFile` flips true.
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
- **`src/arr_top/cli.cr`** — `CLI.run` resolves the config path (`config_path`:
  `-c`/`--config` → `ARR_TOP_CONFIG` → first of `./config.yaml,.yml,.json` →
  `nil`), loads + validates, sets up logging, builds backends (`build_backends`
  maps `type` → `SonarrBackend`/`RadarrBackend`, preserving order), polls once,
  and prints a plain snapshot table (placeholder for the TUI). `--help`/`--version`
  short-circuit. `config_path`/`build_backends` are `self.` methods so they're
  unit-tested offline.
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
