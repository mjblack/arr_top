require "./spec_helper"

# A downloading QueueRow with a known percent (size 1000, size_left 500 => 50%).
private def downloading_row(title : String = "Some Show") : ArrTop::QueueRow
  ArrTop::QueueRow.new(
    backend_name: "b", media_kind: :episode, state: ArrTop::State::Downloading,
    size: 1000_i64, size_left: 500_i64, import_target: 1000_i64,
    title: title, timeleft: "00:10:00", dest_folder: "/data",
  )
end

# A TUI wired to a no-backend poller (so `#errors` stays empty and no network is
# touched) and a disabled theme (so frames are ANSI-free and deterministic);
# `build_frame` and `.quit?` are pure enough to test offline.
private def build_tui : ArrTop::TUI
  ArrTop::TUI.new(
    ArrTop::Poller.new([] of ArrTop::Backend), 1.second,
    theme: ArrTop::Theme.disabled)
end

# Splits a rendered frame into its visible lines (they are joined with "\r\n").
private def frame_lines(frame : String) : Array(String)
  frame.split("\r\n")
end

describe ArrTop::TUI do
  describe ".quit?" do
    it "quits on q, Q, and Ctrl-C (byte 3)" do
      ArrTop::TUI.quit?('q'.ord.to_u8).should be_true
      ArrTop::TUI.quit?('Q'.ord.to_u8).should be_true
      ArrTop::TUI.quit?(3_u8).should be_true
    end

    it "quits on the stdin-EOF sentinel (nil)" do
      ArrTop::TUI.quit?(nil).should be_true
    end

    it "does not quit on other keys" do
      ArrTop::TUI.quit?('j'.ord.to_u8).should be_false
      ArrTop::TUI.quit?(0x1b_u8).should be_false # ESC (start of an arrow key)
      ArrTop::TUI.quit?('['.ord.to_u8).should be_false
    end
  end

  describe "#build_frame" do
    it "shows a friendly message for an empty queue, inside the box" do
      frame = build_tui.build_frame([] of ArrTop::QueueRow, {rows: 24, cols: 80})
      frame.should contain("arrtop") # in the top border
      frame.should contain("queue empty")
      frame.should contain("╔") # double-line box top-left corner
      frame.should contain("╝") # bottom-right corner
    end

    it "renders a downloading row with its status, bar and percent inside the box" do
      frame = build_tui.build_frame([downloading_row], {rows: 24, cols: 80})
      frame.should contain("downloading")
      frame.should contain("50.0%")
      frame.should contain("█")     # bar cells
      frame.should contain("║")     # side borders
      frame.should contain("MOVIE") # column header row
    end

    it "starts at cursor-home and clears to end of screen" do
      frame = build_tui.build_frame([] of ArrTop::QueueRow, {rows: 24, cols: 80})
      frame.starts_with?("\e[H").should be_true
      frame.ends_with?("\e[J").should be_true
    end

    it "never emits more lines than the terminal height" do
      rows = Array.new(20) { |i| downloading_row("Show #{i}") }
      frame = build_tui.build_frame(rows, {rows: 3, cols: 80})
      frame_lines(frame).size.should be <= 3
    end
  end
end
