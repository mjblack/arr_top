require "sonarr"

module ArrTop
  # `Backend` backed by the `sonarr` shard. Wraps a `Sonarr::Client` and maps
  # Sonarr's queue records onto normalized `QueueRow`s. The queue is
  # episode-based, so `media_kind` is `:episode` and `dest_folder` comes from the
  # embedded series' `path`.
  #
  # Network errors are not swallowed: a failed Sonarr request raises
  # `Sonarr::ApiError` for the caller (the `Poller`) to handle.
  class SonarrBackend < Backend
    # Page size used when walking the (paged) queue endpoint.
    QUEUE_PAGE_SIZE = 100

    getter name : String

    def initialize(@name : String, url : String, api_key : String)
      @client = Sonarr::Client.new(url, api_key)
    end

    # Fetches the full queue, following paging until every record is collected.
    # `include_series: true` so `series.path` is available for `dest_folder`.
    def rows : Array(QueueRow)
      api = Sonarr::Api::Queue.new(@client)
      result = [] of QueueRow
      page = 1

      loop do
        resource = api.list(page: page, page_size: QUEUE_PAGE_SIZE, include_series: true)
        break if resource.nil?

        records = resource.records
        records.each { |record| result << SonarrBackend.map_row(record, @name) }

        total = resource.total_records
        break if records.empty?
        break if total && result.size >= total
        break if records.size < QUEUE_PAGE_SIZE

        page += 1
      end

      result
    end

    # Pure mapping seam: turns a Sonarr queue record into a `QueueRow`.
    def self.map_row(record : Sonarr::Model::QueueResource, backend_name : String) : QueueRow
      size = to_i64(record.size)
      QueueRow.new(
        backend_name: backend_name,
        media_kind: :episode,
        state: State.from_tracked_state(record.tracked_download_state.try(&.to_sonarr_value)),
        size: size,
        size_left: to_i64(record.sizeleft),
        import_target: size,
        title: record.title,
        media_name: record.series.try(&.title),
        warning: warning?(record.tracked_download_status),
        timeleft: record.timeleft,
        eta: record.estimated_completion_time,
        protocol: record.protocol.try(&.to_sonarr_value),
        download_client: record.download_client,
        download_id: record.download_id,
        indexer: record.indexer,
        dest_folder: record.series.try(&.path),
      )
    end

    # True when the tracked download status signals a warning or error.
    def self.warning?(status : Sonarr::TrackedDownloadStatus?) : Bool
      case status
      when Sonarr::TrackedDownloadStatus::Warning, Sonarr::TrackedDownloadStatus::Error
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
