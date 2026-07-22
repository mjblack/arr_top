module ArrTop
  # The TUI colour scheme: a bag of ANSI escape codes plus an `enabled` flag and
  # one `#colorize` helper. Everything the renderer draws pulls its colour from a
  # `Theme`, so a single place decides "what does an importing row look like" and
  # whether colour is emitted at all.
  #
  # FUTURE: the theme is meant to be user-configurable (exposed via `Config`) so a
  # user can override any of these codes. For now that wiring does **not** exist —
  # the whole app uses `Theme.default` (a TTY with colour) or `Theme.disabled`
  # (piped/`NO_COLOR`). When config support lands, add a `Theme.from_config` that
  # overlays user codes on top of `default`; nothing else here needs to change.
  #
  # Colours are 256-colour escapes (`\e[38;5;Nm`) where a specific light tone is
  # wanted, and plain SGR codes (`\e[3Xm`) otherwise. A code may be the empty
  # string, which means "no colour" (`Queued` reads in the terminal's default
  # foreground); `#colorize` passes such text through untouched.
  struct Theme
    # The SGR reset that ends every colourised span.
    RESET = "\e[0m"

    # Progress-bar filled cell — light blue.
    getter bar_filled : String
    # Progress-bar remaining cell — light grey.
    getter bar_remaining : String
    # Progress-bar `[`/`]` brackets — dark grey.
    getter brackets : String

    # Progress-bar cell glyphs. Both default to `█` (U+2588 FULL BLOCK) so the
    # bar is a solid two-tone run distinguished only by colour — the most
    # font-portable choice. They are separate fields so the empty cell can later
    # be switched to a shade glyph (`░`/`▒`) in one place; the bar renderer reads
    # the glyphs from here rather than hardcoding them.
    getter bar_filled_glyph : String
    getter bar_empty_glyph : String

    # Status label colours, keyed by meaning.
    getter status_importing : String   # green
    getter status_pending : String     # purple/magenta
    getter status_downloading : String # blue
    getter status_failed : String      # red (also every warning/error row)
    getter status_queued : String      # default terminal colour (no code)
    getter status_unknown : String     # dim grey

    # Box border/corner colour — dim grey.
    getter border : String
    # Column-header label colour — bold.
    getter header_label : String
    # App title in the top border — bold.
    getter title : String
    # Aggregated transfer-speed readout — green.
    getter speed : String

    # Whether colour is emitted at all. When false every `#colorize` call returns
    # its text bare, so no ANSI leaks into a pipe, a file, or a `NO_COLOR` session.
    getter? enabled : Bool

    def initialize(
      *,
      @bar_filled : String,
      @bar_remaining : String,
      @brackets : String,
      @bar_filled_glyph : String,
      @bar_empty_glyph : String,
      @status_importing : String,
      @status_pending : String,
      @status_downloading : String,
      @status_failed : String,
      @status_queued : String,
      @status_unknown : String,
      @border : String,
      @header_label : String,
      @title : String,
      @speed : String,
      @enabled : Bool,
    )
    end

    # The default palette with colour **on** (for an interactive TTY).
    def self.default : Theme
      build(enabled: true)
    end

    # The default palette with colour **off** — for piped/`--once`/`NO_COLOR`
    # output and for pure width-accounting in specs (plain glyphs, no ANSI).
    def self.disabled : Theme
      build(enabled: false)
    end

    # The right theme for an output stream: the default palette, enabled only
    # when *tty* is true **and** `NO_COLOR` is unset in the environment. This is
    # the single gate that keeps ANSI out of non-terminal output.
    def self.detect(*, tty : Bool) : Theme
      build(enabled: tty && !ENV.has_key?("NO_COLOR"))
    end

    # Builds the default palette with the given `enabled` flag. The colour codes
    # live here in exactly one place.
    private def self.build(*, enabled : Bool) : Theme
      new(
        bar_filled: "\e[38;5;111m",     # light blue
        bar_remaining: "\e[38;5;250m",  # light grey
        brackets: "\e[38;5;240m",       # dark grey
        bar_filled_glyph: "█",          # U+2588 FULL BLOCK
        bar_empty_glyph: "█",           # U+2588 FULL BLOCK (grey via colour)
        status_importing: "\e[32m",     # green
        status_pending: "\e[38;5;135m", # purple/magenta
        status_downloading: "\e[34m",   # blue
        status_failed: "\e[31m",        # red
        status_queued: "",              # default terminal colour
        status_unknown: "\e[38;5;244m", # dim grey
        border: "\e[38;5;240m",         # dim grey
        header_label: "\e[1m",          # bold
        title: "\e[1m",                 # bold
        speed: "\e[32m",                # green
        enabled: enabled,
      )
    end

    # Wraps *text* in *code* + `RESET` when colour is enabled and *code* is
    # non-empty; otherwise returns *text* unchanged. Because it only ever adds
    # escape sequences around the text, the **visible** width is never altered —
    # callers can lay out on plain text and colourise afterward.
    def colorize(text : String, code : String) : String
      return text unless @enabled
      return text if code.empty?
      "#{code}#{text}#{RESET}"
    end

    # The status-label colour code for *row*: any warning/error row (or the
    # `Failed` state) is red, overriding the per-state colour; otherwise the
    # colour follows the normalized `State`. *state* defaults to `row.state` but
    # may be the reclassified display state (e.g. a season-pack row shown pending).
    def status_code(row : QueueRow, state : State = row.state) : String
      return @status_failed if row.warning? || state == State::Failed

      case state
      when State::Importing     then @status_importing
      when State::ImportPending then @status_pending
      when State::Downloading   then @status_downloading
      when State::Queued        then @status_queued
      else                           @status_unknown
      end
    end
  end
end
