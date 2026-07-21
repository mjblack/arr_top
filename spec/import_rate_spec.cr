require "./spec_helper"

private def progress(bytes : Int64, target : Int64 = 1000_i64) : ArrTop::ImportProgress
  ArrTop::ImportProgress.new("/data/f.mkv", bytes: bytes, target: target)
end

describe ArrTop::ImportRateTracker do
  describe "#eta" do
    it "returns nil on the first sample" do
      tracker = ArrTop::ImportRateTracker.new
      tracker.eta("/data", progress(100_i64), now: 0.seconds).should be_nil
    end

    it "computes remaining/rate from two samples with injected times" do
      tracker = ArrTop::ImportRateTracker.new
      # 100 bytes at t=0, 300 bytes at t=2s => 100 bytes/sec.
      tracker.eta("/data", progress(100_i64, 1000_i64), now: 0.seconds).should be_nil
      eta = tracker.eta("/data", progress(300_i64, 1000_i64), now: 2.seconds)
      # remaining = 1000 - 300 = 700; rate = 200/2 = 100 B/s => 7s.
      eta.should eq(7.seconds)
    end

    it "returns nil when the file shrinks (reset)" do
      tracker = ArrTop::ImportRateTracker.new
      tracker.eta("/data", progress(500_i64), now: 0.seconds)
      tracker.eta("/data", progress(100_i64), now: 1.seconds).should be_nil
    end

    it "returns nil on a stall (no bytes gained)" do
      tracker = ArrTop::ImportRateTracker.new
      tracker.eta("/data", progress(200_i64), now: 0.seconds)
      tracker.eta("/data", progress(200_i64), now: 1.seconds).should be_nil
    end

    it "returns nil once the target is reached" do
      tracker = ArrTop::ImportRateTracker.new
      tracker.eta("/data", progress(500_i64, 1000_i64), now: 0.seconds)
      tracker.eta("/data", progress(1000_i64, 1000_i64), now: 1.seconds).should be_nil
    end

    it "tracks destinations independently" do
      tracker = ArrTop::ImportRateTracker.new
      tracker.eta("/a", progress(100_i64, 1000_i64), now: 0.seconds).should be_nil
      # /b's first sample must not borrow /a's.
      tracker.eta("/b", progress(100_i64, 1000_i64), now: 2.seconds).should be_nil
      tracker.eta("/a", progress(200_i64, 1000_i64), now: 1.seconds).should eq(8.seconds)
    end
  end

  describe "#rate" do
    it "is bytes gained over seconds elapsed" do
      tracker = ArrTop::ImportRateTracker.new
      tracker.rate(0_i64, 0.seconds, 500_i64, 5.seconds).should eq(100.0)
    end

    it "is nil when no time elapsed" do
      tracker = ArrTop::ImportRateTracker.new
      tracker.rate(0_i64, 2.seconds, 500_i64, 2.seconds).should be_nil
    end

    it "is nil when no bytes gained" do
      tracker = ArrTop::ImportRateTracker.new
      tracker.rate(500_i64, 0.seconds, 500_i64, 5.seconds).should be_nil
    end
  end
end
