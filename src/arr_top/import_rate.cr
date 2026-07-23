module ArrTop
  # Best-effort import ETA: estimates how long an in-progress copy has left by
  # measuring how fast the destination file is growing between two `ImportWatch`
  # readings.
  #
  # The *arr API gives no copy progress and no copy rate for an import, and the
  # download `timeleft`/`eta` no longer apply once the download is done. So the
  # ETA is derived here from arrtop's own successive disk readings: bytes gained
  # ÷ wall time between samples = bytes/sec, and `remaining ÷ rate` = the ETA.
  #
  # State is keyed by an opaque per-copy *key* — the destination **file path**
  # (`ImportProgress#file`), NOT the folder. A Sonarr season pack lands every
  # episode in ONE folder, so a folder key would compare *different* episodes'
  # byte counts frame-to-frame and manufacture an astronomical bogus rate; keying
  # by file gives each episode its own sample history, so only a genuinely
  # growing file yields a positive rate. It returns `nil` until it has two
  # samples for a key, and resets (nil) when the watched file shrinks — a
  # new/replaced file — so a stale rate is never shown.
  #
  # Timing uses `Time.instant` (a monotonic clock that never jumps backward). The
  # instant-based bookkeeping stays inside `#eta`; the actual math lives in the
  # pure class methods `.rate`/`.eta_from`, which take plain `Int64`/`Time::Span`
  # deltas so they can be unit-tested without fabricating clock readings.
  class ImportRateTracker
    # One reading: bytes seen so far and the monotonic instant it was taken.
    record Sample, bytes : Int64, at : Time::Instant

    def initialize
      @samples = {} of String => Sample
    end

    # Records one sample under *key* (the copy's destination file path) and
    # returns both the current copy **rate** (bytes/sec) and the **ETA** from that
    # single update — so a caller that wants both (the per-row bar's ETA *and* the
    # header's aggregate speed) pays for only one sample per frame, not two.
    #
    # Both are `nil` until a second sample exists **for that key**, and both reset
    # to `nil` on a zero-time delta or a shrunk file. A no-growth interval is a
    # *measured stall*: the **rate** reports `0.0` (a copy that isn't advancing,
    # not "unknown"), while the **eta** stays `nil` (nothing divides by a 0 rate).
    # The ETA is additionally `nil` once nothing remains to copy.
    def measure(key : String, progress : ImportProgress) : {rate: Float64?, eta: Time::Span?}
      now = Time.instant
      previous = @samples[key]?
      @samples[key] = Sample.new(progress.bytes, now)

      return {rate: nil, eta: nil} if previous.nil?

      delta_bytes = progress.bytes - previous.bytes
      delta = now - previous.at
      rate = ImportRateTracker.rate(delta_bytes, delta)
      eta = ImportRateTracker.eta_from(
        remaining_bytes: progress.target - progress.bytes,
        delta_bytes: delta_bytes,
        delta: delta,
      )
      {rate: rate, eta: eta}
    end

    # The estimated time remaining for the copy under *key* (its destination file
    # path), or `nil` when it cannot be computed yet: fewer than two samples, no
    # measurable time or byte gain between them (a stall), the file shrank
    # (reset), or the target is already reached. Records the latest sample on
    # every call. Delegates to `#measure` so it never double-samples.
    def eta(key : String, progress : ImportProgress) : Time::Span?
      measure(key, progress)[:eta]
    end

    # Pure ETA from raw deltas: `remaining_bytes ÷ rate`, or `nil` when the rate
    # is unknown or zero (a stall, no time elapsed, or a file reset) or nothing
    # remains. A 0-rate stall gives NO ETA — we never divide by zero (Infinity).
    def self.eta_from(remaining_bytes : Int64, delta_bytes : Int64, delta : Time::Span) : Time::Span?
      return nil if remaining_bytes <= 0
      bytes_per_second = rate(delta_bytes, delta)
      return nil if bytes_per_second.nil? || bytes_per_second <= 0.0
      (remaining_bytes.to_f / bytes_per_second).seconds
    end

    # Pure bytes/sec from a byte delta over a time delta. A no-growth interval
    # (`delta_bytes == 0`) with elapsed time is a *measured stall* and reports
    # `0.0`, not nil. Returns `nil` only when time did not advance
    # (`seconds <= 0`) or the file shrank/reset (`delta_bytes < 0`) — those stay
    # "unknown".
    def self.rate(delta_bytes : Int64, delta : Time::Span) : Float64?
      seconds = delta.total_seconds
      return nil if seconds <= 0
      return nil if delta_bytes < 0
      delta_bytes.to_f / seconds
    end
  end
end
