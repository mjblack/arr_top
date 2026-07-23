require "./spec_helper"

private def progress(bytes : Int64, target : Int64 = 1000_i64) : ArrTop::ImportProgress
  ArrTop::ImportProgress.new("/data/f.mkv", bytes: bytes, target: target)
end

describe ArrTop::ImportRateTracker do
  describe ".rate" do
    it "is bytes gained over seconds elapsed" do
      ArrTop::ImportRateTracker.rate(500_i64, 5.seconds).should eq(100.0)
    end

    it "is nil when no time elapsed" do
      ArrTop::ImportRateTracker.rate(500_i64, Time::Span.zero).should be_nil
    end

    it "is 0.0 when no bytes gained but time elapsed (a measured stall)" do
      ArrTop::ImportRateTracker.rate(0_i64, 5.seconds).should eq(0.0)
    end

    it "is nil when bytes decreased (a reset)" do
      ArrTop::ImportRateTracker.rate(-100_i64, 5.seconds).should be_nil
    end
  end

  describe ".eta_from" do
    it "is remaining ÷ rate from raw deltas" do
      # 200 bytes gained over 2s => 100 B/s; 700 remaining => 7s.
      ArrTop::ImportRateTracker.eta_from(
        remaining_bytes: 700_i64, delta_bytes: 200_i64, delta: 2.seconds
      ).should eq(7.seconds)
    end

    it "is nil on a zero-time delta (unknown rate)" do
      ArrTop::ImportRateTracker.eta_from(
        remaining_bytes: 700_i64, delta_bytes: 200_i64, delta: Time::Span.zero
      ).should be_nil
    end

    it "is nil on a stall (no bytes gained)" do
      ArrTop::ImportRateTracker.eta_from(
        remaining_bytes: 700_i64, delta_bytes: 0_i64, delta: 2.seconds
      ).should be_nil
    end

    it "is nil when the file shrank (reset)" do
      ArrTop::ImportRateTracker.eta_from(
        remaining_bytes: 700_i64, delta_bytes: -300_i64, delta: 2.seconds
      ).should be_nil
    end

    it "is nil once nothing remains" do
      ArrTop::ImportRateTracker.eta_from(
        remaining_bytes: 0_i64, delta_bytes: 200_i64, delta: 2.seconds
      ).should be_nil
    end
  end

  describe "#measure" do
    it "returns nil rate and eta on the first sample (needs two)" do
      tracker = ArrTop::ImportRateTracker.new
      result = tracker.measure("/data", progress(100_i64))
      result[:rate].should be_nil
      result[:eta].should be_nil
    end

    it "exposes a positive rate and eta once two live samples exist" do
      tracker = ArrTop::ImportRateTracker.new
      tracker.measure("/data", progress(100_i64))
      # The monotonic clock advances a tiny amount between calls, so a real (if
      # large) rate/ETA is produced; only their signs are deterministic here.
      result = tracker.measure("/data", progress(300_i64))
      result[:rate].try(&.positive?).should be_true
      result[:eta].try(&.positive?).should be_true
    end

    it "reports a 0.0 rate (not nil) when the copy stalled between samples" do
      # Same byte count twice => no growth, but the monotonic clock advanced, so
      # this is a *measured stall*: rate is 0.0 (kept truthy so the header still
      # shows `↓ 0 B/s` instead of blanking), and the ETA is nil (no divide by 0).
      tracker = ArrTop::ImportRateTracker.new
      tracker.measure("/data", progress(200_i64))
      result = tracker.measure("/data", progress(200_i64))
      result[:rate].should eq(0.0)
      result[:eta].should be_nil
    end

    it "resets to a nil rate when the watched file shrinks" do
      tracker = ArrTop::ImportRateTracker.new
      tracker.measure("/data", progress(500_i64))
      tracker.measure("/data", progress(100_i64))[:rate].should be_nil
    end

    it "records only one sample per call (#eta delegates without double-sampling)" do
      tracker = ArrTop::ImportRateTracker.new
      # First #eta seeds the only sample; a second call then has a prior to
      # compare against and yields a span — proving #eta records exactly once.
      tracker.eta("/data", progress(100_i64)).should be_nil
      tracker.eta("/data", progress(300_i64)).try(&.positive?).should be_true
    end

    # Regression for the "118 GB/s" bug: a Sonarr season pack puts every episode
    # in ONE folder, so folder-keying compared different episodes' byte counts
    # frame-to-frame and manufactured an astronomical rate. Keying by FILE gives
    # each episode its own history.
    it "keys by the file, so two different pack files measured back-to-back don't cross-contaminate" do
      tracker = ArrTop::ImportRateTracker.new
      gb = 1024_i64 * 1024 * 1024
      # Same folder, DIFFERENT files/bytes, one frame — ascending bytes so a folder
      # key WOULD have produced a huge bogus positive rate on the second call.
      e01 = ArrTop::ImportProgress.new("/tv/Show/S01E01.mkv", 1_i64 * gb, 6_i64 * gb)
      e02 = ArrTop::ImportProgress.new("/tv/Show/S01E02.mkv", 5_i64 * gb, 6_i64 * gb)
      # Each is the FIRST sample for its own key ⇒ both nil (no bogus rate).
      tracker.measure(e01.file, e01)[:rate].should be_nil
      tracker.measure(e02.file, e02)[:rate].should be_nil
    end

    it "still yields a real positive rate for a single file sampled twice as it grows" do
      tracker = ArrTop::ImportRateTracker.new
      gb = 1024_i64 * 1024 * 1024
      f = "/tv/Show/S01E02.mkv"
      tracker.measure(f, ArrTop::ImportProgress.new(f, 1_i64 * gb, 6_i64 * gb))[:rate].should be_nil
      # Second sample of the SAME file with more bytes ⇒ a positive (growing) rate.
      # (The exact bytes/sec math is covered deterministically by the .rate specs.)
      result = tracker.measure(f, ArrTop::ImportProgress.new(f, 2_i64 * gb, 6_i64 * gb))
      result[:rate].try(&.positive?).should be_true
    end
  end

  describe "#eta" do
    it "returns nil on the first sample (needs two)" do
      tracker = ArrTop::ImportRateTracker.new
      tracker.eta("/data", progress(100_i64)).should be_nil
    end

    it "produces a positive span once two live samples exist" do
      tracker = ArrTop::ImportRateTracker.new
      tracker.eta("/data", progress(100_i64)).should be_nil
      # The monotonic clock advances a tiny amount between calls, so a real (if
      # large) ETA is produced; only its sign is deterministic here. The exact
      # timing math is covered by the .rate/.eta_from specs above.
      eta = tracker.eta("/data", progress(300_i64))
      # Non-nil and strictly positive (nil would make `try` yield nil, not true).
      eta.try(&.positive?).should be_true
    end

    it "returns nil when the watched file shrinks (reset)" do
      tracker = ArrTop::ImportRateTracker.new
      tracker.eta("/data", progress(500_i64))
      tracker.eta("/data", progress(100_i64)).should be_nil
    end

    it "tracks destinations independently" do
      tracker = ArrTop::ImportRateTracker.new
      tracker.eta("/a", progress(100_i64)).should be_nil
      # /b's first sample must not borrow /a's history.
      tracker.eta("/b", progress(100_i64)).should be_nil
    end
  end
end
