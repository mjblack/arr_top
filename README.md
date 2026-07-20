# arrtop

A `top`-style terminal UI for the **Sonarr/Radarr** download → import pipeline.
It shows the queue sorted by what's actively **importing**, with real progress
bars — including the one the *arr API can't give you: **import (copy) progress**.

> **Status: scaffold.** The build, dependency wiring, and Makefile are in place;
> the queue polling, TUI, and import disk-watch are the next work.

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
