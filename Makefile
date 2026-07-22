# arrtop — build/dev tasks.
#
# The binary MUST be built with -Dpreview_mt (multi-threaded runtime): arrtop
# polls the *arr API and watches import files concurrently, so its fibers run
# across threads. Always build via this Makefile so the flag is never forgotten.

CRYSTAL ?= crystal
BIN      = bin/arrtop
MAIN     = src/main.cr
CRFLAGS  = -Dpreview_mt

.PHONY: all build release run deps deps-dev test format check lint clean

all: build

## Install runtime shard dependencies only (no development deps like ameba).
## `--production` skips dev deps and uses the committed shard.lock as-is
## (frozen), so a plain build never rewrites the lockfile.
deps:
	shards install --production

## Install all shard dependencies, including development (ameba) — for linting.
deps-dev:
	shards install

## Debug build (bin/arrtop), multi-threaded runtime.
build: deps
	@mkdir -p $(dir $(BIN))
	$(CRYSTAL) build $(CRFLAGS) $(MAIN) -o $(BIN)

## Optimized release build.
release: deps
	@mkdir -p $(dir $(BIN))
	$(CRYSTAL) build $(CRFLAGS) --release $(MAIN) -o $(BIN)

## Build then run (pass args with: make run ARGS="...").
run: build
	$(BIN) $(ARGS)

## Run the spec suite.
test:
	$(CRYSTAL) spec

## Format the source in place.
format:
	$(CRYSTAL) tool format

## Verify formatting (CI).
check:
	$(CRYSTAL) tool format --check

## Lint with ameba (a development dependency, so pull dev deps).
lint: deps-dev
	bin/ameba

## Remove build artifacts.
clean:
	rm -f $(BIN)
