require "./spec_helper"
require "file_utils"

# Offline specs for the import disk-watch. Every case builds a throwaway temp
# tree; nothing touches the network or a real *arr host.
private def with_tempdir(&)
  dir = File.tempname("arrtop-import")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

# Creates a file at *path* of exactly *bytes* bytes (sparse — via truncate, so
# multi-GB sizes cost no memory or disk), making parent dirs as needed.
private def write_sized(path : String, bytes : Int64) : Nil
  Dir.mkdir_p(File.dirname(path))
  File.open(path, "w", &.truncate(bytes))
end

# Builds a Season 02 folder with a partial S02E03 (currently copying), a complete
# S02E02 (already imported), and a decoy S02E10, then yields the series root.
private def with_season_pack(&)
  with_tempdir do |dir|
    season = File.join(dir, "Season 02")
    write_sized(File.join(season, "The.Show.S02E02.mkv"), 10_000_i64) # complete
    write_sized(File.join(season, "The.Show.S02E03.mkv"), 4_000_i64)  # partial
    write_sized(File.join(season, "The.Show.S02E10.mkv"), 9_000_i64)  # decoy
    yield dir
  end
end

# Mirrors the live Fallout S01 pack (8 episodes, one folder, copied one file at a
# time): E01–E03 fully copied with progressively older mtimes, E04 the newest
# partial file (actively copying), E05+ absent, plus non-video decoys and an
# out-of-pack S01E10 decoy.
private def with_fallout_pack(&)
  with_tempdir do |dir|
    season = File.join(dir, "Season 01")
    e01 = File.join(season, "Fallout - S01E01 - The End.mkv")
    e02 = File.join(season, "Fallout - S01E02 - The Target.mkv")
    e03 = File.join(season, "Fallout - S01E03 - The Head.mkv")
    e04 = File.join(season, "Fallout - S01E04 - The Ghouls.mkv")
    decoy = File.join(season, "Fallout - S01E10 - Decoy.mkv")
    write_sized(e01, 3_000_i64) # done
    write_sized(e02, 2_680_i64) # done
    write_sized(e03, 2_800_i64) # done
    write_sized(e04, 574_i64)   # actively copying (partial)
    # Non-video decoys and an out-of-pack episode decoy.
    write_sized(File.join(season, "Fallout - S01E01 - The End.nfo"), 500_i64)
    write_sized(File.join(season, "Fallout - S01E01-thumb.jpg"), 500_i64)
    write_sized(decoy, 9_000_i64)

    now = Time.utc
    File.touch(e01, now - 30.minutes)
    File.touch(e02, now - 20.minutes)
    File.touch(e03, now - 10.minutes)
    File.touch(decoy, now - 40.minutes)
    File.touch(e04, now) # newest ⇒ active
    yield dir
  end
end

