require "./spec_helper"

# A counting fetcher: records how many times it was called (per hash) and serves
# a canned file list per (downcased) hash. Injected in place of the real
# qBittorrent network call so tests are deterministic and offline.
private class FakeFetcher
  getter calls : Hash(String, Int32) = Hash(String, Int32).new(0)

  def initialize(@files : Hash(String, ArrTop::TorrentSizes::FileList))
  end

  # The `TorrentSizes::Fetcher` proc: (client_name, hash) -> FileList?.
  def to_proc : ArrTop::TorrentSizes::Fetcher
    ArrTop::TorrentSizes::Fetcher.new do |_name, hash|
      @calls[hash] += 1
      @files[hash]?
    end
  end
end

private def cf(name : String, size : Int64?) : ArrTop::TorrentSizes::CachedFile
  ArrTop::TorrentSizes::CachedFile.new(name, size)
end

# An episode queue row wired to a torrent (download_client + download_id).
private def episode_row(
  season : Int32? = 1,
  episode : Int32? = 3,
  download_client : String? = "qbit",
  download_id : String? = "HASH1",
  media_kind : Symbol = :episode,
) : ArrTop::QueueRow
  ArrTop::QueueRow.new(
    backend_name: "b", media_kind: media_kind, state: ArrTop::State::Importing,
    size: 6_i64, size_left: 0_i64, import_target: 6_i64,
    title: "Show", season_number: season, episode_number: episode,
    download_client: download_client, download_id: download_id,
  )
end

# A season pack: three episode files in one torrent (one shared hash).
private def pack_files : ArrTop::TorrentSizes::FileList
  [
    cf("Show/The.Show.S01E01.mkv", 1_000_i64),
    cf("Show/The.Show.S01E02.mkv", 2_000_i64),
    cf("Show/The.Show.S01E03.mkv", 3_000_i64),
    cf("Show/The.Show.S01E03.nfo", 5_i64), # sidecar shares E03's token
  ]
end

