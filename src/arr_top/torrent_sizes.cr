require "log"
require "qbittorrent"

module ArrTop
  # Optional per-episode exact-size lookup backed by one or more configured
  # download clients (currently qBittorrent).
  #
  # A Sonarr season pack reports only the *whole pack's* size on every episode
  # row — there is no per-episode size in the *arr API — so arrtop otherwise
  # estimates each episode as `pack_total / episode_count` (see
  # `TUI.effective_target`). When a download client is configured, arrtop asks it
  # for the torrent's file list and uses the **real** size of each episode's
  # file as the import target instead.
  #
  # Concurrency (`-Dpreview_mt`): the poller fiber calls `#warm` (the only method
  # that touches the network — it fetches and caches each torrent's file list),
  # while the UI fiber calls `#exact_size` (a pure cache read, never any I/O).
  # The cache is guarded by a `Mutex` so the two fibers never race. `#warm` is
  # fully rescued and NEVER raises, so an unreachable client can't wedge the
  # poller; every uncached/failed lookup falls back to the estimate.
  #
  # Fully optional: build it from `config.download_clients` with `.build`, or get
  # a no-op with `.disabled` (`#exact_size` always nil, `#warm` does nothing).
  class TorrentSizes
    Log = ::Log.for("arrtop.torrent_sizes")

    # One cached torrent file: just the fields size-matching needs (its path
    # within the torrent and its byte size). Torrent file lists never change, so
    # one fetch per torrent hash is cached for the process lifetime.
    record CachedFile, name : String, size : Int64?

    # A torrent's cached file list.
    alias FileList = Array(CachedFile)

    # Fetches a torrent's file list given `(client_name, torrent_hash)`, or `nil`
    # on any failure (unreachable client, hash not found, unknown client). This
    # is the sole network seam: the production fetcher (see `.build`) talks to
    # qBittorrent; tests inject a deterministic/counting fetcher.
    alias Fetcher = Proc(String, String, FileList?)

    # Builds a `TorrentSizes` from the configured *clients* (nil/empty ⇒ a no-op
    # instance). One lazy `QBittorrent::Client` is held per configured client,
    # keyed by its `name`; the fetcher looks the client up by name and calls
    # `torrents/files`, mapping the result to `CachedFile`s and rescuing every
    # failure to `nil` (→ the caller falls back to the estimate).
    def self.build(clients : Array(Config::DownloadClient)?) : TorrentSizes
      qb = {} of String => QBittorrent::Client
      (clients || [] of Config::DownloadClient).each do |client|
        next unless client.type == Config::DownloadClientType::Qbittorrent
        qb[client.name] = QBittorrent::Client.new(client.url, client.username, client.password)
      end

      fetcher = Fetcher.new do |name, hash|
        if client = qb[name]?
          begin
            files = QBittorrent::Api::Torrents.new(client).files(hash)
            files.map { |file| CachedFile.new(file.name || "", file.size) }
          rescue ex
            Log.debug { "qB files(#{hash}) via #{name.inspect} failed: #{ex.message}" }
            nil
          end
        end
      end

      new(fetcher, qb.keys.to_set)
    end

    # A no-op instance: no configured clients, so `#warm` does nothing and
    # `#exact_size` always returns `nil` (every caller falls back to the
    # estimate). Used when `download_clients` is absent from the config.
    def self.disabled : TorrentSizes
      new(Fetcher.new { nil }, Set(String).new)
    end

    # *fetcher* fetches a torrent's file list by `(client_name, hash)`;
    # *client_names* is the set of configured download-client names (a row's
    # `download_client` must be in it to be looked up). Public so specs can inject
    # a fake/counting fetcher with no network.
    def initialize(@fetcher : Fetcher, @client_names : Set(String))
      @cache = {} of String => FileList
      @mutex = Mutex.new
    end

    # Whether any download client is configured (⇒ whether this instance can ever
    # return an exact size).
    def enabled? : Bool
      !@client_names.empty?
    end

    # POLLER-fiber entry point (background): fetch and cache the file list for
    # each distinct torrent among *rows* whose `download_client` matches a
    # configured client and whose hash isn't cached yet. One `files` call returns
    # every file in the torrent, so a whole season pack (all episodes share one
    # `download_id`) costs a single query. Every fetch is rescued; a failure
    # leaves the hash uncached (→ the estimate). NEVER raises into the poller.
    def warm(rows : Array(QueueRow)) : Nil
      return unless enabled?

      # Distinct torrent hashes to consider, each with the client to ask. Keyed by
      # the downcased hash (qB expects lowercase; the *arr may report uppercase).
      pending = {} of String => String
      rows.each do |row|
        client = row.download_client
        id = row.download_id
        next if client.nil? || id.nil?
        next unless @client_names.includes?(client)
        pending[id.downcase] ||= client
      end

      pending.each do |hash, client|
        next if cached?(hash)
        files =
          begin
            @fetcher.call(client, hash)
          rescue ex
            # Backstop: the production fetcher already rescues, but a custom
            # fetcher must never take down the poller either.
            Log.debug { "warm failed for #{hash}: #{ex.message}" }
            nil
          end
        store(hash, files) unless files.nil?
      end
    rescue ex
      # Absolute last resort — `#warm` must never raise into the poller fiber.
      Log.debug { "warm aborted: #{ex.message}" }
    end

    # UI-fiber entry point (render): the exact byte size of *row*'s own episode
    # file, read purely from the cache with **no** network. Returns `nil` — so the
    # caller falls back to the estimate — on any miss: non-episode row, no
    # matching configured client, hash not cached, missing season/episode, no
    # cached file matching the episode's `SxxEyy` token, or a matching file with a
    # nil size. Only episode rows get exact sizes; movies keep their behaviour.
    #
    # Matching reuses the SAME approach as `ImportWatch` (a case-insensitive
    # `S0*<season>(E\d+)*?E0*<episode>(\b|E)` token, tolerant of zero-padding and
    # multi-episode files). When several cached files match (e.g. a `.mkv` beside
    # a same-named `.nfo`), the largest is chosen — the video, not a sidecar.
    def exact_size(row : QueueRow) : Int64?
      return nil unless row.media_kind == :episode
      client = row.download_client
      id = row.download_id
      season = row.season_number
      episode = row.episode_number
      return nil if client.nil? || id.nil? || season.nil? || episode.nil?
      return nil unless @client_names.includes?(client)

      files = cached(id.downcase)
      return nil if files.nil?

      pattern = ImportWatch.episode_pattern(season, episode)
      best : CachedFile? = nil
      files.each do |file|
        next unless pattern.matches?(File.basename(file.name))
        best = file if best.nil? || (file.size || -1_i64) > (best.size || -1_i64)
      end
      best.try(&.size)
    end

    private def cached?(hash : String) : Bool
      @mutex.synchronize { @cache.has_key?(hash) }
    end

    private def cached(hash : String) : FileList?
      @mutex.synchronize { @cache[hash]? }
    end

    private def store(hash : String, files : FileList) : Nil
      @mutex.synchronize { @cache[hash] = files }
    end
  end
end
