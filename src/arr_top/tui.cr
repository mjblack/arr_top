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

      # One pass: read each row's live import progress once, reclassify it into an
      # effective display state (+ possibly synthesized progress), then derive the
      # aggregate copy speed from the effective progress (one sample per folder).
      #
      # A Sonarr season pack reports the *whole pack's* size on every episode row
      # (there is no per-episode size in the API), so split it across the pack's
      # episodes — the rows sharing this row's `download_id` — to get a realistic
      # per-episode target (see `TUI.effective_target`).
      #
      # Completed pack episodes are then *pruned* (see `prune_completed?`): a done
      # episode's copy has finished and Sonarr has moved on, so it drops out of the
      # view, leaving only the actively-copying episode and the pending ones. The
      # group counts stay computed over the FULL row set so the per-episode target
      # split is unaffected by pruning; only what's rendered (and the header
      # summary counts) reflects the surviving rows.
      group_counts = TUI.download_group_counts(rows)
      kept_rows = [] of QueueRow
      states = [] of State
      imports = [] of ImportProgress?
      rows.each do |row|
        state, import, prune = TUI.resolve_display(row, group_counts)
        next if prune
        kept_rows << row
        states << state
        imports << import
      end
      sizes = kept_rows.map { |row| TUI.effective_target(row, group_counts) }
      disks = kept_rows.map_with_index { |row, i| TUI.disk_bytes(row, states[i], imports[i], sizes[i]) }
      speed = aggregate_speed(imports)

      top = Render.top_border(cols, counts(states), speed, @theme)
      bottom = Render.bottom_border(cols, @theme)
      header = Render.wrap(Render.header_row(@theme, interior), cols, @theme)
      divider = Render.divider(cols, @theme)
      content = content_lines(kept_rows, states, imports, disks, sizes, cols, interior)

      frame_string(layout(max_lines, top, header, divider, content, bottom))
    end

    # The wrapped content lines: backend-error lines first, then either an
    # empty-queue message or one data row per queue entry. Each is exactly *cols*
    # wide (interior padded to *interior*, wrapped in the side borders).
    private def content_lines(rows : Array(QueueRow), states : Array(State),
                              imports : Array(ImportProgress?),
                              disks : Array(Int64?), sizes : Array(Int64),
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
          line = Render.render_row(row, imports[i], disks[i], sizes[i], @theme, interior, states[i])
          lines << Render.wrap(line, cols, @theme)
        end
      end
      lines
    end

    # The aggregated import copy speed across watchable importing rows, e.g.
    # `Import Speed 45.20 MB/s`, or `""` when nothing measurable is copying. The
    # "Import Speed" label is explicit so it is not mistaken for the download
    # client's (e.g. qBittorrent) download rate. Calls `ImportRateTracker#measure`
    # once per copied **file** — keyed by `ImportProgress#file`, not the folder,
    # so a season pack's many episodes in one folder each get their own sample
    # history and a completed/other episode can't manufacture a bogus rate.
    private def aggregate_speed(imports : Array(ImportProgress?)) : String
      total = 0.0
      any = false
      imports.each do |ip|
        next if ip.nil?
        if rate = @rates.measure(ip.file, ip)[:rate]
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

    # The single source of truth for a row's effective display, shared by the live
    # TUI (`build_frame`) and the plain-text snapshot (`CLI.print_snapshot`) so the
    # two never disagree. Given a row and the queue's `download_id` → count map
    # (from `download_group_counts`), it chains the per-episode pipeline —
    # `effective_target` (split a season pack's total across its episodes) →
    # `watch_progress` (read this episode's file + whether it's the active copy) →
    # `display_state_and_progress` (reclassify done/active/pending) — and returns
    # `{State, ImportProgress?, prune}`: the effective state + progress to render,
    # plus whether this is a *completed* pack episode that should be **pruned**
    # from the view (see `prune_completed?`). Both the TUI (`build_frame`) and the
    # snapshot (`CLI.print_snapshot`) key off this single `prune` flag so the two
    # agree on what a season pack shows.
    def self.resolve_display(row : QueueRow,
                             group_counts : Hash(String, Int32)) : {State, ImportProgress?, Bool}
      target = effective_target(row, group_counts)
      on_disk, active = watch_progress(row, target)
      state, progress = display_state_and_progress(row, on_disk, active, target)
      {state, progress, prune_completed?(row, on_disk, active)}
    end

    # Whether *row* is a **completed** season-pack episode that should be dropped
    # from the view, so a pack shows only the actively-copying episode plus the
    # not-yet-started (pending) ones. Pure, so it's unit-tested directly.
    #
    # Keys off the *raw* on-disk watch (`on_disk`/`active` from `watch_progress`),
    # not the reclassified display state. Only a Sonarr **episode** row the *arr
    # still reports as `Importing` can prune; a row prunes when either:
    # - its file is present but is **not** the folder's active (newest-mtime) copy
    #   — its copy finished and Sonarr has moved on to the next episode — or
    # - `episode_has_file` is true (Sonarr already imported it; a filename-match
    #   fallback for when the on-disk file can't be located).
    # The actively-copying episode (present **and** active) is kept even when its
    # on-disk bytes overshoot the per-episode estimate; pending episodes (no file,
    # not yet imported), movies, and every non-importing row are kept.
    def self.prune_completed?(row : QueueRow, on_disk : ImportProgress?, active : Bool) : Bool
      return false unless row.media_kind == :episode && row.state == State::Importing
      (!on_disk.nil? && !active) || row.episode_has_file == true
    end

    # Live import (copy) progress for an `Importing` row that arrtop can watch on
    # disk, paired with whether the matched file is the folder's **active**
    # (newest-mtime) copy. Returns `{nil, false}` for every non-importing row and
    # for an importing row it cannot watch (off-host / file not yet created).
    #
    # *target* is the effective per-episode target (see `effective_target`), used
    # as the bar's denominator. Episode rows use the season/episode-aware watch so
    # each row watches THIS episode's file out of a season pack (and learns
    # whether it is the one being copied); movies use the folder-wide newest file.
    def self.watch_progress(row : QueueRow, target : Int64) : {ImportProgress?, Bool}
      return {nil, false} unless row.state == State::Importing
      folder = row.dest_folder
      return {nil, false} if folder.nil?

      season = row.season_number
      episode = row.episode_number
      if season && episode
        result = ImportWatch.episode_progress(folder, target, season, episode)
        result ? {result[0], result[1]} : {nil, false}
      else
        {ImportWatch.progress(folder, target), false}
      end
    end

    # Counts how many queue rows share each `download_id` (nil ids ignored). A
    # Sonarr season pack lists one row per episode, all sharing one download, so
    # this count is "episodes in the pack". Pure, so it's unit-testable.
    def self.download_group_counts(rows : Array(QueueRow)) : Hash(String, Int32)
      counts = Hash(String, Int32).new(0)
      rows.each do |row|
        id = row.download_id
        counts[id] += 1 if id
      end
      counts
    end

    # The effective per-episode import target for *row*. The Sonarr API reports the
    # *whole pack's* size on every episode row (no per-episode size), so for an
    # episode row that shares its `download_id` with others (a season pack of
    # count > 1) the target is estimated as `import_target // count`. Single-file
    # downloads and movies keep the reported `import_target`. Pure/unit-testable.
    def self.effective_target(row : QueueRow, group_counts : Hash(String, Int32)) : Int64
      return row.import_target unless row.media_kind == :episode
      id = row.download_id
      return row.import_target if id.nil?
      count = group_counts[id]? || 1
      count > 1 ? row.import_target // count : row.import_target
    end

    # The bytes currently on disk behind an *importing* row's copy — the numerator
    # of the SIZE column's `disk/total` pair — or `nil` for every other state (so
    # only rows displayed as `Importing` show the pair; the rest show just the
    # size). For an importing row it is the resolved copy *progress*'s real bytes,
    # which is `0` at the start of a copy and equal to *total* for a finished
    # episode (a nil *progress* ⇒ `0`). Pure/unit-testable. *row* and *total* are
    # unused for now but kept so callers pass the row's full context.
    def self.disk_bytes(row : QueueRow, state : State, progress : ImportProgress?, total : Int64) : Int64?
      return nil unless state == State::Importing
      progress.try(&.bytes) || 0_i64
    end

    # Pure reclassification: given a row, the import progress found on disk for it,
    # whether that file is the folder's **active** (newest-mtime) copy, and the
    # effective per-episode *target*, decide the effective display `State` and the
    # `ImportProgress?` to render.
    #
    # Only a Sonarr **episode** row the *arr reports as `Importing` is touched (a
    # season pack lists one importing row per episode, all sharing one folder; the
    # pack is copied one file at a time, so at most one episode's file is active):
    # - no matching file on disk ⇒ `ImportPending` (no bar), unless
    #   `episode_has_file` says Sonarr already imported it ⇒ Importing at 100%
    #   (a filename-match fallback);
    # - a matching file that is NOT the active/newest copy ⇒ a done episode ⇒
    #   Importing at 100% (synthesize `bytes == target`);
    # - a matching file that IS the active/newest copy ⇒ Importing with its real
    #   bar (`file_bytes / target`).
    # Movie rows and non-importing rows keep their real state and import.
    def self.display_state_and_progress(row : QueueRow, on_disk : ImportProgress?,
                                        active : Bool, target : Int64) : {State, ImportProgress?}
      return {row.state, on_disk} unless row.media_kind == :episode && row.state == State::Importing

      if on_disk.nil?
        if row.episode_has_file
          {State::Importing, ImportProgress.new("", target, target)}
        else
          {State::ImportPending, nil}
        end
      elsif active
        {State::Importing, on_disk}
      else
        {State::Importing, ImportProgress.new(on_disk.file, target, target)}
      end
    end

    # A red, `⚠`-prefixed interior line surfacing a failed backend so an
    # unreachable *arr is visible, not silent. The text is fit to *interior* and
    # padded to it *before* colouring, so the ANSI codes never count toward the
    # visible width and the row still lines up under the right border.
    private def error_content(name : String, message : String, interior : Int32) : String
      text = Render.truncate("⚠ backend #{name.inspect}: #{message}", interior).ljust(interior)
      @theme.colorize(text, @theme.status_failed)
    end

    # Tallies effective display *states* for the header summary (so a reclassified
    # season-pack row counts as pending/importing per what's shown).
    private def counts(states : Array(State)) : Hash(State, Int32)
      tally = Hash(State, Int32).new(0)
      states.each { |state| tally[state] += 1 }
      tally
    end
  end
end
