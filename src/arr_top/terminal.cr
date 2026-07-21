# Reopens `LibC` to bind the one terminal ioctl the Crystal stdlib does not
# expose on this target: `TIOCGWINSZ` (query the terminal window size). Raw
# mode, no-echo, and cooked mode already come from `IO::FileDescriptor#raw!` /
# `#cooked!` in the stdlib, so only the winsize query is bound here.
lib LibC
  # `struct winsize` from <termios.h>: rows/cols in characters (pixels unused).
  struct Winsize
    ws_row : UShort
    ws_col : UShort
    ws_xpixel : UShort
    ws_ypixel : UShort
  end

  # `ioctl` request number for "get window size" on x86_64 Linux.
  TIOCGWINSZ = 0x5413

  # Variadic `ioctl(2)`; used only with `TIOCGWINSZ` and a `Winsize*`.
  fun ioctl(fd : Int, request : ULong, ...) : Int
end

module ArrTop
  # Low-level terminal control for the TUI: the alternate screen buffer, cursor
  # visibility, and raw/no-echo input — plus a **guaranteed** restore of the
  # terminal to its normal state on every exit path.
  #
  # The restore contract is the whole point of this class. A TUI that leaves the
  # terminal in raw mode with a hidden cursor is a hard bug, so `#restore` is
  # wired to run on: normal quit (the `ensure` in `TUI#run`), `SIGINT`/`SIGTERM`,
  # an uncaught exception (also the `ensure`), and process exit (`at_exit`). It
  # is **idempotent** — guarded by `@active` under a lock — so being called from
  # several of those paths at once is safe.
  class Terminal
    # Enter the alternate screen buffer (so the user's scrollback is preserved).
    ENTER_ALT = "\e[?1049h"
    # Leave the alternate screen buffer, restoring the prior screen contents.
    LEAVE_ALT = "\e[?1049l"
    # Hide the cursor while the TUI paints.
    HIDE_CURSOR = "\e[?25l"
    # Show the cursor again.
    SHOW_CURSOR = "\e[?25h"

    # Fallback size when the ioctl fails (no tty, redirected, or an error).
    FALLBACK = {rows: 24, cols: 80}

    def initialize(@input : IO::FileDescriptor = STDIN, @output : IO::FileDescriptor = STDOUT)
      @active = false
      @lock = Mutex.new
    end

    # The terminal size as `{rows, cols}`, read fresh via `TIOCGWINSZ` so a
    # resize is picked up on the next redraw without needing `SIGWINCH`. Any
    # failure (not a tty, ioctl error, zero dimensions) yields `{24, 80}`.
    def self.size(fd : Int32 = STDOUT.fd) : {rows: Int32, cols: Int32}
      ws = uninitialized LibC::Winsize
      ret = LibC.ioctl(fd, LibC::TIOCGWINSZ, pointerof(ws))
      if ret == 0 && ws.ws_row > 0 && ws.ws_col > 0
        {rows: ws.ws_row.to_i32, cols: ws.ws_col.to_i32}
      else
        FALLBACK
      end
    rescue
      FALLBACK
    end

    # Current terminal size (instance shortcut over the class method).
    def size : {rows: Int32, cols: Int32}
      Terminal.size(@output.fd)
    end

    # Enters the TUI display state: alternate screen, hidden cursor, and raw +
    # no-echo input so a single keypress (`q`) is delivered immediately. Installs
    # the `SIGINT`/`SIGTERM` traps and the `at_exit` backstop so `#restore` runs
    # no matter how the process ends. Raw mode is best-effort: if STDIN is not a
    # tty it is skipped (the caller only starts a TUI when STDOUT is a tty).
    def start : Nil
      @lock.synchronize do
        return if @active
        @active = true

        @output.print(ENTER_ALT)
        @output.print(HIDE_CURSOR)
        @output.flush

        begin
          @input.raw!
        rescue IO::Error
          # STDIN is not a terminal (piped) — leave it cooked; the reader fiber
          # simply blocks on whatever input arrives.
        end
      end

      # Restore on signals and at process exit. cfmakeraw disables ISIG, so a
      # keyboard Ctrl-C does not raise SIGINT (the TUI reads byte 3 instead);
      # these traps still catch an external `kill -INT`/`-TERM`.
      Signal::INT.trap { restore; exit 130 }
      Signal::TERM.trap { restore; exit 143 }
      at_exit { restore }
    end

    # Restores the terminal to its normal state: cooked input, cursor shown,
    # alternate screen left. Idempotent — safe to call from the run loop's
    # `ensure`, a signal trap, and `at_exit` all in one run.
    def restore : Nil
      @lock.synchronize do
        return unless @active
        @active = false

        begin
          @input.cooked!
        rescue IO::Error
        end

        @output.print(SHOW_CURSOR)
        @output.print(LEAVE_ALT)
        @output.flush
      end
    rescue
      # Never let restore itself raise on an exit path.
    end

    # Alias so callers can read `#stop` as the paired verb to `#start`.
    def stop : Nil
      restore
    end

    # Writes *frame* to the output in one go and flushes, minimizing flicker.
    def write(frame : String) : Nil
      @output.print(frame)
      @output.flush
    end

    # Reads a single byte from input (blocking), or `nil` at EOF. Under raw mode
    # each keypress returns immediately.
    def read_byte : UInt8?
      @input.read_byte
    end
  end
end
