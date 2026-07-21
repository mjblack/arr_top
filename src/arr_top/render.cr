module ArrTop
  # Pure, I/O-free rendering helpers for the TUI. Every function here takes plain
  # data and returns a `String`; nothing touches the terminal, the clock, or the
  # network, so the whole module is unit-testable offline. The `TUI` loop is the
  # only thing that turns these strings into terminal writes.
  module Render
    # Cells inside a progress bar's brackets, e.g. `[####----------------]`.
    BAR_WIDTH = 20

    # Width the state column is padded/truncated to (`ImportPending` is the
    # widest label at 13 chars).
    STATE_WIDTH = 13

    # Human-readable label per `State`, used in the header summary.
    STATE_LABELS = {
      State::Importing     => "importing",
      State::ImportPending => "pending",
      State::Downloading   => "downloading",
      State::Failed        => "failed",
      State::Queued        => "queued",
      State::Unknown       => "other",
    }

    # Byte-size unit ladder (base 1024).
    BYTE_UNITS = ["B", "KB", "MB", "GB", "TB", "PB"]

    # A `[####----]`-style bar filled to *percent* (clamped 0–100) with exactly
    # *width* cells between the brackets. `width <= 0` yields `[]`.
    def self.bar(percent : Float64, width : Int32) : String
      return "[]" if width <= 0
      pct = percent.clamp(0.0, 100.0)
      filled = (pct / 100.0 * width).round.to_i
      filled = 0 if filled < 0
      filled = width if filled > width
      String.build do |io|
        io << '['
        width.times { |i| io << (i < filled ? '#' : '-') }
        io << ']'
      end
    end

    # Formats a byte count like `9.43 GB` (base 1024). Whole bytes stay as
    # `512 B`; larger units get two decimals. Non-positive counts are `0 B`.
    def self.human_bytes(n : Int64) : String
      return "0 B" if n <= 0
      value = n.to_f
      idx = 0
      while value >= 1024 && idx < BYTE_UNITS.size - 1
        value /= 1024
        idx += 1
      end
      idx.zero? ? "#{n} B" : "%.2f %s" % {value, BYTE_UNITS[idx]}
    end

    # Formats a span like `1h20m` (hours+minutes), `5m3s` (minutes+seconds), or
    # `42s`. Non-positive spans are `0s`; anything past 99h caps at `99h+` so a
    # near-stalled import's ETA can't blow the column out to `27777777h46m`.
    def self.human_duration(span : Time::Span) : String
      total = span.total_seconds.to_i64
      return "0s" if total <= 0
      hours = total // 3600
      return "99h+" if hours > 99
      minutes = (total % 3600) // 60
      seconds = total % 60
      if hours > 0
        "#{hours}h#{minutes}m"
      elsif minutes > 0
        "#{minutes}m#{seconds}s"
      else
        "#{seconds}s"
      end
    end

    # Truncates *str* to at most *width* characters, ending with `…` when it
    # overflows. `width <= 0` yields an empty string.
    def self.truncate(str : String, width : Int32) : String
      return "" if width <= 0
      return str if str.size <= width
      "#{str[0, width - 1]}…"
    end

    # The app header: name plus a one-line summary of the queue counts, e.g.
    # `arrtop  3 importing · 12 pending · 1 downloading`. *counts* maps each
    # `State` to how many rows are in it; zero-count states are omitted. Fits
    # within *cols*.
    def self.header(cols : Int32, counts : Hash(State, Int32)) : String
      parts = [] of String
      STATE_LABELS.each do |state, label|
        n = counts[state]? || 0
        parts << "#{n} #{label}" if n > 0
      end
      summary = parts.empty? ? "idle" : parts.join(" · ")
      fit("arrtop  #{summary}", cols)
    end

    # One formatted queue line fitting *cols*, never wrapping: state, title
    # (truncated to the space left), a progress bar, the percentage, and an ETA.
    #
    # For an `Importing` row with a live `import` reading the **import** bar and
    # percent come from `import.percent` (the copy progress read off disk) and the
    # ETA is *eta* (the import-rate estimate); otherwise the **download** bar and
    # percent come from `row.download_percent` and the ETA is the API's
    # `timeleft` (or a countdown to `row.eta`).
    def self.render_row(row : QueueRow, import : ImportProgress?, eta : Time::Span?, cols : Int32) : String
      cols = 1 if cols < 1
      live = row.state == State::Importing ? import : nil
      importing = !live.nil?
      percent = live ? live.percent : row.download_percent

      state_col = fit(row.state.to_s, STATE_WIDTH).ljust(STATE_WIDTH)
      bar_str = bar(percent, BAR_WIDTH)
      pct_str = "%5.1f%%" % percent.clamp(0.0, 100.0)
      eta_str = eta_field(row, importing, eta)

      right = eta_str.empty? ? "#{bar_str} #{pct_str}" : "#{bar_str} #{pct_str} #{eta_str}"

      # Title takes whatever horizontal space is left after the fixed columns and
      # the two separating spaces.
      title_width = cols - state_col.size - right.size - 2
      line =
        if title_width > 0
          title = truncate(row.title || "", title_width)
          "#{state_col} #{title.ljust(title_width)} #{right}"
        else
          "#{state_col} #{right}"
        end

      fit(line, cols)
    end

    # The ETA cell for a row. Import rows use the injected rate estimate; download
    # rows use the API's `timeleft` string, falling back to a countdown to `eta`.
    # Empty when nothing useful is available.
    private def self.eta_field(row : QueueRow, importing : Bool, eta : Time::Span?) : String
      if importing
        eta ? "~#{human_duration(eta)}" : ""
      elsif (timeleft = row.timeleft) && !timeleft.blank?
        timeleft
      elsif finish = row.eta
        remaining = finish - Time.utc
        remaining > Time::Span.zero ? "~#{human_duration(remaining)}" : ""
      else
        ""
      end
    end

    # Hard-fits *str* into *width* visible cells (no ellipsis) — a safety net so a
    # composed line can never exceed the terminal width and wrap.
    private def self.fit(str : String, width : Int32) : String
      return "" if width <= 0
      str.size > width ? str[0, width] : str
    end
  end
end
