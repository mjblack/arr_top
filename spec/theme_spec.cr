require "./spec_helper"

private def row(state : ArrTop::State, warning : Bool = false) : ArrTop::QueueRow
  ArrTop::QueueRow.new(
    backend_name: "b", media_kind: :movie, state: state,
    size: 0_i64, size_left: 0_i64, import_target: 0_i64, warning: warning)
end

# Sets NO_COLOR for the duration of *block*, restoring its prior value.
private def with_no_color(value : String?, &)
  prev = ENV["NO_COLOR"]?
  if value
    ENV["NO_COLOR"] = value
  else
    ENV.delete("NO_COLOR")
  end
  begin
    yield
  ensure
    prev ? (ENV["NO_COLOR"] = prev) : ENV.delete("NO_COLOR")
  end
end

describe ArrTop::Theme do
  describe "#colorize" do
    it "wraps text in the code and a reset when enabled" do
      ArrTop::Theme.default.colorize("hi", "\e[31m").should eq("\e[31mhi\e[0m")
    end

    it "passes text through untouched when disabled" do
      ArrTop::Theme.disabled.colorize("hi", "\e[31m").should eq("hi")
    end

    it "passes text through for an empty code even when enabled" do
      ArrTop::Theme.default.colorize("hi", "").should eq("hi")
    end
  end

  describe ".detect" do
    it "is disabled for a non-tty (so no ANSI leaks into a pipe/file)" do
      with_no_color(nil) do
        ArrTop::Theme.detect(tty: false).enabled?.should be_false
      end
    end

    it "is enabled for a tty when NO_COLOR is unset" do
      with_no_color(nil) do
        ArrTop::Theme.detect(tty: true).enabled?.should be_true
      end
    end

    it "is disabled for a tty when NO_COLOR is set" do
      with_no_color("1") do
        ArrTop::Theme.detect(tty: true).enabled?.should be_false
      end
    end
  end

  describe "#status_code" do
    it "colours each state and forces warnings/failures to red" do
      t = ArrTop::Theme.default
      t.status_code(row(ArrTop::State::Importing)).should eq(t.status_importing)
      t.status_code(row(ArrTop::State::ImportPending)).should eq(t.status_pending)
      t.status_code(row(ArrTop::State::Downloading)).should eq(t.status_downloading)
      t.status_code(row(ArrTop::State::Queued)).should eq(t.status_queued)
      t.status_code(row(ArrTop::State::Unknown)).should eq(t.status_unknown)
      t.status_code(row(ArrTop::State::Failed)).should eq(t.status_failed)
      # A warning flag on an otherwise-non-red state still renders red.
      t.status_code(row(ArrTop::State::Downloading, warning: true)).should eq(t.status_failed)
    end

    it "leaves Queued with the terminal default (empty code)" do
      ArrTop::Theme.default.status_queued.should eq("")
    end
  end

  describe "bar glyphs" do
    it "default both filled and empty cells to the full block" do
      t = ArrTop::Theme.default
      t.bar_filled_glyph.should eq("█")
      t.bar_empty_glyph.should eq("█")
    end
  end
end
