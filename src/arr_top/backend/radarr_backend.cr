require "radarr"

module ArrTop
  # `Backend` backed by the `radarr` shard. Wraps a `Radarr::Client` and maps
  # Radarr's queue records onto normalized `QueueRow`s. The queue is movie-based,
  # so `media_kind` is `:movie` and `dest_folder` comes from the embedded movie's
  # `path`.
  #
  # Network errors are not swallowed: a failed Radarr request raises
  # `Radarr::ApiError` for the caller (the `Poller`) to handle.
  class RadarrBackend < Backend
    # Page size used when walking the (paged) queue endpoint.
    QUEUE_PAGE_SIZE = 100

    getter name : String

    def initialize(@name : String, url : String, api_key : String)
      @client = Radarr::Client.new(url, api_key)
    end

    # Fetches the full queue, following paging until every record is collected.
    # `include_movie: true` so `movie.path` is available for `dest_folder`.
    def rows : Array(QueueRow)
      api = Radarr::Api::Queue.new(@client)
      result = [] of QueueRow
      page = 1

      loop do
        resource = api.list(page: page, page_size: QUEUE_PAGE_SIZE, include_movie: true)
        break if resource.nil?

        records = resource.records
        records.each { |record| result << RadarrBackend.map_row(record, @name) }

        total = resource.total_records
        break if records.empty?
        break if total && result.size >= total
        break if records.size < QUEUE_PAGE_SIZE

        page += 1
      end

      result
    end

    # Pure mapping seam: turns a Radarr queue record into a `QueueRow`.
    def self.map_row(record : Radarr::Model::QueueResource, backend_name : String) : QueueRow
      size = to_i64(record.size)
      QueueRow.new(
        backend_name: backend_name,
        media_kind: :movie,
        state: State.from_tracked_state(record.tracked_download_state.try(&.to_radarr_value)),
        size: size,
        size_left: to_i64(record.sizeleft),
        import_target: size,
        title: record.title,
        media_name: record.movie.try(&.title),
        warning: warning?(record.tracked_download_status),
        timeleft: record.timeleft,
        eta: record.estimated_completion_time,
        protocol: record.protocol.try(&.to_radarr_value),
        download_client: record.download_client,
        download_id: record.download_id,
        indexer: record.indexer,
        dest_folder: record.movie.try(&.path),
      )
    end

    # True when the tracked download status signals a warning or error.
    def self.warning?(status : Radarr::TrackedDownloadStatus?) : Bool
      case status
      when Radarr::TrackedDownloadStatus::Warning, Radarr::TrackedDownloadStatus::Error
        true
      else
        false
      end
    end

    # Converts the shard's `Float64?` byte counts to `Int64` (nil → 0).
    def self.to_i64(value : Float64?) : Int64
      value.nil? ? 0_i64 : value.to_i64
    end
  end
end
