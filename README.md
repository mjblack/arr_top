# arrtop

A `top`-style terminal UI for the **Sonarr/Radarr** download → import pipeline.
It shows the queue sorted by what's actively **importing**, with real progress
bars — including the one the *arr API can't give you: **import (copy) progress**.

> **Status: usable.** The data layer (typed queue poller), config + CLI,
> logging, the **import disk-watch**, and the **full-screen live TUI** are in
> place. On a terminal `arrtop` runs the live view; piped/redirected (or with
> `--once`) it prints a one-shot snapshot with a live `IMPORT%` column.

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
refresh: 2s                 # TUI redraw interval; optional (default 2s)
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

`refresh` accepts `<int>s`, `<int>ms`, or a bare integer (seconds); it sets how
often the live view redraws (it also wakes instantly on a keypress).

### Exact per-episode sizes (optional download client)

A Sonarr **season pack** reports only the *whole-pack* total on every episode
row — there is no per-episode size in the *arr API — so arrtop estimates each
episode as `pack_total / episode_count`. If you also point arrtop at the
download client, it asks the client for the torrent's file list and uses the
**real** size of each episode's file as the import target instead (exact SIZE
column, progress-bar denominator, prune threshold, and aggregate).

This is entirely **optional**: omit the `download_clients` block and behaviour is
identical to before (the estimate, zero download-client calls). Only qBittorrent
is supported for now.

```yaml
download_clients:
  - name: qbit                    # MUST match the download-client name the *arr reports
    type: qbittorrent             # qbittorrent (lowercase); only client for now
    url: http://localhost:8080    # qBittorrent Web UI URL
    username: admin
    password: YOUR_QBITTORRENT_PASSWORD
```

A queue row is matched to a client by the row's **download-client name**, so the
`name` here must equal the download-client name Sonarr shows for that download.
The lookup is non-blocking (the background poller fetches each torrent's file
list once and caches it; the render only reads the cache) and fully fault-
tolerant: an unreachable client, a torrent not found, or a non-torrent (NZB)
download simply falls back to the estimate — no crash, no UI stall. Each client
needs a non-blank `name`, `url`, `username`, `password`, and a recognized `type`
(`qbittorrent`).

The config path is resolved in this order:

1. `-c`/`--config <path>`
2. the `ARR_TOP_CONFIG` environment variable
3. the first of `./config.yaml`, `./config.yml`, `./config.json` that exists
4. the first of `/etc/arr_top/config.yaml`, `/etc/arr_top/config.yml`,
   `/etc/arr_top/config.json` that exists

A local `./config.*` therefore overrides a system-wide one. The `.deb`/`.rpm`
packages ship `/etc/arr_top/config.yaml.example`; copy it to
`/etc/arr_top/config.yaml` (drop the `.example`) to use the system-wide
location. If none resolves, arrtop prints an error and exits non-zero. The file extension
picks the parser (`.yaml`/`.yml` → YAML, `.json` → JSON; anything else tries
YAML then JSON). Every backend needs a non-blank `name`, `url`, `api_key`, and a
recognized `type` (`sonarr` or `radarr`); validation reports **all** problems at
once.

Logging goes to **stderr** at the **Info** level (so the TUI can own stdout). A
configurable level lands in a later phase.

```sh
arrtop --version
arrtop --help
arrtop --config /etc/arrtop/config.yaml
arrtop --once                 # one-shot snapshot, skip the live view
```

## The live view (TUI)

Run `arrtop` on a terminal and it opens a full-screen, `top`-style live view:
one line per queue item — state, title, a progress bar (the live **import** copy
bar for importing rows, the **download** bar otherwise), the percentage, and an
ETA — under a header summarizing the counts. An unreachable *arr shows as a red
`⚠` line rather than silently vanishing.

- **Keys:** `q` (or `Q`, or `Ctrl-C`) quits.
- **Refresh:** redraws every `refresh` (config; default 2s), and instantly on any
  keypress.
- **Auto-resize:** the layout follows the terminal size on each redraw (no
  `SIGWINCH` needed).
- **Terminal-safe:** the terminal is always restored — alt screen left, cursor
  shown, cooked mode — on quit, `SIGINT`/`SIGTERM`, an uncaught exception, and at
  process exit. It never leaves your terminal in raw mode.

**Snapshot fallback.** When stdout is **not** a terminal (piped or redirected —
e.g. CI, `arrtop > out.txt`, `arrtop | head`), or when you pass `--once`/`-1`,
arrtop prints a single plain-text table instead of entering the TUI. Snapshot
output tolerates a closed pipe, so `arrtop | head` exits quietly.

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
