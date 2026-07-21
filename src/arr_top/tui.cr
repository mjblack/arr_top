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

    def initialize(@poller : Poller, @refresh : Time::Span, @terminal : Terminal = Terminal.new)
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
    # `@updates`, then sleeps `@refresh` — repeating until `@stop` is closed. Both
    # the publish and the sleep race `@stop.receive?` so shutdown is prompt and a
    # consumer that has gone away can't wedge it. `@poller.rows` blocking parks
    # only this fiber's thread (`-Dpreview_mt`).
    private def spawn_poller : Nil
      spawn do
        loop do
          rows = @poller.rows

          select
          when @stop.receive?
            break
          when @updates.send(rows)
            # delivered
          end

          select
          when @stop.receive?
            break
          when timeout(@refresh)
            # next poll
          end
        end
      rescue ex
        Log.debug { "poller fiber stopped: #{ex.message}" }
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

    # Builds the full frame string for *rows* at terminal *size*: cursor-home,
    # then header + optional error lines + one row per queue entry (capped to the
    # terminal height), each cleared to end-of-line, then a clear-to-end-of-screen
    # to erase any rows a previous, taller frame left behind.
    #
    # Lines are joined with `\r\n` (not `\n`): raw mode disables output
    # post-processing, so a bare `\n` would drop down without returning to
    # column 0.
    def build_frame(rows : Array(QueueRow), size : {rows: Int32, cols: Int32}) : String
      cols = size[:cols]
      max_lines = {size[:rows], 1}.max

      lines = [] of String
      lines << Render.header(cols, counts(rows))

      @poller.errors.each do |name, message|
        break if lines.size >= max_lines
        lines << error_line(name, message, cols)
      end

      if rows.empty?
        lines << "" if lines.size < max_lines
        lines << Render.truncate("queue empty — waiting for downloads…", cols) if lines.size < max_lines
      else
        rows.each do |row|
          break if lines.size >= max_lines
          import = import_progress(row)
          eta = nil
          if import && (folder = row.dest_folder)
            eta = @rates.eta(folder, import)
          end
          lines << Render.render_row(row, import, eta, cols)
        end
      end

      lines = lines[0, max_lines] if lines.size > max_lines

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

    # A red, `⚠`-prefixed line surfacing a failed backend so an unreachable *arr
    # is visible, not silent. The text is fit to *cols* before coloring so the
    # ANSI codes never count toward the visible width.
    private def error_line(name : String, message : String, cols : Int32) : String
      text = Render.truncate("⚠ backend #{name.inspect}: #{message}", cols)
      "\e[31m#{text}\e[0m"
    end

    # Tallies *rows* by `State` for the header summary.
    private def counts(rows : Array(QueueRow)) : Hash(State, Int32)
      tally = Hash(State, Int32).new(0)
      rows.each { |row| tally[row.state] += 1 }
      tally
    end
  end
end