describe ArrTop::TorrentSizes do
  describe ".disabled" do
    it "is not enabled, warms nothing, and never returns an exact size" do
      sizes = ArrTop::TorrentSizes.disabled
      sizes.enabled?.should be_false
      sizes.warm([episode_row])
      sizes.exact_size(episode_row).should be_nil
    end
  end

  describe "#exact_size (after #warm)" do
    it "returns the exact size of the episode's own file in the pack" do
      fetcher = FakeFetcher.new({"hash1" => pack_files})
      sizes = ArrTop::TorrentSizes.new(fetcher.to_proc, Set{"qbit"})
      sizes.warm([episode_row(episode: 2)])
      sizes.exact_size(episode_row(episode: 2)).should eq(2_000_i64)
      sizes.exact_size(episode_row(episode: 1)).should eq(1_000_i64)
    end

    it "prefers the video over a same-token sidecar (largest match)" do
      fetcher = FakeFetcher.new({"hash1" => pack_files})
      sizes = ArrTop::TorrentSizes.new(fetcher.to_proc, Set{"qbit"})
      sizes.warm([episode_row(episode: 3)])
      # E03.mkv (3000) and E03.nfo (5) both match the token; the larger wins.
      sizes.exact_size(episode_row(episode: 3)).should eq(3_000_i64)
    end

    it "matches a multi-episode file for both of its episodes" do
      multi = [cf("Show/The.Show.S01E03E04.mkv", 4_242_i64)]
      fetcher = FakeFetcher.new({"hash1" => multi})
      sizes = ArrTop::TorrentSizes.new(fetcher.to_proc, Set{"qbit"})
      sizes.warm([episode_row(episode: 3)])
      sizes.exact_size(episode_row(episode: 3)).should eq(4_242_i64)
      sizes.exact_size(episode_row(episode: 4)).should eq(4_242_i64)
    end

    it "returns nil for an episode with no matching file in the torrent" do
      fetcher = FakeFetcher.new({"hash1" => pack_files})
      sizes = ArrTop::TorrentSizes.new(fetcher.to_proc, Set{"qbit"})
      sizes.warm([episode_row(episode: 9)])
      sizes.exact_size(episode_row(episode: 9)).should be_nil
    end

    it "returns nil when the hash was never warmed (uncached)" do
      fetcher = FakeFetcher.new({"hash1" => pack_files})
      sizes = ArrTop::TorrentSizes.new(fetcher.to_proc, Set{"qbit"})
      # No warm at all.
      sizes.exact_size(episode_row).should be_nil
    end

    it "returns nil when the row's download_client isn't configured" do
      fetcher = FakeFetcher.new({"hash1" => pack_files})
      sizes = ArrTop::TorrentSizes.new(fetcher.to_proc, Set{"qbit"})
      other = episode_row(download_client: "deluge")
      sizes.warm([other])
      sizes.exact_size(other).should be_nil
    end

    it "returns nil for a movie row" do
      fetcher = FakeFetcher.new({"hash1" => pack_files})
      sizes = ArrTop::TorrentSizes.new(fetcher.to_proc, Set{"qbit"})
      movie = episode_row(media_kind: :movie, season: nil, episode: nil)
      sizes.warm([movie])
      sizes.exact_size(movie).should be_nil
    end

    it "returns nil when the row lacks season/episode numbers" do
      fetcher = FakeFetcher.new({"hash1" => pack_files})
      sizes = ArrTop::TorrentSizes.new(fetcher.to_proc, Set{"qbit"})
      sizes.warm([episode_row(episode: nil)])
      sizes.exact_size(episode_row(episode: nil)).should be_nil
    end

    it "returns nil when the matching file has a nil size" do
      fetcher = FakeFetcher.new({"hash1" => [cf("Show/The.Show.S01E03.mkv", nil)]})
      sizes = ArrTop::TorrentSizes.new(fetcher.to_proc, Set{"qbit"})
      sizes.warm([episode_row(episode: 3)])
      sizes.exact_size(episode_row(episode: 3)).should be_nil
    end
  end

  describe "#warm (caching)" do
    it "fetches each distinct torrent hash exactly once, even across many rows" do
      fetcher = FakeFetcher.new({"hash1" => pack_files})
      sizes = ArrTop::TorrentSizes.new(fetcher.to_proc, Set{"qbit"})
      rows = [
        episode_row(episode: 1),
        episode_row(episode: 2),
        episode_row(episode: 3),
      ]
      sizes.warm(rows) # first warm: one fetch for the shared hash
      sizes.warm(rows) # second warm: already cached, no fetch
      fetcher.calls["hash1"].should eq(1)
    end

    it "downcases the hash before fetching (qB expects lowercase)" do
      fetcher = FakeFetcher.new({"hash1" => pack_files})
      sizes = ArrTop::TorrentSizes.new(fetcher.to_proc, Set{"qbit"})
      sizes.warm([episode_row(download_id: "HASH1", episode: 1)])
      fetcher.calls["hash1"].should eq(1)
      sizes.exact_size(episode_row(download_id: "HASH1", episode: 1)).should eq(1_000_i64)
    end

    it "does not fetch for an unconfigured client" do
      fetcher = FakeFetcher.new({"hash1" => pack_files})
      sizes = ArrTop::TorrentSizes.new(fetcher.to_proc, Set{"qbit"})
      sizes.warm([episode_row(download_client: "deluge")])
      fetcher.calls.empty?.should be_true
    end

    it "never raises when the fetcher fails, leaving the hash uncached" do
      raising = ArrTop::TorrentSizes::Fetcher.new { |_n, _h| raise "boom" }
      sizes = ArrTop::TorrentSizes.new(raising, Set{"qbit"})
      sizes.warm([episode_row]) # must not raise
      sizes.exact_size(episode_row).should be_nil
    end
  end

  describe "TUI.effective_target with a size service" do
    it "prefers the exact size over the pack-average estimate" do
      fetcher = FakeFetcher.new({"hash1" => pack_files})
      sizes = ArrTop::TorrentSizes.new(fetcher.to_proc, Set{"qbit"})
      # A 3-episode pack of import_target 9000 ⇒ estimate 3000/episode; but the
      # exact E01 file is 1000.
      row = ArrTop::QueueRow.new(
        backend_name: "b", media_kind: :episode, state: ArrTop::State::Importing,
        size: 9_000_i64, size_left: 0_i64, import_target: 9_000_i64,
        title: "Show", season_number: 1, episode_number: 1,
        download_client: "qbit", download_id: "HASH1")
      counts = {"HASH1" => 3}
      sizes.warm([row])
      ArrTop::TUI.effective_target(row, counts, sizes).should eq(1_000_i64)
    end

    it "falls back to the estimate when no exact size is available" do
      sizes = ArrTop::TorrentSizes.disabled
      row = ArrTop::QueueRow.new(
        backend_name: "b", media_kind: :episode, state: ArrTop::State::Importing,
        size: 9_000_i64, size_left: 0_i64, import_target: 9_000_i64,
        title: "Show", season_number: 1, episode_number: 1,
        download_client: "qbit", download_id: "HASH1")
      counts = {"HASH1" => 3}
      # 9000 / 3 = 3000 estimate; unchanged behaviour.
      ArrTop::TUI.effective_target(row, counts, sizes).should eq(3_000_i64)
      ArrTop::TUI.effective_target(row, counts).should eq(3_000_i64)
    end
  end
end
