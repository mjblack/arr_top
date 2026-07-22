module ArrTop
  # Pure, I/O-free rendering helpers for the TUI. Every function here takes plain
  # data (and, where colour is wanted, a `Theme`) and returns a `String`; nothing
  # touches the terminal, the clock, or the network, so the whole module is
  # unit-testable offline. The `TUI` loop is the only thing that turns these
  # strings into terminal writes.
  #
  # ALIGNMENT CONTRACT: every column/box helper lays out on **plain** text and
  # applies colour only after the visible width is fixed (see `Theme#colorize`,
  # which never changes visible width). So with a disabled theme each helper
  # returns a string whose `.size` is exactly the width it was asked for — the
  # property the specs assert to guarantee the right border lines up.
  module Render
    # Max cells inside a progress bar's brackets. The bar shrinks below this to
    # fit a narrow terminal; it never grows past it.
    BAR_WIDTH = 20

    # Visible width of the percent readout, e.g. `" 50.0%"` / `"100.0%"`.
    PCT_WIDTH = 6

    # Widest a whole progress cell (bar + space + percent) is allowed to get:
    # a full `BAR_WIDTH` bar (`+2` brackets) + a space + the percent.
    MAX_PROGRESS = BAR_WIDTH + 2 + 1 + PCT_WIDTH

    # Fixed column widths (visible cells). Movie/Torrent are hard limits — their
    # text is truncated to fit, never allowed to widen the layout.
    MOVIE_WIDTH   = 20
    TORRENT_WIDTH = 28
    STATUS_WIDTH  = 11 # widest label is "downloading" (11)

    # Double-line box-drawing pieces (U+2550–U+2563).
    BOX_TL = "╔"
    BOX_TR = "╗"
    BOX_BL = "╚"
    BOX_BR = "╝"
    BOX_H  = "═"
    BOX_V  = "║"
    BOX_ML = "╠"
    BOX_MR = "╣"

    # Column header labels.
    HEADER_LABELS = {movie: "MEDIA", torrent: "TORRENT", status: "STATUS", progress: "PROGRESS"}

    # Human-readable status label per `State` (also used in the queue summary).
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

    # A bracketed two-tone block bar filled to *percent* (clamped 0–100) with
    # exactly *width* cells between the brackets: `[` + filled cells + remaining
    # cells + `]`. Both cell glyphs come from the *theme* (both default to `█`),
    # so the bar is a solid run distinguished only by colour — filled in the
    # theme's filled colour, the remainder in its remaining colour, the brackets
    # in the bracket colour. Filled count = round(pct/100 · width), clamped to
    # `[0, width]`. With a disabled theme the glyphs are emitted bare, so the
    # visible width is always `width + 2`. `width <= 0` yields `[]`.
    def self.bar(percent : Float64, width : Int32, theme : Theme = Theme.disabled) : String
      return theme.colorize("[]", theme.brackets) if width <= 0
      pct = percent.clamp(0.0, 100.0)
      filled = (pct / 100.0 * width).round.to_i
      filled = 0 if filled < 0
      filled = width if filled > width
      remaining = width - filled

      String.build do |io|
        io << theme.colorize("[", theme.brackets)
        io << theme.colorize(theme.bar_filled_glyph * filled, theme.bar_filled) if filled > 0
        io << theme.colorize(theme.bar_empty_glyph * remaining, theme.bar_remaining) if remaining > 0
        io << theme.colorize("]", theme.brackets)
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

    # Formats a span like `1h20m`, `5m3s`, or `42s`. Non-positive spans are `0s`;
    # anything past 99h caps at `99h+`.
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

    # One-line summary of the queue counts, e.g. `3 importing · 1 downloading`,
    # or `idle` when every count is zero. Zero-count states are omitted.
    def self.summary_text(counts : Hash(State, Int32)) : String
      parts = [] of String
      STATE_LABELS.each do |state, label|
        n = counts[state]? || 0
        parts << "#{n} #{label}" if n > 0
      end
      parts.empty? ? "idle" : parts.join(" · ")
    end

    # Column widths `{movie, torrent, status, progress}` for a content row of
    # *width* visible cells. Columns are placed left-to-right at their fixed
    # widths with one-space gaps; when the row is too narrow the rightmost
    # columns shrink and then drop (width 0) rather than wrap. `progress` takes
    # whatever remains, capped at `MAX_PROGRESS`.
    def self.plan_columns(width : Int32) : {Int32, Int32, Int32, Int32}
      width = 0 if width < 0
      gap = 1

      movie = {MOVIE_WIDTH, width}.min
      rem = width - movie

      torrent = 0
      if rem > gap
        torrent = {TORRENT_WIDTH, rem - gap}.min
        rem -= gap + torrent
      end

      status = 0
      if rem > gap
        status = {STATUS_WIDTH, rem - gap}.min
        rem -= gap + status
      end

      progress = 0
      progress = {MAX_PROGRESS, rem - gap}.min if rem > gap

      {movie, torrent, status, progress}
    end

    # One data row laid out into *width* visible cells: Movie · Torrent · Status ·
    # Progress. Movie is `media_name` (`—` when nil), Torrent is the release
    # `title`; both are truncated to their fixed widths. Status is the coloured
    # state label. Progress is a bar+percent — **only** for `Downloading` (from
    # `download_percent`) and `Importing` (from *import*'s copy percent) rows;
    # every other state (incl. `ImportPending`) leaves the progress cell blank.
    # The returned string is exactly *width* visible cells wide.
    #
    # *display_state* is the effective state to render (label + progress); it can
    # differ from `row.state` when the TUI reclassifies a Sonarr season-pack row
    # (e.g. an "importing" episode with no file yet is displayed as pending). It
    # defaults to `row.state` so callers that don't reclassify are unaffected.
    def self.render_row(row : QueueRow, import : ImportProgress?, theme : Theme, width : Int32,
                        display_state : State = row.state) : String
      width = 0 if width < 0
      widths = plan_columns(width)
      m, t, s, p = widths
      cells = {
        movie_cell(row, m),
        torrent_cell(row, t),
        status_cell(row, display_state, theme, s),
        progress_cell(row, display_state, import, theme, p),
      }
      assemble(width, widths, cells)
    end

    # The column-header label row, aligned to the same columns as `render_row`,
    # exactly *width* visible cells wide.
    def self.header_row(theme : Theme, width : Int32) : String
      width = 0 if width < 0
      widths = plan_columns(width)
      m, t, s, p = widths
      cells = {
        label_cell(HEADER_LABELS[:movie], m, theme),
        label_cell(HEADER_LABELS[:torrent], t, theme),
        label_cell(HEADER_LABELS[:status], s, theme),
        label_cell(HEADER_LABELS[:progress], p, theme),
      }
      assemble(width, widths, cells)
    end

    # The top border: `╔ … ╗` filled with `═`, embedding the app title, the
    # queue-counts summary, and (when non-blank) the aggregated transfer *speed*
    # at the right. Exactly *cols* visible cells wide. Degrades by dropping the
    # speed, then truncating the summary, and finally to a plain rule when the
    # terminal is too narrow for any text.
    def self.top_border(cols : Int32, counts : Hash(State, Int32), speed : String, theme : Theme) : String
      interior = cols - 2
      return rule_line(BOX_TL, BOX_TR, cols, theme) if interior < 12

      summary = summary_text(counts)
      right_text = speed
      # Fixed left cells: "═ arrtop" (8) + "  " (2) + trailing " " (1) = 11.
      # Right block, when shown, is "<speed> ═" = speed.size + 2.
      right_cells = right_text.empty? ? 0 : right_text.size + 2
      budget = interior - 11 - right_cells
      if budget < 1
        right_text = "" # not enough room for the speed readout — drop it
        budget = interior - 11
      end

      summary = truncate(summary, {budget - 1, 0}.max)
      fill = budget - summary.size # >= 1

      String.build do |io|
        io << theme.colorize(BOX_TL, theme.border)
        io << theme.colorize("#{BOX_H} ", theme.border)
        io << theme.colorize("arrtop", theme.title)
        io << "  "
        io << summary
        io << " "
        io << theme.colorize(BOX_H * fill, theme.border)
        unless right_text.empty?
          io << theme.colorize(right_text, theme.speed)
          io << theme.colorize(" #{BOX_H}", theme.border)
        end
        io << theme.colorize(BOX_TR, theme.border)
      end
    end

    # The `╠═…═╣` divider between the header labels and the data rows, *cols* wide.
    def self.divider(cols : Int32, theme : Theme) : String
      rule_line(BOX_ML, BOX_MR, cols, theme)
    end

    # The `╚═…═╝` bottom border, *cols* wide.
    def self.bottom_border(cols : Int32, theme : Theme) : String
      rule_line(BOX_BL, BOX_BR, cols, theme)
    end

    # Wraps interior *content* (already exactly `cols - 2` visible cells) in the
    # left/right `║` borders, producing a *cols*-wide line.
    def self.wrap(content : String, cols : Int32, theme : Theme) : String
      border = theme.colorize(BOX_V, theme.border)
      "#{border}#{content}#{border}"
    end

    # A horizontal rule with the given corner/junction pieces, *cols* wide.
    private def self.rule_line(left : String, right : String, cols : Int32, theme : Theme) : String
      return theme.colorize(BOX_H * {cols, 0}.max, theme.border) if cols < 2
      theme.colorize("#{left}#{BOX_H * (cols - 2)}#{right}", theme.border)
    end

    # Joins the four already-coloured, already-width-`w` cells with one-space
    # gaps (only between present columns) and right-pads to exactly *width*.
    private def self.assemble(width : Int32, widths : {Int32, Int32, Int32, Int32}, cells : {String, String, String, String}) : String
      m, t, s, p = widths
      cm, ct, cs, cp = cells
      String.build do |io|
        used = 0
        if m > 0
          io << cm
          used += m
        end
        if t > 0
          io << ' ' << ct
          used += 1 + t
        end
        if s > 0
          io << ' ' << cs
          used += 1 + s
        end
        if p > 0
          io << ' ' << cp
          used += 1 + p
        end
        io << " " * (width - used) if used < width
      end
    end

    # The Movie cell: `media_name` (or `—` when nil/blank), truncated + left-
    # padded to *w*. Plain (uncoloured).
    private def self.movie_cell(row : QueueRow, w : Int32) : String
      return "" if w <= 0
      name = row.media_name
      text = (name && !name.empty?) ? name : "—"
      truncate(text, w).ljust(w)
    end

    # The Torrent cell: the release `title`, truncated + left-padded to *w*.
    private def self.torrent_cell(row : QueueRow, w : Int32) : String
      return "" if w <= 0
      truncate(row.title || "", w).ljust(w)
    end

    # The Status cell: the human state label, padded to *w* then coloured per the
    # theme (warning/error/`Failed` → red; else per state). *state* is the
    # effective display state (may be a reclassified `row.state`).
    private def self.status_cell(row : QueueRow, state : State, theme : Theme, w : Int32) : String
      return "" if w <= 0
      label = STATE_LABELS[state]? || "other"
      theme.colorize(truncate(label, w).ljust(w), theme.status_code(row, state))
    end

    # A bold column-label cell padded to *w*.
    private def self.label_cell(text : String, w : Int32, theme : Theme) : String
      return "" if w <= 0
      theme.colorize(truncate(text, w).ljust(w), theme.header_label)
    end

    # The Progress cell: a coloured bar + percent for `Downloading`/`Importing`,
    # or blank spaces otherwise (and when a bar can't meaningfully fit *w*).
    # *state* is the effective display state. Exactly *w* visible cells wide.
    private def self.progress_cell(row : QueueRow, state : State, import : ImportProgress?, theme : Theme, w : Int32) : String
      return "" if w <= 0
      percent = progress_percent(row, state, import)
      return " " * w if percent.nil?

      bar_cells = w - PCT_WIDTH - 3 # brackets (2) + gap (1) + percent
      bar_cells = BAR_WIDTH if bar_cells > BAR_WIDTH
      return " " * w if bar_cells < 1

      bar_str = bar(percent, bar_cells, theme)
      pct_str = "%5.1f%%" % percent.clamp(0.0, 100.0)
      visible = bar_cells + 2 + 1 + PCT_WIDTH
      content = "#{bar_str} #{pct_str}"
      visible < w ? content + " " * (w - visible) : content
    end

    # The percentage a row's progress cell should show, or `nil` when it should
    # be blank. `Importing` reads the on-disk copy percent (nil when unwatchable);
    # `Downloading` reads `download_percent`; every other state (incl.
    # `ImportPending`) is blank. Keys off the effective *state*.
    private def self.progress_percent(row : QueueRow, state : State, import : ImportProgress?) : Float64?
      case state
      when State::Importing
        import.try(&.percent)
      when State::Downloading
        row.download_percent
      else
        nil
      end
    end
  end
end
