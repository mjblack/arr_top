require "./spec_helper"

describe ArrTop::State do
  describe ".from_tracked_state" do
    it "maps each shard tracked-state string to a normalized State" do
      ArrTop::State.from_tracked_state("importing").should eq(ArrTop::State::Importing)
      ArrTop::State.from_tracked_state("imported").should eq(ArrTop::State::Importing)
      ArrTop::State.from_tracked_state("importPending").should eq(ArrTop::State::ImportPending)
      ArrTop::State.from_tracked_state("importBlocked").should eq(ArrTop::State::ImportPending)
      ArrTop::State.from_tracked_state("downloading").should eq(ArrTop::State::Downloading)
      ArrTop::State.from_tracked_state("failed").should eq(ArrTop::State::Failed)
      ArrTop::State.from_tracked_state("failedPending").should eq(ArrTop::State::Failed)
      ArrTop::State.from_tracked_state("queued").should eq(ArrTop::State::Queued)
    end

    it "matches case-insensitively" do
      ArrTop::State.from_tracked_state("Importing").should eq(ArrTop::State::Importing)
      ArrTop::State.from_tracked_state("DOWNLOADING").should eq(ArrTop::State::Downloading)
    end

    it "maps unknown and nil values to Unknown" do
      ArrTop::State.from_tracked_state("warning").should eq(ArrTop::State::Unknown)
      ArrTop::State.from_tracked_state("ignored").should eq(ArrTop::State::Unknown)
      ArrTop::State.from_tracked_state("").should eq(ArrTop::State::Unknown)
      ArrTop::State.from_tracked_state(nil).should eq(ArrTop::State::Unknown)
    end
  end

  describe "#rank" do
    it "orders Importing < ImportPending < Downloading < Failed < Queued < Unknown" do
      ranks = [
        ArrTop::State::Importing,
        ArrTop::State::ImportPending,
        ArrTop::State::Downloading,
        ArrTop::State::Failed,
        ArrTop::State::Queued,
        ArrTop::State::Unknown,
      ].map(&.rank)

      ranks.should eq(ranks.sort)
      ArrTop::State::Importing.rank.should be < ArrTop::State::ImportPending.rank
      ArrTop::State::ImportPending.rank.should be < ArrTop::State::Downloading.rank
    end
  end
end

describe ArrTop::QueueRow do
  describe "#download_percent" do
    it "computes (size - size_left) / size * 100" do
      row = ArrTop::QueueRow.new(
        backend_name: "s", media_kind: :episode, state: ArrTop::State::Downloading,
        size: 1000_i64, size_left: 250_i64, import_target: 1000_i64)
      row.download_percent.should eq(75.0)
    end

    it "is 0 when size is unknown (0)" do
      row = ArrTop::QueueRow.new(
        backend_name: "s", media_kind: :episode, state: ArrTop::State::Queued,
        size: 0_i64, size_left: 0_i64, import_target: 0_i64)
      row.download_percent.should eq(0.0)
    end
  end
end
