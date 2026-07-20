require "log"

module ArrTop
  # Collects normalized `QueueRow`s from every configured backend and returns
  # them sorted so what's actively importing sorts first.
  #
  # A backend that raises (unreachable *arr, API error) is **skipped** rather
  # than blanking the whole view — its rows are omitted and its name/message are
  # recorded in `#errors` for a future UI to surface. `#rows` recomputes
  # `#errors` on each call.
  class Poller
    # `Log` source for poll-loop messages.
    Log = ::Log.for("arrtop.poller")

    # Backend name → error message for backends that failed on the last `#rows`.
    getter errors : Hash(String, String)

    def initialize(@backends : Array(Backend))
      @errors = {} of String => String
    end

    # Rows from every backend, sorted by `State` rank (Importing first), then by
    # descending download percent, then title. Failed backends are skipped and
    # recorded in `#errors`.
    def rows : Array(QueueRow)
      @errors.clear
      collected = [] of QueueRow

      @backends.each do |backend|
        backend_rows = backend.rows
        Log.debug { "backend #{backend.name.inspect} returned #{backend_rows.size} rows" }
        collected.concat(backend_rows)
      rescue ex
        message = ex.message || ex.class.name
        Log.debug { "backend #{backend.name.inspect} failed: #{message}" }
        @errors[backend.name] = message
      end

      Poller.sort(collected)
    end

    # Stable sort: `State` rank (Importing = 0 first), then descending
    # download percent, then title.
    def self.sort(rows : Array(QueueRow)) : Array(QueueRow)
      rows.sort_by { |row| {row.state.rank, -row.download_percent, row.title || ""} }
    end
  end
end
