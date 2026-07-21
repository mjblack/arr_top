# arrtop

A `top`-style terminal UI for the **Sonarr/Radarr** download → import pipeline.
It shows the queue sorted by what's actively **importing**, with real progress
bars — including the one the *arr API can't give you: **import (copy) progress**.

> **Status: early.** The data layer (typed queue poller), config + CLI,
> logging, and the **import disk-watch** are in place; a plain snapshot of the
> queue — now with a live `IMPORT%` column — prints to stdout. The TUI is the
> next work.

## Why it exists

The *arr API tells you a lot about the queue for free — `trackedDownloadState`
(`downloading`/`importPending`/`importing`), and `size`/`sizeleft`/`timeleft`
for a **download** progress bar. But once a download completes and the *arr is
**copying** the file into the library, the API reports only "importing" with
`sizeleft: 0` and `hasFile: false` — **no copy progress at all**. On a
cross-filesystem import (e.g. a remote/seedbox source), that copy can take an
hour with zero feedback.

`arrtop` fills that gap by reading the destination file directly:

```
queue (API)         → sort by trackedDownloadState; download bars from size/sizeleft
importing item      → movie.path / series.path (API: the destination folder)
                    → queue.size              (API: the copy's final size = the target)
                    → destination file size   (disk: the one number only disk knows)
import %            = file bytes / target
done                = movie.hasFile flips true (movieFile.path populates)
```

## The import disk-watch

For a row whose state is `importing`, `ArrTop::ImportWatch.progress` turns the
API's destination **folder** plus copy **target** (`queue.size`, carried on the
row as `import_target`) into a live copy percentage read straight off disk:

- **Recursive walk.** The destination is a folder — Radarr's movie folder, or
  Sonarr's series folder where the file lands in a `Season NN/` subfolder — so
  the walk descends into subfolders to collect every regular file.
- **No `Dir.glob` (metacharacter gotcha).** Real *arr folder names embed glob
  metacharacters — `Jurassic Park (1993) {tmdb-329} [Bluray-1080p]` — that
  `Dir.glob` would interpret as patterns instead of literal path segments. The
  walk is therefore **manual** (`Dir.children` + `File.info`), and every
  filesystem call is rescued so a file that vanishes mid-copy or an unreadable
  subdirectory is skipped, not fatal.
- **Most-recent-mtime selection.** Among the video files (`.mkv .mp4 .avi .m4v
  .ts .m2ts .mov .wmv .mpg .mpeg .webm .flv`), it picks the one with the newest
  modification time — the file actively being written. This deliberately beats a
  largest-size heuristic: during an upgrade the old full file sits beside the new
  partial one, and "largest" would wrongly pick the old file.
- **`import% = file bytes / target`**, clamped to `[0, 100]` (the growing file
  can momentarily overshoot the target).
- **Off-host degrades to `—` (unknown), never crashes.** When the folder does
  not exist or cannot be read (arrtop running off the *arr host), or the import
  has not created the file yet, `progress` returns `nil` and the CLI shows `—` in
  the `IMPORT%` column. Non-importing rows show `—` there too.

## Runs on the *arr host (important)

The import bar reads the file the *arr is **writing**, so it must run where that
write is happening — **on the Sonarr/Radarr host**. Watching the same file over
NFS from another client only updates at the *writer's* flush cadence (coarse,
stepped) regardless of client cache settings; only the writing host's kernel
reports the growing size in real time. A lighter API-only mode (download bars +
import *state*, no copy %) can run anywhere.

## Configuration

arrtop reads a list of Sonarr/Radarr backends from a config file in **YAML or
JSON** (the same shape in both — see `config.example.yaml` /
`config.example.json`):

```yaml
backends:
  - name: sonarr
    type: sonarr          # sonarr | radarr (lowercase)
    url: http://localhost:8989
    api_key: YOUR_SONARR_API_KEY
  - name: radarr
    type: radarr
    url: http://localhost:7878
    api_key: YOUR_RADARR_API_KEY
```

The config path is resolved in this order:

1. `-c`/`--config <path>`
2. the `ARR_TOP_CONFIG` environment variable
3. the first of `./config.yaml`, `./config.yml`, `./config.json` that exists

If none resolves, arrtop prints an error and exits non-zero. The file extension
picks the parser (`.yaml`/`.yml` → YAML, `.json` → JSON; anything else tries
YAML then JSON). Every backend needs a non-blank `name`, `url`, `api_key`, and a
recognized `type` (`sonarr` or `radarr`); validation reports **all** problems at
once.

Logging currently goes to **stderr** at the **Info** level (so the future TUI
can own stdout). A configurable level lands in a later phase.

```sh
arrtop --version
arrtop --help
arrtop --config /etc/arrtop/config.yaml
```

## Build

The binary **must** be built with `-Dpreview_mt` (arrtop's fibers run across
threads), so always build through the Makefile:

```sh
make build        # → bin/arrtop  (debug, -Dpreview_mt)
make release      # optimized
make run ARGS=…   # build + run
make test         # crystal spec
make check lint   # format check + ameba
```

Requires Crystal `>= 1.20.2`. Dependencies are the public `sonarr` and `radarr`
shards.
