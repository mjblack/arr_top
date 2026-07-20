# arrtop

A `top`-style terminal UI for the **Sonarr/Radarr** download → import pipeline.
It shows the queue sorted by what's actively **importing**, with real progress
bars — including the one the *arr API can't give you: **import (copy) progress**.

> **Status: early.** The data layer (typed queue poller), config + CLI, and
> logging are in place; a plain snapshot of the queue prints to stdout. The TUI
> and import disk-watch are the next work.

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
