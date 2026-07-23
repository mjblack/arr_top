require "./spec_helper"

# A minimal QueueRow builder so tests can vary just the fields render cares about.
private def build_row(
  state : ArrTop::State,
  title : String? = "Some.Torrent.Name",
  media_name : String? = "Media Name",
  size : Int64 = 1000_i64,
  size_left : Int64 = 0_i64,
  warning : Bool = false,
) : ArrTop::QueueRow
  ArrTop::QueueRow.new(
    backend_name: "b", media_kind: :movie, state: state,
    size: size, size_left: size_left, import_target: size,
    title: title, media_name: media_name, warning: warning, dest_folder: "/data",
  )
end

describe ArrTop::Render do
  describe ".bar" do
    # The default (both) glyph is `█`; filled vs remaining differ only by colour,
    # so the plain (uncoloured) bar is a solid run of `█` at any percentage.
    it "is a solid full-block run wrapped in brackets" do
      ArrTop::Render.bar(0.0, 10).should eq("[" + ("█" * 10) + "]")
      ArrTop::Render.bar(50.0, 10).should eq("[" + ("█" * 10) + "]")
      ArrTop::Render.bar(100.0, 10).should eq("[" + ("█" * 10) + "]")
    end

    it "has exactly width cells between the brackets for various widths" do
      [1, 3, 7, 20, 40].each do |width|
        bar = ArrTop::Render.bar(37.5, width)
        bar[0].should eq('[')
        bar[-1].should eq(']')
        (bar.size - 2).should eq(width)
      end
    end

    it "is safe for width <= 0" do
      ArrTop::Render.bar(50.0, 0).should eq("[]")
      ArrTop::Render.bar(50.0, -5).should eq("[]")
    end

    it "colours filled (blue) and remaining (grey) cells by their counts, brackets dark grey" do
      # width 4 at 50% => 2 filled, 2 remaining; both cells are `█`.
      bar = ArrTop::Render.bar(50.0, 4, ArrTop::Theme.default)
      bar.should contain("\e[38;5;240m[")       # dark-grey opening bracket
      bar.should contain("\e[38;5;111m██\e[0m") # 2 light-blue filled cells
      bar.should contain("\e[38;5;250m██\e[0m") # 2 light-grey remaining cells
    end

    it "colours all cells filled at 100% and all remaining at 0%" do
      full = ArrTop::Render.bar(100.0, 3, ArrTop::Theme.default)
      full.should contain("\e[38;5;111m███\e[0m")
      full.should_not contain("\e[38;5;250m")

      empty = ArrTop::Render.bar(0.0, 3, ArrTop::Theme.default)
      empty.should contain("\e[38;5;250m███\e[0m")
      empty.should_not contain("\e[38;5;111m")
    end
  end

  describe ".human_bytes" do
    it "keeps whole bytes" do
      ArrTop::Render.human_bytes(512_i64).should eq("512 B")
    end

    it "formats KB/MB/GB with two decimals" do
      ArrTop::Render.human_bytes(1536_i64).should eq("1.50 KB")
      ArrTop::Render.human_bytes(10_i64 * 1024 * 1024).should eq("10.00 MB")
    end

    it "formats a realistic GB size" do
      n = (9.43 * 1024 * 1024 * 1024).to_i64
      ArrTop::Render.human_bytes(n).should eq("9.43 GB")
    end

    it "is 0 B for non-positive" do
      ArrTop::Render.human_bytes(0_i64).should eq("0 B")
      ArrTop::Render.human_bytes(-5_i64).should eq("0 B")
    end
  end

  describe ".human_size_pair" do
    gb = 1024_i64 * 1024 * 1024
    mb = 1024_i64 * 1024

    it "renders each side in its own unit, trimming trailing .0" do
      # 12 GB on disk of 30 GB → whole numbers, no decimals, each side its own unit.
      ArrTop::Render.human_size_pair(12_i64 * gb, 30_i64 * gb).should eq("12 GB / 30 GB")
    end

    it "keeps one decimal for fractional values" do
      disk = (1.5 * gb).to_i64
      total = (2.1 * gb).to_i64
      ArrTop::Render.human_size_pair(disk, total).should eq("1.5 GB / 2.1 GB")
    end

    it "shows a small on-disk value in its OWN unit, never a misleading 0" do
      # 44 MB copied of a 2.1 GB estimate: with a shared GB unit this rounded to
      # `0`; per-side units keep it a meaningful `44 MB`.
      ArrTop::Render.human_size_pair(44_i64 * mb, (2.1 * gb).to_i64).should eq("44 MB / 2.1 GB")
    end

    it "shows a zero on-disk part as 0 B (just-started import)" do
      ArrTop::Render.human_size_pair(0_i64, (2.1 * gb).to_i64).should eq("0 B / 2.1 GB")
    end

    it "picks the disk side's own unit (512 MB stays MB, not a fraction of GB)" do
      ArrTop::Render.human_size_pair(512_i64 * mb, 2_i64 * gb).should eq("512 MB / 2 GB")
    end

    it "caps the on-disk value at the total (numerator never exceeds denominator)" do
      # A file that overshoots the per-episode estimate (2.3 GB on disk of a 2.1 GB
      # estimate) must display as full, not `2.3 GB / 2.1 GB`.
      total = (2.1 * gb).to_i64
      ArrTop::Render.human_size_pair((2.3 * gb).to_i64, total).should eq("2.1 GB / 2.1 GB")
    end

    it "shows just the size (single value) when disk is nil (not importing)" do
      total = (2.9 * gb).to_i64
      ArrTop::Render.human_size_pair(nil, total).should eq(ArrTop::Render.human_bytes(total))
      ArrTop::Render.human_size_pair(nil, total).should_not contain("/")
    end

    it "is — when the total is zero or negative" do
      ArrTop::Render.human_size_pair(0_i64, 0_i64).should eq("—")
      ArrTop::Render.human_size_pair(10_i64, -1_i64).should eq("—")
    end
  end

  describe ".human_duration" do
    it "shows hours+minutes past an hour" do
      ArrTop::Render.human_duration(1.hour + 20.minutes + 5.seconds).should eq("1h20m")
    end

    it "shows minutes+seconds under an hour" do
      ArrTop::Render.human_duration(5.minutes + 3.seconds).should eq("5m3s")
    end

    it "shows seconds only under a minute" do
      ArrTop::Render.human_duration(42.seconds).should eq("42s")
    end

    it "is 0s for non-positive" do
      ArrTop::Render.human_duration(Time::Span.zero).should eq("0s")
    end

    it "caps absurd spans at 99h+" do
      ArrTop::Render.human_duration(100.hours).should eq("99h+")
      ArrTop::Render.human_duration(1_000_000.hours).should eq("99h+")
    end
  end

  describe ".truncate" do
    it "leaves a short string untouched" do
      ArrTop::Render.truncate("hello", 10).should eq("hello")
    end

    it "adds an ellipsis when overflowing, staying within width" do
      out = ArrTop::Render.truncate("hello world", 8)
      out.size.should eq(8)
      out.should end_with("…")
    end

    it "is empty for width <= 0" do
      ArrTop::Render.truncate("hello", 0).should eq("")
    end
  end

  describe ".summary_text" do
    it "joins non-zero counts in state order" do
      counts = {
        ArrTop::State::Importing   => 3,
        ArrTop::State::Downloading => 1,
      } of ArrTop::State => Int32
      ArrTop::Render.summary_text(counts).should eq("3 importing · 1 downloading")
    end

    it "says idle when everything is zero" do
      ArrTop::Render.summary_text({} of ArrTop::State => Int32).should eq("idle")
    end
  end

  describe ".plan_columns" do
    it "yields five widths that fit within the row (columns + gaps ≤ width)" do
      widths = ArrTop::Render.plan_columns(120)
      widths.size.should eq(5)
      m, t, s, sz, p = widths
      m.should eq(20)
      t.should eq(28)
      s.should eq(11)
      sz.should eq(ArrTop::Render::SIZE_WIDTH)
      p.should be > 0
      # present columns each cost a leading one-space gap (the first has none).
      present = [m, t, s, sz, p].count(&.positive?)
      total = m + t + s + sz + p + {present - 1, 0}.max
      total.should be <= 120
    end

    it "drops the progress, size and status columns on a narrow row" do
      m, _t, s, sz, p = ArrTop::Render.plan_columns(30)
      m.should eq(20)
      s.should eq(0)
      sz.should eq(0)
      p.should eq(0)
    end
  end

  describe "box chrome" do
    theme = ArrTop::Theme.disabled
    counts = {ArrTop::State::Importing => 2} of ArrTop::State => Int32

    it "renders a top border exactly cols wide with title, summary and speed" do
      line = ArrTop::Render.top_border(100, counts, "↓ 45.20 MB/s", theme)
      line.size.should eq(100)
      line.should start_with("╔")
      line.should end_with("╗")
      line.should contain("arrtop")
      line.should contain("2 importing")
      line.should contain("↓ 45.20 MB/s")
    end

    it "omits the speed when blank, still exactly cols wide" do
      line = ArrTop::Render.top_border(100, counts, "", theme)
      line.size.should eq(100)
      line.should_not contain("↓")
    end

    it "renders divider and bottom border exactly cols wide" do
      ArrTop::Render.divider(100, theme).size.should eq(100)
      ArrTop::Render.divider(100, theme).should start_with("╠")
      ArrTop::Render.bottom_border(100, theme).size.should eq(100)
      ArrTop::Render.bottom_border(100, theme).should start_with("╚")
    end

    it "renders the column-header row with all labels, exactly the interior width" do
      inner = ArrTop::Render.header_row(theme, 98)
      inner.size.should eq(98)
      inner.should contain("MEDIA")
      inner.should contain("TORRENT")
      inner.should contain("STATUS")
      inner.should contain("SIZE")
      inner.should contain("PROGRESS")
      ArrTop::Render.wrap(inner, 100, theme).size.should eq(100)
    end
  end

  describe ".render_row" do
    theme = ArrTop::Theme.disabled
    width = 90

    gb = 1024_i64 * 1024 * 1024

    it "produces a line exactly the requested width" do
      line = ArrTop::Render.render_row(build_row(ArrTop::State::Downloading), nil, nil, 1000_i64, theme, width)
      line.size.should eq(width)
    end

    it "orders columns Movie, Torrent, Status and truncates the fixed name columns" do
      line = ArrTop::Render.render_row(
        build_row(ArrTop::State::Downloading, title: "A" * 40, media_name: "B" * 40),
        nil, nil, 1000_i64, theme, width)
      # Movie occupies the first 20 cells, ellipsis-truncated.
      line[0, 20].should eq(("B" * 19) + "…")
      # Torrent occupies the next 28 cells, after a one-space gap.
      line[21, 28].should eq(("A" * 27) + "…")
      line.should contain("downloading")
    end

    it "shows the combined disk/total size pair for an importing row (disk non-nil)" do
      # 1.9 GB on disk of a 2.9 GB target → `1.9 GB / 2.9 GB`, right-aligned in SIZE.
      disk = (1.9 * gb).to_i64
      total = (2.9 * gb).to_i64
      line = ArrTop::Render.render_row(
        build_row(ArrTop::State::Importing), nil, disk, total, theme, width)
      line.should contain("1.9 GB / 2.9 GB")
      line.size.should eq(width)
    end

    it "shows just the size (no pair) in the SIZE column for a non-importing row (disk nil)" do
      total = (2.9 * gb).to_i64
      line = ArrTop::Render.render_row(
        build_row(ArrTop::State::ImportPending), nil, nil, total, theme, width)
      line.should contain(ArrTop::Render.human_bytes(total)) # e.g. `2.90 GB`
      line.should_not contain("/2.9")                        # no disk/total pair
    end

    it "shows a bar and percent for an importing row (from copy progress)" do
      import = ArrTop::ImportProgress.new("/data/f.mkv", bytes: 41_i64, target: 100_i64)
      line = ArrTop::Render.render_row(build_row(ArrTop::State::Importing), import, 41_i64, 100_i64, theme, width)
      line.should contain("importing")
      line.should contain("█")
      line.should contain("41.0%")
    end

    it "shows a bar and percent for a downloading row (from download percent)" do
      line = ArrTop::Render.render_row(
        build_row(ArrTop::State::Downloading, size: 1000_i64, size_left: 500_i64),
        nil, 500_i64, 1000_i64, theme, width)
      line.should contain("50.0%")
      line.should contain("█")
    end

    it "shows NEITHER a bar NOR a percent for an ImportPending row" do
      line = ArrTop::Render.render_row(build_row(ArrTop::State::ImportPending), nil, nil, 1000_i64, theme, width)
      line.should contain("pending")
      line.should_not contain("█")
      line.should_not contain("%")
    end

    it "honors a display_state that differs from row.state (reclassified pending)" do
      import = ArrTop::ImportProgress.new("/data/f.mkv", bytes: 41_i64, target: 100_i64)
      # The row's real state is Importing (with a bar available), but the caller
      # reclassifies it to pending: label reads pending and NO bar is drawn.
      line = ArrTop::Render.render_row(
        build_row(ArrTop::State::Importing), import, 41_i64, 100_i64, theme, width, ArrTop::State::ImportPending)
      line.should contain("pending")
      line.should_not contain("█")
      line.should_not contain("%")
    end

    it "shows no bar for failed, queued, or unknown rows" do
      [ArrTop::State::Failed, ArrTop::State::Queued, ArrTop::State::Unknown].each do |state|
        line = ArrTop::Render.render_row(build_row(state), nil, nil, 1000_i64, theme, width)
        line.should_not contain("█")
        line.should_not contain("%")
      end
    end

    it "renders the movie cell as — when media_name is nil" do
      line = ArrTop::Render.render_row(build_row(ArrTop::State::Queued, media_name: nil), nil, nil, 1000_i64, theme, width)
      line[0, 20].should eq("—".ljust(20))
    end

    it "never exceeds a narrow terminal width" do
      line = ArrTop::Render.render_row(
        build_row(ArrTop::State::Downloading, title: "A very very very long title"), nil, nil, 1000_i64, theme, 30)
      line.size.should eq(30)
    end
  end
end
