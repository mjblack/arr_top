require "log"

module ArrTop
  # Command-line entry point: resolves the config path, loads + validates the
  # config, sets up logging, builds a `Backend` per configured entry, then either
  # runs the live TUI (`TUI`) or prints a one-shot snapshot of the queue.
  #
  # The default is the TUI when stdout is a terminal; a piped/redirected stdout
  # (or `--once`/`-1`) falls back to the plain-text snapshot. The path resolution
  # and backend construction are factored into `config_path`/`build_backends` so
  # they can be unit-tested without touching the network or the process exit.
  module CLI
    # `Log` source for CLI-phase messages (config load, backend construction,
    # poll summary). Scoped like the other `arrtop.<area>` sources.
    Log = ::Log.for("arrtop.cli")

    # Environment variable naming the config file, consulted after `--config`
    # but before the current-directory default search.
    CONFIG_ENV = "ARR_TOP_CONFIG"

    # Config filenames searched (in order) in the current working directory when
    # neither `--config`/`-c` nor `ARR_TOP_CONFIG` is given.
    DEFAULT_CONFIG_FILES = ["config.yaml", "config.yml", "config.json"]

    # System-wide config paths searched (in order) after the current-directory
    # defaults. A local `./config.*` therefore overrides a system one. This is
    # where the native package (.deb/.rpm) directs operators to place their
    # config (copied from the shipped `config.yaml.example`).
    SYSTEM_CONFIG_FILES = [
      "/etc/arr_top/config.yaml",
      "/etc/arr_top/config.yml",
      "/etc/arr_top/config.json",
    ]

    # Flags that consume the following argument as their value. The argument
    # after one of these is that flag's value and must never be mistaken for
    # something else while scanning `argv`.
    VALUE_FLAGS = {"--config", "-c"}

    # Usage text for `-h`/`--help`.
    USAGE = <<-USAGE
      arrtop — a top-like view of the Sonarr/Radarr download + import queue.

      usage: arrtop [-c|--config <path>] [-1|--once] [-h|--help] [-v|--version]

        -c, --config <path>   path to the config file (YAML or JSON)
        -1, --once            print a one-shot snapshot and exit (no live view)
        -h, --help            show this help and exit
        -v, --version         show the version and exit

      With a terminal on stdout, arrtop runs a full-screen live view (a top-like
      TUI) that redraws on the `refresh` interval (config; default 2s) or the
      instant you press a key. Press `q` (or Ctrl-C) to quit; the view resizes
      with the terminal. When stdout is piped/redirected, or with --once, arrtop
      prints a single plain-text snapshot instead.

      Config is resolved in this order:
        1. -c/--config <path>
        2. $#{CONFIG_ENV}
        3. the first of ./config.yaml, ./config.yml, ./config.json that exists
        4. the first of /etc/arr_top/config.yaml, .yml, .json that exists

      Logs are written to stderr at the Info level.
      USAGE

    # Parses *argv*, loads + validates the config, polls every backend once and
    # prints a snapshot. Errors are written to STDERR and exit non-zero.
    def self.run(argv : Array(String)) : Nil
      if help?(argv)
        puts USAGE
        exit 0
      end

      if version?(argv)
        puts "arrtop #{ArrTop::VERSION}"
        exit 0
      end

      path = config_path(argv)
      if path.nil?
        STDERR.puts "no config file found — looked for ./config.yaml, ./config.yml, " \
                    "./config.json, then /etc/arr_top/config.{yaml,yml,json}; " \
                    "pass --config <path> or set #{CONFIG_ENV}"
        exit 1
      end

      config =
        begin
          Config.from_file(path).validate
        rescue ex : Config::Error
          STDERR.puts ex.message
          exit 1
        end

      ArrTop.setup_logging

      Log.debug { "loaded config from #{path} (#{config.backends.size} backends)" }

      backends = build_backends(config)
      poller = Poller.new(backends)

      # Live TUI when stdout is a terminal and --once was not given; otherwise a
      # one-shot snapshot (piped/redirected output, CI, or an explicit --once).
      if tui?(argv)
        TUI.new(poller, config.refresh_span).run
      else
        run_snapshot(poller)
      end
    end

    # Whether to run the interactive TUI: stdout is a terminal and `--once`/`-1`
    # was not passed.
    def self.tui?(argv : Array(String)) : Bool
      STDOUT.tty? && !once?(argv)
    end

    # Whether *argv* forces the one-shot snapshot via `--once`/`-1`.
    def self.once?(argv : Array(String)) : Bool
      argv.any? { |arg| arg == "--once" || arg == "-1" }
    end

    # Polls every backend once and prints the plain-text snapshot. Writes are
    # guarded against `IO::Error` (a closed stdout — e.g. `arrtop | head`) so the
    # process exits quietly instead of crashing on a broken pipe.
    private def self.run_snapshot(poller : Poller) : Nil
      rows = poller.rows
      Log.debug { "polled #{rows.size} rows" }

      poller.errors.each do |name, message|
        Log.error { "backend #{name.inspect} failed: #{message}" }
      end

      print_snapshot(rows)
    rescue IO::Error
      # stdout closed (broken pipe) — nothing more to say.
    end

    # The resolved config path, or `nil` when none is found. Precedence:
    # `-c`/`--config <path>` → `$ARR_TOP_CONFIG` (if non-blank) → the first
    # existing of the current-directory defaults → the first existing of the
    # `/etc/arr_top` system-wide defaults → `nil`. A local `./config.*` thus
    # overrides a system one.
    def self.config_path(argv : Array(String)) : String?
      if explicit = config_flag(argv)
        return explicit
      end

      if env = ENV[CONFIG_ENV]?.presence
        return env
      end

      default_config_candidates.find { |candidate| File.exists?(candidate) }
    end

    # The ordered list of config-file candidates tried when neither `--config`
    # nor `$ARR_TOP_CONFIG` selects a path: the current-directory defaults
    # first, then the `/etc/arr_top` system-wide fallbacks. Pure — it consults
    # no filesystem and no environment, so the search order is unit-testable.
    def self.default_config_candidates : Array(String)
      DEFAULT_CONFIG_FILES + SYSTEM_CONFIG_FILES
    end

    # The `--config`/`-c` value from *argv*, or `nil` when the flag is absent.
    # The argument after any value flag is skipped so it is never misread.
    def self.config_flag(argv : Array(String)) : String?
      i = 0
      while i < argv.size
        arg = argv[i]
        if arg == "--config" || arg == "-c"
          value = argv[i + 1]?
          return value unless value.nil?
        elsif VALUE_FLAGS.includes?(arg)
          i += 1 # skip this value flag's value
        end
        i += 1
      end
      nil
    end

    # Builds a concrete `Backend` for each configured entry: `sonarr` → a
    # `SonarrBackend`, `radarr` → a `RadarrBackend`. Order is preserved. A nil
    # type cannot occur post-validation but is skipped defensively.
    def self.build_backends(config : Config) : Array(Backend)
      backends = [] of Backend

      config.backends.each do |backend_config|
        backend =
          case backend_config.type
          when Config::BackendType::Sonarr
            SonarrBackend.new(backend_config.name, backend_config.url, backend_config.api_key)
          when Config::BackendType::Radarr
            RadarrBackend.new(backend_config.name, backend_config.url, backend_config.api_key)
          else
            Log.warn { "backend #{backend_config.name.inspect} has no recognized type, skipping" }
            next
          end

        Log.debug { "backend #{backend_config.name.inspect} (#{backend_config.type}) → #{backend_config.url}" }
        backends << backend
      end

      backends
    end

    # Whether *argv* requests help via `--help`/`-h`.
    def self.help?(argv : Array(String)) : Bool
      argv.any? { |arg| arg == "--help" || arg == "-h" }
    end

    # Whether *argv* requests the version via `--version`/`-v`.
    def self.version?(argv : Array(String)) : Bool
      argv.any? { |arg| arg == "--version" || arg == "-v" }
    end

    # Width the media (movie/series) name column is truncated to in the snapshot.
    MEDIA_WIDTH = 24

    # Width the torrent (release title) column is truncated to in the snapshot.
    TITLE_WIDTH = 40

    # Prints a plain, ANSI-free aligned table of *rows* in the same column order
    # as the TUI: media name, torrent (release title), status, download %, import
    # %. STATUS and IMPORT% come from the SAME per-episode reclassification the
    # TUI uses (`TUI.resolve_display`), so a season pack renders identically here:
    # already-copied episodes read `100.0%`, the one actively copying reads its
    # estimated %, and not-yet-started episodes show `pending` with `—`. The
    # IMPORT% cell is `—` for non-importing rows and for importing rows arrtop
    # cannot watch (off-host / destination file not yet created). Used for non-tty
    # output and `--once`.
    private def self.print_snapshot(rows : Array(QueueRow)) : Nil
      if rows.empty?
        puts "queue is empty"
        return
      end

      # One shared count map (download_id → episodes in the pack), same as the TUI.
      group_counts = TUI.download_group_counts(rows)

      printf("%-*s  %-*s  %-12s %6s %8s\n",
        MEDIA_WIDTH, "MEDIA", TITLE_WIDTH, "TORRENT", "STATUS", "DL%", "IMPORT%")
      rows.each do |row|
        state, progress = TUI.resolve_display(row, group_counts)
        printf(
          "%-*s  %-*s  %-12s %5.1f%% %8s\n",
          MEDIA_WIDTH, truncate(row.media_name || "—", MEDIA_WIDTH),
          TITLE_WIDTH, truncate(row.title || "", TITLE_WIDTH),
          Render::STATE_LABELS[state]? || "other",
          row.download_percent,
          import_cell(progress),
        )
      end
    end

    # The IMPORT% cell for a resolved display *progress*: the copy percentage
    # (e.g. `26.0%`, or `100.0%` for a finished season-pack episode), or `—` when
    # there is no progress to show (non-importing rows, pending episodes, and
    # importing rows arrtop cannot watch). Pure, so it's unit-testable.
    def self.import_cell(progress : ImportProgress?) : String
      progress ? "#{progress.percent.round(1)}%" : "—"
    end

    # Truncates *str* to *width* chars, using a trailing `…` when it overflows.
    # A non-positive *width* yields an empty string (a negative slice count would
    # otherwise raise).
    private def self.truncate(str : String, width : Int32) : String
      return "" if width <= 0
      return str if str.size <= width
      "#{str[0, width - 1]}…"
    end
  end
end
