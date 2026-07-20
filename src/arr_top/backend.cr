module ArrTop
  # Abstraction over an *arr instance (Sonarr or Radarr). Concrete backends wrap
  # the corresponding client shard and expose their download queue as normalized
  # `QueueRow`s so the `Poller`/UI never touch the underlying model types.
  #
  # Network errors are **not** swallowed here — a failed request raises the
  # shard's `ApiError`; the `Poller` decides per-backend how to handle it.
  abstract class Backend
    # Human-readable backend name (from config).
    abstract def name : String

    # The backend's current download queue as normalized rows.
    abstract def rows : Array(QueueRow)
  end
end
