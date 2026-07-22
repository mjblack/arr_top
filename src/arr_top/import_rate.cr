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
  # State is keyed by `dest_folder` (one copy in flight per destination). It
  # returns `nil` until it has two samples, and resets (nil) when the watched
  # file shrinks — a new/replaced file — so a stale rate is never shown.
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

    # Records one sample for *dest_folder* and returns both the current copy
    # **rate** (bytes/sec) and the **ETA** from that single update — so a caller
    # that wants both (the per-row bar's ETA *and* the header's aggregate speed)
    # pays for only one sample per frame, not two.
    #
    # Both are `nil` until a second sample exists, and both reset to `nil` on a
    # stall (no gain), a zero-time delta, or a shrunk file. The ETA is
    # additionally `nil` once nothing remains to copy.
    def measure(dest_folder : String, progress : ImportProgress) : {rate: Float64?, eta: Time::Span?}
      now = Time.instant
      previous = @samples[dest_folder]?
      @samples[dest_folder] = Sample.new(progress.bytes, now)

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

    # The estimated time remaining for the copy at *dest_folder*, or `nil` when
    # it cannot be computed yet: fewer than two samples, no measurable time or
    # byte gain between them (a stall), the file shrank (reset), or the target is
    # already reached. Records the latest sample on every call. Delegates to
    # `#measure` so it never double-samples.
    def eta(dest_folder : String, progress : ImportProgress) : Time::Span?
      measure(dest_folder, progress)[:eta]
    end

    # Pure ETA from raw deltas: `remaining_bytes ÷ rate`, or `nil` when the rate
    # is unknown (stall / no time elapsed / file reset) or nothing remains.
    def self.eta_from(remaining_bytes : Int64, delta_bytes : Int64, delta : Time::Span) : Time::Span?
      return nil if remaining_bytes <= 0
      bytes_per_second = rate(delta_bytes, delta)
      return nil if bytes_per_second.nil?
      (remaining_bytes.to_f / bytes_per_second).seconds
    end

    # Pure bytes/sec from a byte delta over a time delta, or `nil` when time did
    # not advance or no bytes were gained (a stall or a reset — treated as
    # "unknown", not "infinite").
    def self.rate(delta_bytes : Int64, delta : Time::Span) : Float64?
      seconds = delta.total_seconds
      return nil if seconds <= 0
      return nil if delta_bytes <= 0
      delta_bytes.to_f / seconds
    end
  end
end
