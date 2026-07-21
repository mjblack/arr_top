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
  # Deltas use `Time.monotonic`, which never jumps backward on a clock change.
  # The `now` argument is injectable so the calculation is unit-testable.
  class ImportRateTracker
    # One reading: bytes seen so far and the monotonic instant it was taken.
    record Sample, bytes : Int64, at : Time::Span

    def initialize
      @samples = {} of String => Sample
    end

    # The estimated time remaining for the copy at *dest_folder*, or `nil` when
    # it cannot be computed yet: fewer than two samples, no measurable time or
    # byte gain between them (a stall), the file shrank (reset), or the target is
    # already reached. Records *progress* as the latest sample on every call.
    def eta(dest_folder : String, progress : ImportProgress, now : Time::Span = Time.monotonic) : Time::Span?
      previous = @samples[dest_folder]?
      @samples[dest_folder] = Sample.new(progress.bytes, now)

      return nil if previous.nil?
      return nil if progress.bytes < previous.bytes # file replaced/reset

      remaining = progress.target - progress.bytes
      return nil if remaining <= 0

      rate = rate(previous.bytes, previous.at, progress.bytes, now)
      return nil if rate.nil? || rate <= 0

      (remaining.to_f / rate).seconds
    end

    # Pure bytes/sec between two samples, or `nil` when time did not advance or no
    # bytes were gained (a stall — treated as "unknown", not "infinite").
    def rate(prev_bytes : Int64, prev_at : Time::Span, curr_bytes : Int64, curr_at : Time::Span) : Float64?
      elapsed = (curr_at - prev_at).total_seconds
      return nil if elapsed <= 0
      gained = curr_bytes - prev_bytes
      return nil if gained <= 0
      gained.to_f / elapsed
    end
  end
end
