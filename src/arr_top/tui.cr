require "log"

module ArrTop
  # The full-screen, `top`-style live view. Polls the `Poller` on an interval,
  # draws one line per queue row (with download or live import progress bars) and
  # a header, and redraws every `@refresh` — or immediately when a key is pressed.
  #
  # Concurrency (needs `-Dpreview_mt`): a reader fiber turns raw keypresses into
  # bytes on a channel; the main loop `select`s over that channel and a
  # `timeout(@refresh)`, so it wakes the instant a key arrives yet still refreshes
  # on schedule. `q`/`Q`/Ctrl-C quits.
  #
  # Terminal restore is guaranteed by `Terminal` (see there): the `ensure` below
  # plus signal traps and an `at_exit` backstop all funnel to one idempotent
  # `restore`, so no exit path leaves the terminal in raw mode.
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

    def initialize(@poller : Poller, @refresh : Time::Span, @terminal : Terminal = Terminal.new)
      @rates = ImportRateTracker.new
      @keys = Channel(UInt8).new(capacity: 16)
    end

    # Runs the TUI until the user quits. Starts the terminal, spawns the key
    # reader, and loops poll → draw → wait. The `ensure` restores the terminal on
    # every exit (normal, exception, quit).
    def run : Nil
      @terminal.start
      spawn_reader

      loop do
        frame = build_frame(@poller.rows, @terminal.size)
        @terminal.write(frame)
        break if wait_for_key
      end
    ensure
      @terminal.stop
    end

    # Reader fiber: blocks on raw input and forwards each byte to `@keys`. Under
    # raw mode every keypress returns immediately; at EOF the fiber ends.
    private def spawn_reader : Nil
      spawn do
        loop do
          byte = @terminal.read_byte
          break if byte.nil?
          @keys.send(byte)
        end
      rescue ex
        Log.debug { "key reader stopped: #{ex.message}" }
      end
    end

    # Waits up to `@refresh` for a keypress. Returns `true` when a quit key
    # (`q`/`Q`/Ctrl-C) was pressed, `false` on any other key or on timeout (both
    # just trigger the next redraw).
    private def wait_for_key : Bool
      select
      when byte = @keys.receive
        quit_key?(byte)
      when timeout(@refresh)
        false
      end
    end

    # Whether *byte* is a quit key: `q`, `Q`, or Ctrl-C (ETX, byte 3 — delivered
    # as input because raw mode disables the SIGINT that a cooked terminal sends).
    private def quit_key?(byte : UInt8) : Bool
      byte == 'q'.ord || byte == 'Q'.ord || byte == 3
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
