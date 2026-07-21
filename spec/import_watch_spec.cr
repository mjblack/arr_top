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
