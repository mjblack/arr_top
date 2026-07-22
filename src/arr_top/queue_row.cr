module ArrTop
  # arrtop's own normalized queue state, ordered so "what's importing" rises to
  # the top of the view. The enum **value is the sort rank** — lower sorts
  # first (`Importing` = 0 … `Unknown` = 5).
  enum State
    Importing     = 0
    ImportPending = 1
    Downloading   = 2
    Failed        = 3
    Queued        = 4
    Unknown       = 5

    # Sort rank; lower rises to the top. Equal to the enum value.
    def rank : Int32
      value
    end

    # Maps a shard `trackedDownloadState` string onto a normalized `State`.
    # Matching is case-insensitive; unknown or nil values become `Unknown`.
    #
    # The shard enum values are: `downloading`, `importBlocked`,
    # `importPending`, `importing`, `imported`, `failedPending`, `failed`,
    # `ignored` (`queued` is accepted too, though it is reported via the queue
    # `status` field rather than `trackedDownloadState`).
    def self.from_tracked_state(str : String?) : State
      return Unknown if str.nil?

      case str.downcase
      when "importing", "imported"
        Importing
      when "importpending", "importblocked"
        ImportPending
      when "downloading"
        Downloading
      when "failed", "failedpending"
        Failed
      when "queued"
        Queued
      else
        Unknown
      end
    end
  end

  # One normalized queue item, in arrtop's own vocabulary so the UI/poller never
  # touch the underlying `sonarr`/`radarr` model types.
  #
  # `dest_folder` is the media folder the import lands in (Sonarr: `series.path`,
  # Radarr: `movie.path`); the later disk-watch phase watches it for `Importing`
  # rows. `import_target` is the copy's final size (== `size`) so that phase can
  # compute `import% = file_bytes / import_target`. This layer does **not**
  # compute import progress — that needs disk access and lands later.
  struct QueueRow
    # Which *arr this row came from (the configured backend name).
    getter backend_name : String

    # `:episode` (Sonarr) or `:movie` (Radarr).
    getter media_kind : Symbol

    # Sonarr episode identity, used to match this row's own on-disk file (a season
    # pack lands N episodes in one series folder, so the import watch needs the
    # season+episode to find *this* episode's file). `nil` for movies / when the
    # *arr did not embed the episode.
    getter season_number : Int32?
    getter episode_number : Int32?

    # Whether this episode already has an imported file on disk (Sonarr's
    # `episodeHasFile`). Used to reclassify a "still importing" season-pack row as
    # done (100%) even when filename matching can't confirm it. `nil` for movies.
    getter episode_has_file : Bool?

    # The release/torrent name (what the download client sees).
    getter title : String?

    # The media's display name — the movie or series title — distinct from the
    # release `title`. `nil` when the *arr did not embed the movie/series.
    getter media_name : String?

    getter state : State

    # True when the *arr's `trackedDownloadStatus` signals a warning or error.
    getter? warning : Bool

    # Total download size and bytes remaining (shards report these as `Float64?`;
    # nil becomes 0).
    getter size : Int64
    getter size_left : Int64

    # Human-readable remaining time as reported by the *arr (e.g. `"00:12:34"`).
    getter timeleft : String?

    # Estimated completion time (`estimatedCompletionTime`).
    getter eta : Time?

    getter protocol : String?
    getter download_client : String?
    getter download_id : String?
    getter indexer : String?

    # Destination media folder to watch for import progress. Populated for every
    # row where known; the import-watch phase uses it only for `Importing`.
    getter dest_folder : String?

    # The copy's final size (== `size`), exposed so the future disk-watch can
    # compute import percent as `file_bytes / import_target`.
    getter import_target : Int64

    def initialize(@backend_name : String, @media_kind : Symbol, @state : State,
                   @size : Int64, @size_left : Int64, @import_target : Int64,
                   @title : String? = nil, @media_name : String? = nil,
                   @warning : Bool = false,
                   @timeleft : String? = nil, @eta : Time? = nil,
                   @protocol : String? = nil, @download_client : String? = nil,
                   @download_id : String? = nil, @indexer : String? = nil,
                   @dest_folder : String? = nil,
                   @season_number : Int32? = nil, @episode_number : Int32? = nil,
                   @episode_has_file : Bool? = nil)
    end

    # Download progress as a 0–100 percentage; 0 when the total size is unknown.
    def download_percent : Float64
      size > 0 ? (size - size_left).to_f / size * 100 : 0.0
    end
  end
end
