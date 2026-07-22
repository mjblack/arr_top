require "log"

module ArrTop
  # The full-screen, `top`-style live view: one line per queue row (download or
  # live import progress bar) under a header, redrawn continuously.
  #
  # Concurrency (needs `-Dpreview_mt`) — three fibers, so a slow/hung backend
  # never freezes the UI or the keyboard:
  # - **Poller fiber (producer):** loops `@poller.rows` → `@updates`, then
  #   `sleep @refresh`. The blocking HTTP call parks this fiber's thread while the
  #   UI keeps running on another; a stuck poll can't block quit.
  # - **Reader fiber:** turns raw keypresses into bytes on `@keys`; sends the
  #   `nil` EOF sentinel when stdin closes.
  # - **UI fiber (this one, consumer):** keeps a cached `rows` snapshot and
  #   `select`s over `@keys`, `@updates`, and a modest animate `timeout`. It only
  #   ever *reads* cached rows — it never polls — so key-mashing (an arrow key is
  #   3 raw bytes) can't hammer the *arr API.
  #
  # `q`/`Q`/Ctrl-C (or stdin EOF) quits. On quit the poller fiber is stopped
  # (`@stop` closed) so nothing leaks, and terminal restore is guaranteed by
  # `Terminal` — the `ensure` here plus signal traps and an `at_exit` backstop all
  # funnel to one idempotent `restore`. No `Channel::ClosedError` escapes: the
  # poller watches `@stop` with `receive?` (nil on close), and `@keys`/`@updates`
  # are never closed.
  class TUI
    Log = ::Log.for("arrtop.tui")

    # Cursor-home; each frame starts here so redraws overwrite in place.
    HOME = "\e[H"
    # Clear from the cursor to the end of the line (drops a prior longer line's
    # tail).
    CLEAR_EOL = "\e[K"
    # Clear from the cursor to the end of the screen (drops rows a shrunken frame
    # no longer uses).
    CLEAR_EOS = "\e[J"

    # How often the UI redraws the *cached* rows between polls, so live import
    # copy bars (read fresh off disk in `build_frame`) animate smoothly even while
    # the poller sleeps. This never polls the backends.
    ANIMATE_INTERVAL = 1.second

    def initialize(@poller : Poller, @refresh : Time::Span, @terminal : Terminal = Terminal.new,
                   @theme : Theme = Theme.detect(tty: STDOUT.tty?))
      @rates = ImportRateTracker.new
      # `nil` is the EOF sentinel the reader sends when stdin closes (so the loop
      # can quit without `close` making `receive` raise in the `select`).
      @keys = Channel(UInt8?).new(capacity: 16)
      # Fresh row snapshots from the poller fiber.
      @updates = Channel(Array(QueueRow)).new
      # Closed by the UI fiber on quit to stop the poller fiber (no leak).
      @stop = Channel(Nil).new
    end

    # Runs the TUI until the user quits (or stdin hits EOF). Seeds an empty
    # snapshot (drawn immediately — no blocking on the first poll), spawns the
    # producer/reader fibers, then consumes updates and keypresses. The `ensure`
    # stops the poller and restores the terminal on every exit.
    def run : Nil
      @terminal.start
      spawn_reader
      spawn_poller

      rows = [] of QueueRow
      @terminal.write(build_frame(rows, @terminal.size))

      loop do
        select
        when byte = @keys.receive
          break if quit?(byte)
          # Non-quit key: reflow the cached rows for a possible resize only.
          @terminal.write(build_frame(rows, @terminal.size))
        when new_rows = @updates.receive
          rows = new_rows
          @terminal.write(build_frame(rows, @terminal.size))
        when timeout(ANIMATE_INTERVAL)
          # Redraw cached rows so live import bars/ETAs advance between polls.
          @terminal.write(build_frame(rows, @terminal.size))
        end
      end
    ensure
      stop_poller
      @terminal.stop
    end

    # Poller fiber (producer): polls every backend, publishes the snapshot on
    # `@updates`, then waits `@refresh` — repeating until `@stop` is closed. Both
    # the publish and the wait race `@stop.receive?` so shutdown is prompt and a
    # consumer that has gone away can't wedge it. `@poller.rows` blocking parks
    # only this fiber's thread (`-Dpreview_mt`).
    #
    # Per-iteration-retry invariant: a poll that raises is caught INSIDE the
    # loop, logged visibly, and skipped — the fiber does NOT publish (keeping the
    # last good frame) but STILL runs the `@stop`-vs-`timeout` wait, so it retries
    # every backend on the next tick and never terminates on a poll error. The
    # outer `rescue` is only a last-resort backstop for a truly unexpected exit.
    private def spawn_poller : Nil
      spawn do
        loop do
          rows =
            begin
              @poller.rows
            rescue ex
              Log.warn { "poll failed; retrying in #{@refresh}: #{ex.message}" }
              nil
            end

          # Publish only a successful poll; a nil (failed) poll keeps the last
          # frame on screen. The send races `@stop.receive?` so quit is immediate.
          if rows
            select
            when @stop.receive?
              break
            when @updates.send(rows)
              # delivered
            end
          end

          # Always wait a tick (even after a failure) so a stuck backend is
          # retried next round and quit stays prompt.
          select
          when @stop.receive?
            break
          when timeout(@refresh)
            # next poll
          end
        end
      rescue ex
        Log.error { "poller fiber stopped unexpectedly: #{ex.message}" }
      end
    end

    # Signals the poller fiber to stop. Idempotent-safe under the single `ensure`
    # caller; a double close is swallowed so shutdown never raises.
    private def stop_poller : Nil
      @stop.close
    rescue Channel::ClosedError
    end

    # Reader fiber: blocks on raw input and forwards each byte to `@keys`. Under
    # raw mode every keypress returns immediately. At EOF it sends the `nil`
    # sentinel so `#run` exits cleanly instead of redrawing forever with no way
    # to quit from the keyboard (e.g. `arrtop < /dev/null` in a terminal).
    private def spawn_reader : Nil
      spawn do
        loop do
          byte = @terminal.read_byte
          if byte.nil?
            @keys.send(nil)
            break
          end
          @keys.send(byte)
        end
      rescue ex
        Log.debug { "key reader stopped: #{ex.message}" }
      end
    end

    # Whether *byte* means "quit": the stdin-EOF sentinel (`nil`), `q`, `Q`, or
    # Ctrl-C (ETX, byte 3 — delivered as input because raw mode disables the
    # SIGINT a cooked terminal would send). Pure, so it's unit-tested directly.
    def self.quit?(byte : UInt8?) : Bool
      byte.nil? || byte == 'q'.ord || byte == 'Q'.ord || byte == 3
    end

    # :ditto:
    def quit?(byte : UInt8?) : Bool
      TUI.quit?(byte)
    end

    # Builds the full frame string for *rows* at terminal *size*: a double-line
    # box (top border with the app title + queue summary + aggregated copy speed,
    # a column-header row, a divider, one data row per queue entry, and a bottom
    # border). The box width tracks *cols* and the whole frame is capped to the
    # terminal height, degrading by dropping the least-important chrome (divider,
    # then header labels) before it would overflow or wrap. Every line is cleared
    # to end-of-line and the frame ends with clear-to-end-of-screen to erase what
    # a previous, taller frame left behind.
    #
    # Lines are joined with `\r\n` (not `\n`): raw mode disables output
    # post-processing, so a bare `\n` would drop down without returning to
    # column 0.
    def build_frame(rows : Array(QueueRow), size : {rows: Int32, cols: Int32}) : String
      cols = {size[:cols], 4}.max
      interior = cols - 2
      max_lines = {size[:rows], 1}.max

      # One pass: read each row's live import progress once, then derive the
      # aggregate copy speed from it (a single sample per folder per frame).
      imports = rows.map { |row| import_progress(row) }
      speed = aggregate_speed(rows, imports)

      top = Render.top_border(cols, counts(rows), speed, @theme)
      bottom = Render.bottom_border(cols, @theme)
      header = Render.wrap(Render.header_row(@theme, interior), cols, @theme)
      divider = Render.divider(cols, @theme)
      content = content_lines(rows, imports, cols, interior)

      frame_string(layout(max_lines, top, header, divider, content, bottom))
    end

    # The wrapped content lines: backend-error lines first, then either an
    # empty-queue message or one data row per queue entry. Each is exactly *cols*
    # wide (interior padded to *interior*, wrapped in the side borders).
    private def content_lines(rows : Array(QueueRow), imports : Array(ImportProgress?),
                              cols : Int32, interior : Int32) : Array(String)
      lines = [] of String
      @poller.errors.each do |name, message|
        lines << Render.wrap(error_content(name, message, interior), cols, @theme)
      end

      if rows.empty?
        empty = Render.truncate("queue empty — waiting for downloads…", interior).ljust(interior)
        lines << Render.wrap(empty, cols, @theme)
      else
        rows.each_with_index do |row, i|
          lines << Render.wrap(Render.render_row(row, imports[i], @theme, interior), cols, @theme)
        end
      end
      lines
    end

    # The aggregated import copy speed across watchable importing rows, e.g.
    # `Import Speed 45.20 MB/s`, or `""` when nothing measurable is copying. The
    # "Import Speed" label is explicit so it is not mistaken for the download
    # client's (e.g. qBittorrent) download rate. Calls `ImportRateTracker#measure`
    # once per folder (recording this frame's sample).
    private def aggregate_speed(rows : Array(QueueRow), imports : Array(ImportProgress?)) : String
      total = 0.0
      any = false
      rows.each_with_index do |row, i|
        ip = imports[i]
        next if ip.nil?
        folder = row.dest_folder
        next if folder.nil?
        if rate = @rates.measure(folder, ip)[:rate]
          total += rate
          any = true
        end
      end
      any ? "Import Speed #{Render.human_bytes(total.to_i64)}/s" : ""
    end

    # Fits [top, header, divider, *content, bottom] into *max_lines*, dropping the
    # divider then the header row (chrome) before it would drop data. Top/bottom
    # borders are kept whenever there is room for them.
    private def layout(max_lines : Int32, top : String, header : String,
                       divider : String, content : Array(String), bottom : String) : Array(String)
      return [top] if max_lines <= 1
      return [top, bottom] if max_lines == 2

      remaining = max_lines - 2 # rows available between the borders
      inner =
        if remaining <= content.size
          content.first(remaining) # no room for chrome — data only (truncated)
        else
          spare = remaining - content.size
          chrome = [] of String
          chrome << header if spare >= 1
          chrome << divider if spare >= 2
          chrome + content
        end

      [top] + inner + [bottom]
    end

    # Assembles the final frame: cursor-home, each line cleared to end-of-line
    # and joined with `\r\n`, then clear-to-end-of-screen.
    private def frame_string(lines : Array(String)) : String
      String.build do |io|
        io << HOME
        lines.each_with_index do |line, i|
          io << line << CLEAR_EOL
          io << "\r\n" if i < lines.size - 1
        end
        io << CLEAR_EOS
      end
    end

    # Live import (copy) progress for an `Importing` row that arrtop can watch on
    # disk, or `nil` for every other row and for an importing row it cannot watch
    # (off-host / destination file not yet created).
    private def import_progress(row : QueueRow) : ImportProgress?
      return nil unless row.state == State::Importing
      return nil if row.dest_folder.nil?
      ImportWatch.progress(row.dest_folder, row.import_target)
    end

    # A red, `⚠`-prefixed interior line surfacing a failed backend so an
    # unreachable *arr is visible, not silent. The text is fit to *interior* and
    # padded to it *before* colouring, so the ANSI codes never count toward the
    # visible width and the row still lines up under the right border.
    private def error_content(name : String, message : String, interior : Int32) : String
      text = Render.truncate("⚠ backend #{name.inspect}: #{message}", interior).ljust(interior)
      @theme.colorize(text, @theme.status_failed)
    end

    # Tallies *rows* by `State` for the header summary.
    private def counts(rows : Array(QueueRow)) : Hash(State, Int32)
      tally = Hash(State, Int32).new(0)
      rows.each { |row| tally[row.state] += 1 }
      tally
    end
  end
end
