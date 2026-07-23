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
  download_id : String? = nil,
) : ArrTop::QueueRow
  ArrTop::QueueRow.new(
    backend_name: "b", media_kind: :episode, state: ArrTop::State::Importing,
    size: import_target, size_left: 0_i64, import_target: import_target,
    title: "The.Show.S02E03", media_name: "The Show S02E03", dest_folder: "/tv/The Show",
    season_number: season, episode_number: episode, episode_has_file: episode_has_file,
    download_id: download_id,
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

  describe ".download_group_counts" do
    it "counts rows per download_id, ignoring nil ids" do
      rows = [
        episode_row(episode: 1, download_id: "pack"),
        episode_row(episode: 2, download_id: "pack"),
        episode_row(episode: 3, download_id: "pack"),
        episode_row(episode: 1, download_id: "solo"),
        episode_row(episode: 1, download_id: nil),
      ]
      counts = ArrTop::TUI.download_group_counts(rows)
      counts["pack"].should eq(3)
      counts["solo"].should eq(1)
      counts.has_key?(nil).should be_false
    end
  end

  describe ".effective_target" do
    it "splits the pack total across the pack's episodes (count > 1)" do
      counts = {"pack" => 8}
      row = episode_row(import_target: 22_961_512_974_i64, download_id: "pack")
      # ~22.96 GB / 8 ≈ 2.87 GB per episode.
      ArrTop::TUI.effective_target(row, counts).should eq(2_870_189_121_i64)
    end

    it "keeps the reported target for a single-file download (count 1)" do
      counts = {"solo" => 1}
      row = episode_row(import_target: 3_000_i64, download_id: "solo")
      ArrTop::TUI.effective_target(row, counts).should eq(3_000_i64)
    end

    it "keeps the reported target for a row with no download_id" do
      row = episode_row(import_target: 3_000_i64, download_id: nil)
      ArrTop::TUI.effective_target(row, {} of String => Int32).should eq(3_000_i64)
    end

    it "keeps the reported target for movies" do
      movie = ArrTop::QueueRow.new(
        backend_name: "b", media_kind: :movie, state: ArrTop::State::Importing,
        size: 5_000_i64, size_left: 0_i64, import_target: 5_000_i64,
        download_id: "m")
      ArrTop::TUI.effective_target(movie, {"m" => 3}).should eq(5_000_i64)
    end
  end

  describe ".disk_bytes" do
    it "uses the resolved import progress's real bytes for an importing row" do
      row = episode_row(import_target: 2_870_i64)
      progress = ArrTop::ImportProgress.new("/tv/E03.mkv", 1_500_i64, 2_870_i64)
      ArrTop::TUI.disk_bytes(row, ArrTop::State::Importing, progress, 2_870_i64).should eq(1_500_i64)
    end

    it "reports the full size for a done episode (bytes == target)" do
      row = episode_row(import_target: 2_870_i64)
      done = ArrTop::ImportProgress.new("/tv/E03.mkv", 2_870_i64, 2_870_i64)
      ArrTop::TUI.disk_bytes(row, ArrTop::State::Importing, done, 2_870_i64).should eq(2_870_i64)
    end

    it "is nil for a pending row with no import progress" do
      row = episode_row
      ArrTop::TUI.disk_bytes(row, ArrTop::State::ImportPending, nil, 2_870_i64).should be_nil
    end

    it "scales a downloading row's downloaded fraction onto the effective total" do
      # 50% downloaded (size 1000, size_left 500) of a 2870-byte per-episode total
      # → 1435 bytes on disk.
      row = downloading_row
      ArrTop::TUI.disk_bytes(row, ArrTop::State::Downloading, nil, 2_870_i64).should eq(1_435_i64)
    end

    it "is nil for a queued row" do
      row = downloading_row
      ArrTop::TUI.disk_bytes(row, ArrTop::State::Queued, nil, 1_000_i64).should be_nil
    end
  end

  describe ".display_state_and_progress" do
    it "shows an active (newest-mtime) episode with its real partial bar" do
      # 574 of the ~2.87 GB per-episode estimate ≈ 20%.
      partial = ArrTop::ImportProgress.new("/tv/E04.mkv", 574_i64, 2_870_i64)
      state, import = ArrTop::TUI.display_state_and_progress(
        episode_row(episode_has_file: false), partial, active: true, target: 2_870_i64)
      state.should eq(ArrTop::State::Importing)
      import.should eq(partial)
      import.as(ArrTop::ImportProgress).percent.should be_close(20.0, 0.1)
    end

    it "shows a present-but-not-active episode (already copied) at 100%" do
      # An older-mtime file that has finished copying: bytes on disk are the
      # partial reading from a prior frame, but not-active ⇒ done ⇒ 100%.
      partial = ArrTop::ImportProgress.new("/tv/E01.mkv", 400_i64, 2_870_i64)
      state, import = ArrTop::TUI.display_state_and_progress(
        episode_row(episode_has_file: false), partial, active: false, target: 2_870_i64)
      state.should eq(ArrTop::State::Importing)
      import.as(ArrTop::ImportProgress).percent.should eq(100.0)
      import.as(ArrTop::ImportProgress).file.should eq("/tv/E01.mkv")
    end

    it "reclassifies an importing episode with no file yet as pending (no bar)" do
      state, import = ArrTop::TUI.display_state_and_progress(
        episode_row(episode_has_file: false), nil, active: false, target: 2_870_i64)
      state.should eq(ArrTop::State::ImportPending)
      import.should be_nil
    end

    it "falls back to 100% when there is no on-disk match but episode_has_file is set" do
      state, import = ArrTop::TUI.display_state_and_progress(
        episode_row(episode_has_file: true), nil, active: false, target: 2_870_i64)
      state.should eq(ArrTop::State::Importing)
      import.as(ArrTop::ImportProgress).percent.should eq(100.0)
    end

    it "leaves movie rows untouched (no reclassification)" do
      movie = ArrTop::QueueRow.new(
        backend_name: "b", media_kind: :movie, state: ArrTop::State::Importing,
        size: 1000_i64, size_left: 0_i64, import_target: 1000_i64, dest_folder: "/m")
      state, import = ArrTop::TUI.display_state_and_progress(movie, nil, active: false, target: 1000_i64)
      state.should eq(ArrTop::State::Importing)
      import.should be_nil
    end

    it "leaves a non-importing episode row untouched" do
      row = ArrTop::QueueRow.new(
        backend_name: "b", media_kind: :episode, state: ArrTop::State::Downloading,
        size: 1000_i64, size_left: 500_i64, import_target: 1000_i64,
        season_number: 2, episode_number: 3)
      state, import = ArrTop::TUI.display_state_and_progress(row, nil, active: false, target: 1000_i64)
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

    it "renders a downloading row with its status, size, bar and percent inside the box" do
      # A wide terminal so the SIZE column and a full PROGRESS bar both fit.
      frame = build_tui.build_frame([downloading_row], {rows: 24, cols: 110})
      frame.should contain("downloading")
      frame.should contain("50.0%")
      frame.should contain("█")          # bar cells
      frame.should contain("500/1000 B") # combined on-disk/total size pair
      frame.should contain("║")          # side borders
      frame.should contain("MEDIA")      # column header row
      frame.should contain("SIZE")       # column header includes the new column
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
