require "log"

module ArrTop
  # Configures Crystal's `Log` for arrtop. Logs go to **STDERR** so the future
  # TUI can own STDOUT for its rendering.
  #
  # The level is pinned to `Info` for now — the CLI calls this with the default.
  # Making the level configurable (via a CLI flag, an env var, or the config
  # file) is deferred to a later phase; the `level` parameter already threads
  # through so that wiring is a small change when it lands.
  def self.setup_logging(level : ::Log::Severity = ::Log::Severity::Info,
                         io : IO = STDERR) : Nil
    backend = ::Log::IOBackend.new(io, dispatcher: ::Log::DispatchMode::Sync)
    ::Log.setup(level, backend)
  end
end
