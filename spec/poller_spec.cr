require "./spec_helper"

# A fake backend that returns canned rows or raises, so the poller's collect /
# sort / error-handling can be exercised offline.
private class FakeBackend < ArrTop::Backend
  getter name : String

  def initialize(@name : String, @rows : Array(ArrTop::QueueRow), @error : String? = nil)
  end

  def rows : Array(ArrTop::QueueRow)
    if err = @error
      raise err
    end
    @rows
  end
end

private def row(state : ArrTop::State, title : String, size : Int64 = 1000_i64,
                size_left : Int64 = 0_i64) : ArrTop::QueueRow
  ArrTop::QueueRow.new(
    backend_name: "fake", media_kind: :episode, state: state,
    size: size, size_left: size_left, import_target: size, title: title)
end

describe ArrTop::Poller do
  describe "#rows" do
    it "sorts by State rank so Importing rows come first" do
      backend = FakeBackend.new("a", [
        row(ArrTop::State::Queued, "q"),
        row(ArrTop::State::Downloading, "d"),
        row(ArrTop::State::Importing, "i"),
        row(ArrTop::State::ImportPending, "p"),
      ])

      states = ArrTop::Poller.new([backend] of ArrTop::Backend).rows.map(&.state)
      states.should eq([
        ArrTop::State::Importing,
        ArrTop::State::ImportPending,
        ArrTop::State::Downloading,
        ArrTop::State::Queued,
      ])
    end

    it "breaks State ties by descending download percent, then title" do
      backend = FakeBackend.new("a", [
        row(ArrTop::State::Downloading, "low", 1000_i64, 900_i64),  # 10%
        row(ArrTop::State::Downloading, "high", 1000_i64, 100_i64), # 90%
        row(ArrTop::State::Downloading, "mid", 1000_i64, 500_i64),  # 50%
      ])

      titles = ArrTop::Poller.new([backend] of ArrTop::Backend).rows.map(&.title)
      titles.should eq(["high", "mid", "low"])
    end

    it "merges rows from multiple backends" do
      a = FakeBackend.new("a", [row(ArrTop::State::Downloading, "a1")])
      b = FakeBackend.new("b", [row(ArrTop::State::Importing, "b1")])

      poller = ArrTop::Poller.new([a, b] of ArrTop::Backend)
      poller.rows.map(&.title).should eq(["b1", "a1"])
      poller.errors.should be_empty
    end

    it "skips a failing backend and records it in #errors while keeping the rest" do
      good = FakeBackend.new("good", [row(ArrTop::State::Importing, "ok")])
      bad = FakeBackend.new("bad", [] of ArrTop::QueueRow, error: "connection refused")

      poller = ArrTop::Poller.new([good, bad] of ArrTop::Backend)
      rows = poller.rows

      rows.map(&.title).should eq(["ok"])
      poller.errors.has_key?("bad").should be_true
      poller.errors["bad"].should eq("connection refused")
      poller.errors.has_key?("good").should be_false
    end

    it "recomputes #errors on each call" do
      bad = FakeBackend.new("bad", [] of ArrTop::QueueRow, error: "boom")
      poller = ArrTop::Poller.new([bad] of ArrTop::Backend)
      poller.rows
      poller.errors.size.should eq(1)
      # Same call again: errors are cleared then repopulated, not accumulated.
      poller.rows
      poller.errors.size.should eq(1)
    end
  end
end
