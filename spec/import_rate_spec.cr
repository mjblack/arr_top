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

    it "is nil when no bytes gained (a stall)" do
      ArrTop::ImportRateTracker.rate(0_i64, 5.seconds).should be_nil
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
