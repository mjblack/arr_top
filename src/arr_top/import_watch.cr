require "log"

module ArrTop
  # A single import-copy progress reading: the destination file currently being
  # written, how many bytes it holds so far, and the copy's final target size.
  struct ImportProgress
    getter file : String
    getter bytes : Int64
    getter target : Int64

    def initialize(@file : String, @bytes : Int64, @target : Int64)
    end

    # Copy progress as a 0–100 percentage, clamped so a file that momentarily
    # overshoots `target` never reports past 100. 0 when the target is unknown.
    def percent : Float64
      target > 0 ? (bytes.to_f / target * 100).clamp(0.0, 100.0) : 0.0
    end
  end

  # Reads live import (copy) progress off disk. The *arr API reports an import as
  # `importing` with `sizeleft: 0` and no copy progress, so the only way to show
  # how far the copy has gotten is to watch the destination file grow on disk.
  #
  # This works only when arrtop runs **on the *arr host** (or on a mount of its
  # library). Off-host — the folder does not exist or cannot be read — it
  # degrades to "unknown" (`nil`) and never raises.
  module ImportWatch
    Log = ::Log.for("arrtop.import")

    # Video-file extensions (lower-case, with dot) that count as an import's
    # destination file. Anything else in the folder (`.nfo`, `.srt`, artwork,
    # ...) is ignored.
    VIDEO_EXTENSIONS = Set{
      ".mkv", ".mp4", ".avi", ".m4v", ".ts", ".m2ts",
      ".mov", ".wmv", ".mpg", ".mpeg", ".webm", ".flv",
    }

    # Live copy progress for an `Importing` row, or `nil` when there is nothing
    # to show.
    #
    # Returns `nil` (unwatchable / nothing yet) when: *dest_folder* is nil or
    # blank; *target* is `<= 0`; the folder does not exist or cannot be read; or
    # no candidate video file exists yet (the import may not have created it).
    #
    # Otherwise it walks *dest_folder* recursively, picks the most recently
    # modified video file (the one actively being written — see below), reads its
    # size, and returns an `ImportProgress`.
    #
    # The destination is a *folder*: Radarr's movie folder, or Sonarr's series
    # folder (where the file lands in a `Season NN/` subfolder), so the walk is
    # recursive. Selection is by **most-recent mtime**, not largest size: during
    # an upgrade a full old file sits beside the new partial one, and the
    # largest-size heuristic would wrongly pick the old file — the freshly
    # written file is the one with the newest mtime.
    def self.progress(dest_folder : String?, target : Int64) : ImportProgress?
      return nil if dest_folder.nil?
      folder = dest_folder.strip
      return nil if folder.empty?
      return nil if target <= 0

      unless Dir.exists?(folder)
        Log.debug { "import folder not found (off-host?): #{folder}" }
        return nil
      end

      newest = newest_video_file(folder)
      if newest.nil?
        Log.debug { "no video file yet under #{folder}" }
        return nil
      end

      file, bytes = newest
      progress = ImportProgress.new(file, bytes, target)
      Log.debug { "watching #{file}: #{bytes}/#{target} (#{progress.percent.round(1)}%)" }
      progress
    end

    # Recursively finds the most-recently-modified video file under *root*,
    # returning `{path, size}` or `nil` when none is found. Every filesystem call
    # is guarded: files can vanish mid-copy and directories can be unreadable, so
    # a failing entry is skipped rather than aborting the whole walk (an
    # unreadable root simply yields `nil`).
    private def self.newest_video_file(root : String) : {String, Int64}?
      best_path : String? = nil
      best_mtime = Time.unix(0)
      best_size = 0_i64

      walk(root) do |path, info|
        next unless video?(path)
        mtime = info.modification_time
        if best_path.nil? || mtime > best_mtime
          best_path = path
          best_mtime = mtime
          best_size = info.size
        end
      end

      if path = best_path
        {path, best_size}
      end
    end

    # Recursively yields `{path, File::Info}` for every regular file under *dir*.
    #
    # Uses a manual walk with `Dir.each_child` + `File.info` — **never**
    # `Dir.glob`. Real *arr folders embed glob metacharacters in their names
    # (e.g. `Jurassic Park (1993) {tmdb-329}`, bracketed release tags) that
    # `Dir.glob` would interpret as patterns instead of literal path segments.
    # Each `Dir`/`File.info` call is rescued so a vanished file or unreadable
    # subdirectory is skipped, not fatal.
    private def self.walk(dir : String, &block : String, File::Info -> Nil) : Nil
      children =
        begin
          Dir.children(dir)
        rescue ex : File::Error
          Log.debug { "cannot read directory #{dir}: #{ex.message}" }
          return
        end

      children.each do |name|
        path = File.join(dir, name)
        info =
          begin
            File.info(path, follow_symlinks: false)
          rescue File::Error
            next # vanished mid-copy or unreadable — skip
          end

        if info.directory?
          walk(path, &block)
        elsif info.file?
          block.call(path, info)
        end
      end
    end

    # Whether *path* ends in a known video extension (case-insensitive).
    private def self.video?(path : String) : Bool
      VIDEO_EXTENSIONS.includes?(File.extname(path).downcase)
    end
  end
end