describe ArrTop::ImportWatch do
  describe ".progress" do
    it "returns nil when dest_folder is nil" do
      ArrTop::ImportWatch.progress(nil, 100_i64).should be_nil
    end

    it "returns nil when dest_folder is blank" do
      ArrTop::ImportWatch.progress("   ", 100_i64).should be_nil
    end

    it "returns nil when target is zero or negative" do
      with_tempdir do |dir|
        write_sized(File.join(dir, "movie.mkv"), 10_i64)
        ArrTop::ImportWatch.progress(dir, 0_i64).should be_nil
        ArrTop::ImportWatch.progress(dir, -5_i64).should be_nil
      end
    end

    it "returns nil when the folder does not exist" do
      ArrTop::ImportWatch.progress("/no/such/arrtop/folder", 100_i64).should be_nil
    end

    it "returns nil when the folder has no video file" do
      with_tempdir do |dir|
        write_sized(File.join(dir, "movie.nfo"), 10_i64)
        write_sized(File.join(dir, "readme.txt"), 10_i64)
        ArrTop::ImportWatch.progress(dir, 100_i64).should be_nil
      end
    end

    it "reports bytes and percent for a single growing video file" do
      with_tempdir do |dir|
        two_gb = 2_i64 * 1024 * 1024 * 1024
        target = 9_663_676_416_i64 # ~9.0 GiB
        write_sized(File.join(dir, "movie.mkv"), two_gb)

        progress = ArrTop::ImportWatch.progress(dir, target).as(ArrTop::ImportProgress)
        progress.bytes.should eq(two_gb)
        progress.target.should eq(target)
        progress.percent.should be_close(22.2, 0.5)
      end
    end

    it "clamps percent to 100 when bytes meets or exceeds target" do
      with_tempdir do |dir|
        write_sized(File.join(dir, "movie.mkv"), 200_i64)
        progress = ArrTop::ImportWatch.progress(dir, 100_i64).as(ArrTop::ImportProgress)
        progress.percent.should eq(100.0)
      end
    end

    it "picks the most-recently-modified video file (upgrade case)" do
      with_tempdir do |dir|
        # An older, larger "full" file from a prior version, and a newer, smaller
        # file currently being written. Most-recent-mtime must pick the newer
        # (smaller) file; a largest-size heuristic would wrongly pick the old one.
        old_full = File.join(dir, "movie.2020.mkv")
        new_part = File.join(dir, "movie.2024.mkv")
        write_sized(old_full, 8_000_i64)
        write_sized(new_part, 2_000_i64)

        now = Time.utc
        File.touch(old_full, now - 1.hour)
        File.touch(new_part, now)

        progress = ArrTop::ImportWatch.progress(dir, 10_000_i64).as(ArrTop::ImportProgress)
        progress.file.should eq(new_part)
        progress.bytes.should eq(2_000_i64)
      end
    end

    it "ignores non-video files (.nfo, .srt, .txt)" do
      with_tempdir do |dir|
        write_sized(File.join(dir, "movie.nfo"), 5_000_i64)
        write_sized(File.join(dir, "movie.srt"), 5_000_i64)
        write_sized(File.join(dir, "notes.txt"), 5_000_i64)
        write_sized(File.join(dir, "movie.mkv"), 1_000_i64)

        progress = ArrTop::ImportWatch.progress(dir, 4_000_i64).as(ArrTop::ImportProgress)
        progress.bytes.should eq(1_000_i64) # the .mkv, not the larger sidecars
      end
    end

    it "finds a file in a nested subfolder (recursive walk)" do
      with_tempdir do |dir|
        # Sonarr-style: file lands in a Season NN/ subfolder.
        nested = File.join(dir, "Season 01", "episode.mkv")
        write_sized(nested, 3_000_i64)

        progress = ArrTop::ImportWatch.progress(dir, 6_000_i64).as(ArrTop::ImportProgress)
        progress.file.should eq(nested)
        progress.bytes.should eq(3_000_i64)
        progress.percent.should be_close(50.0, 0.01)
      end
    end

    it "handles folder names containing glob metacharacters (manual walk, not Dir.glob)" do
      with_tempdir do |dir|
        # A real *arr folder name with { } [ ] that Dir.glob would misread.
        movie_dir = File.join(dir, "Jurassic Park (1993) {tmdb-329} [Bluray-1080p]")
        file = File.join(movie_dir, "Jurassic.Park.1993.mkv")
        write_sized(file, 2_500_i64)

        progress = ArrTop::ImportWatch.progress(dir, 5_000_i64).as(ArrTop::ImportProgress)
        progress.file.should eq(file)
        progress.bytes.should eq(2_500_i64)
        progress.percent.should be_close(50.0, 0.01)
      end
    end

    # Episode-aware matching for Sonarr season packs: N episodes land in ONE
    # series folder sharing one download, so each row must watch ITS OWN file.
    describe "episode-aware (season/episode given)" do
      it "picks THIS episode's file and its bytes, not the folder's newest" do
        with_season_pack do |dir|
          progress = ArrTop::ImportWatch.progress(dir, 8_000_i64, 2, 3).as(ArrTop::ImportProgress)
          progress.file.should end_with("The.Show.S02E03.mkv")
          progress.bytes.should eq(4_000_i64)
          progress.percent.should be_close(50.0, 0.01)
        end
      end

      it "reads ~100% for a completed episode" do
        with_season_pack do |dir|
          progress = ArrTop::ImportWatch.progress(dir, 10_000_i64, 2, 2).as(ArrTop::ImportProgress)
          progress.file.should end_with("The.Show.S02E02.mkv")
          progress.percent.should be_close(100.0, 0.01)
        end
      end

      it "returns nil for an episode with no file present" do
        with_season_pack do |dir|
          ArrTop::ImportWatch.progress(dir, 8_000_i64, 2, 7).should be_nil
        end
      end

      it "tolerates zero-padding (S2E3 matches S02E03)" do
        with_tempdir do |dir|
          write_sized(File.join(dir, "Show.S02E03.mkv"), 4_000_i64)
          progress = ArrTop::ImportWatch.progress(dir, 8_000_i64, 2, 3).as(ArrTop::ImportProgress)
          progress.file.should end_with("Show.S02E03.mkv")
        end
      end

      it "matches BOTH episodes of a multi-episode file (S02E03E04)" do
        with_tempdir do |dir|
          multi = File.join(dir, "The.Show.S02E03E04.mkv")
          write_sized(multi, 5_000_i64)
          ArrTop::ImportWatch.progress(dir, 10_000_i64, 2, 3).as(ArrTop::ImportProgress).file.should eq(multi)
          ArrTop::ImportWatch.progress(dir, 10_000_i64, 2, 4).as(ArrTop::ImportProgress).file.should eq(multi)
          # A non-member episode of that file must NOT match.
          ArrTop::ImportWatch.progress(dir, 10_000_i64, 2, 5).should be_nil
        end
      end

      it "picks the most-recent matching file on an upgrade (old full beside new partial)" do
        with_tempdir do |dir|
          old_full = File.join(dir, "Show.S02E03.1080p.mkv")
          new_part = File.join(dir, "Show.S02E03.2160p.mkv")
          write_sized(old_full, 9_000_i64)
          write_sized(new_part, 3_000_i64)
          now = Time.utc
          File.touch(old_full, now - 1.hour)
          File.touch(new_part, now)

          progress = ArrTop::ImportWatch.progress(dir, 10_000_i64, 2, 3).as(ArrTop::ImportProgress)
          progress.file.should eq(new_part)
          progress.bytes.should eq(3_000_i64)
        end
      end

      it "keeps legacy newest-file behaviour when season/episode are nil (movies)" do
        with_season_pack do |dir|
          # No season/episode => the folder-wide most-recent video file, ignoring
          # the SxxEyy tokens entirely.
          newest = File.join(dir, "Season 02", "The.Show.NEWEST.mkv")
          write_sized(newest, 1_000_i64)
          File.touch(newest, Time.utc + 1.hour)
          progress = ArrTop::ImportWatch.progress(dir, 8_000_i64).as(ArrTop::ImportProgress)
          progress.file.should eq(newest)
        end
      end
    end
  end

  # Episode-aware watch that also reports whether THIS episode's file is the
  # folder's newest-mtime video (the one actively being copied). Mirrors the live
  # Fallout S01 pack: E01–E03 fully copied with older mtimes, E04 the newest
  # partial file, E05+ absent, plus non-video decoys and an out-of-range decoy.
  describe ".episode_progress" do
    it "reports the active/newest episode with its partial bytes and active=true" do
      with_fallout_pack do |dir|
        # Per-episode estimate: ~22.96 GB / 8 ≈ 2.87 GB (use 2870 here at scale).
        progress, active = ArrTop::ImportWatch.episode_progress(dir, 2_870_i64, 1, 4)
          .as({ArrTop::ImportProgress, Bool})
        progress.file.should end_with("S01E04 - The Ghouls.mkv")
        progress.bytes.should eq(574_i64)
        active.should be_true
        progress.percent.should be_close(20.0, 0.2)
      end
    end

    it "reports a completed episode (older mtime) as present-but-not-active" do
      with_fallout_pack do |dir|
        {1, 2, 3}.each do |episode|
          progress, active = ArrTop::ImportWatch.episode_progress(dir, 2_870_i64, 1, episode)
            .as({ArrTop::ImportProgress, Bool})
          progress.file.should contain("S01E0#{episode}")
          active.should be_false # older mtime ⇒ already copied, not the active file
        end
      end
    end

    it "returns nil for an episode with no file present yet (E05)" do
      with_fallout_pack do |dir|
        ArrTop::ImportWatch.episode_progress(dir, 2_870_i64, 1, 5).should be_nil
      end
    end

    it "ignores non-video decoys when matching an episode" do
      with_fallout_pack do |dir|
        progress, _ = ArrTop::ImportWatch.episode_progress(dir, 2_870_i64, 1, 1)
          .as({ArrTop::ImportProgress, Bool})
        progress.file.should end_with(".mkv") # not the .nfo / -thumb.jpg
        progress.bytes.should eq(3_000_i64)
      end
    end

    it "returns nil off-host / blank folder / non-positive target" do
      ArrTop::ImportWatch.episode_progress(nil, 100_i64, 1, 4).should be_nil
      ArrTop::ImportWatch.episode_progress("   ", 100_i64, 1, 4).should be_nil
      ArrTop::ImportWatch.episode_progress("/no/such/arrtop/folder", 100_i64, 1, 4).should be_nil
      with_fallout_pack do |dir|
        ArrTop::ImportWatch.episode_progress(dir, 0_i64, 1, 4).should be_nil
      end
    end
  end

  describe ArrTop::ImportProgress do
    it "computes percent and clamps to [0, 100]" do
      ArrTop::ImportProgress.new("f.mkv", 50_i64, 100_i64).percent.should eq(50.0)
      ArrTop::ImportProgress.new("f.mkv", 150_i64, 100_i64).percent.should eq(100.0)
    end

    it "reports 0 percent when the target is unknown" do
      ArrTop::ImportProgress.new("f.mkv", 50_i64, 0_i64).percent.should eq(0.0)
    end
  end
end
