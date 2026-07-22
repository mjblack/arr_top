require "./spec_helper"

# A downloading QueueRow with a known percent (size 1000, size_left 500 => 50%).
private def downloading_row(title : String = "Some Show") : ArrTop::QueueRow
  ArrTop::QueueRow.new(
    backend_name: "b", media_kind: :episode, state: ArrTop::State::Downloading,
    size: 1000_i64, size_left: 500_i64, import_target: 1000_i64,
    title: title, timeleft: "00:10:00", dest_folder: "/data",
  )
end

# An importing Sonarr episode row, varying the fields the reclassification reads.
private def episode_row(
  episode_has_file : Bool? = nil,
  season : Int32? = 2,
  episode : Int32? = 3,
  import_target : Int64 = 1000_i64,
) : ArrTop::QueueRow
  ArrTop::QueueRow.new(
    backend_name: "b", media_kind: :episode, state: ArrTop::State::Importing,
    size: import_target, size_left: 0_i64, import_target: import_target,
    title: "The.Show.S02E03", media_name: "The Show S02E03", dest_folder: "/tv/The Show",
    season_number: season, episode_number: episode, episode_has_file: episode_has_file,
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

  describe ".display_state_and_progress" do
    it "shows a done episode (episode_has_file) as importing at 100%, even with no on-disk match" do
      state, import = ArrTop::TUI.display_state_and_progress(episode_row(episode_has_file: true), nil)
      state.should eq(ArrTop::State::Importing)
      import.as(ArrTop::ImportProgress).percent.should eq(100.0)
    end

    it "forces 100% for a done episode even when the on-disk file reads partial" do
      partial = ArrTop::ImportProgress.new("/tv/f.mkv", 400_i64, 1000_i64)
      state, import = ArrTop::TUI.display_state_and_progress(episode_row(episode_has_file: true), partial)
      state.should eq(ArrTop::State::Importing)
      import.as(ArrTop::ImportProgress).percent.should eq(100.0)
    end

    it "shows a copying episode with its partial on-disk bar" do
      partial = ArrTop::ImportProgress.new("/tv/f.mkv", 410_i64, 1000_i64)
      state, import = ArrTop::TUI.display_state_and_progress(episode_row(episode_has_file: false), partial)
      state.should eq(ArrTop::State::Importing)
      import.should eq(partial)
      import.as(ArrTop::ImportProgress).percent.should be_close(41.0, 0.01)
    end

    it "reclassifies an importing episode with no file yet as pending (no bar)" do
      state, import = ArrTop::TUI.display_state_and_progress(episode_row(episode_has_file: false), nil)
      state.should eq(ArrTop::State::ImportPending)
      import.should be_nil
    end

    it "leaves movie rows untouched (no reclassification)" do
      movie = ArrTop::QueueRow.new(
        backend_name: "b", media_kind: :movie, state: ArrTop::State::Importing,
        size: 1000_i64, size_left: 0_i64, import_target: 1000_i64, dest_folder: "/m")
      state, import = ArrTop::TUI.display_state_and_progress(movie, nil)
      state.should eq(ArrTop::State::Importing)
      import.should be_nil
    end

    it "leaves a non-importing episode row untouched" do
      row = ArrTop::QueueRow.new(
        backend_name: "b", media_kind: :episode, state: ArrTop::State::Downloading,
        size: 1000_i64, size_left: 500_i64, import_target: 1000_i64,
        season_number: 2, episode_number: 3)
      state, import = ArrTop::TUI.display_state_and_progress(row, nil)
      state.should eq(ArrTop::State::Downloading)
      import.should be_nil
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
      frame.should contain("MEDIA") # column header row
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
