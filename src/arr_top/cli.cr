require "log"

module ArrTop
  # Command-line entry point: resolves the config path, loads + validates the
  # config, sets up logging, builds a `Backend` per configured entry, polls them
  # once, and prints a plain-text snapshot of the queue.
  #
  # The snapshot print is a placeholder for the TUI phase. The path resolution
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

    # Flags that consume the following argument as their value. The argument
    # after one of these is that flag's value and must never be mistaken for
    # something else while scanning `argv`.
    VALUE_FLAGS = {"--config", "-c"}

    # Usage text for `-h`/`--help`.
    USAGE = <<-USAGE
      arrtop — a top-like view of the Sonarr/Radarr download + import queue.

      usage: arrtop [-c|--config <path>] [-h|--help] [-v|--version]

        -c, --config <path>   path to the config file (YAML or JSON)
        -h, --help            show this help and exit
        -v, --version         show the version and exit

      Config is resolved in this order:
        1. -c/--config <path>
        2. $#{CONFIG_ENV}
        3. the first of ./config.yaml, ./config.yml, ./config.json that exists

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
                    "./config.json; pass --config <path> or set #{CONFIG_ENV}"
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
      rows = poller.rows
      Log.debug { "polled #{backends.size} backends, #{rows.size} rows" }

      poller.errors.each do |name, message|
        Log.error { "backend #{name.inspect} failed: #{message}" }
      end

      print_snapshot(rows)
    end

    # The resolved config path, or `nil` when none is found. Precedence:
    # `-c`/`--config <path>` → `$ARR_TOP_CONFIG` (if non-blank) → the first
    # existing of `DEFAULT_CONFIG_FILES` in the CWD → `nil`.
    def self.config_path(argv : Array(String)) : String?
      if explicit = config_flag(argv)
        return explicit
      end

      if env = ENV[CONFIG_ENV]?.presence
        return env
      end

      DEFAULT_CONFIG_FILES.find { |candidate| File.exists?(candidate) }
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

    # Width the title column is truncated to in the snapshot table.
    TITLE_WIDTH = 50

    # Prints a plain aligned table of *rows*: state, download %, title, dest.
    # Placeholder output until the TUI phase.
    private def self.print_snapshot(rows : Array(QueueRow)) : Nil
      if rows.empty?
        puts "queue is empty"
        return
      end

      printf("%-14s %6s  %-*s  %s\n", "STATE", "DL%", TITLE_WIDTH, "TITLE", "DEST")
      rows.each do |row|
        printf(
          "%-14s %5.1f%%  %-*s  %s\n",
          row.state.to_s,
          row.download_percent,
          TITLE_WIDTH,
          truncate(row.title || "", TITLE_WIDTH),
          row.dest_folder || "",
        )
      end
    end

    # Truncates *str* to *width* chars, using a trailing `…` when it overflows.
    private def self.truncate(str : String, width : Int32) : String
      return str if str.size <= width
      return str[0, width] if width < 1
      "#{str[0, width - 1]}…"
    end
  end
end
