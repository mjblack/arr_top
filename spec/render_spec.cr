require "./spec_helper"

# A minimal QueueRow builder so tests can vary just the fields render cares about.
private def build_row(
  state : ArrTop::State,
  title : String? = "Some Title",
  size : Int64 = 1000_i64,
  size_left : Int64 = 0_i64,
  timeleft : String? = nil,
  eta : Time? = nil,
) : ArrTop::QueueRow
  ArrTop::QueueRow.new(
    backend_name: "b", media_kind: :movie, state: state,
    size: size, size_left: size_left, import_target: size,
    title: title, timeleft: timeleft, eta: eta, dest_folder: "/data",
  )
end

describe ArrTop::Render do
  describe ".bar" do
    it "is empty fill at 0%" do
      ArrTop::Render.bar(0.0, 10).should eq("[" + ("-" * 10) + "]")
    end

    it "is full fill at 100%" do
      ArrTop::Render.bar(100.0, 10).should eq("[" + ("#" * 10) + "]")
    end

    it "half-fills at 50%" do
      ArrTop::Render.bar(50.0, 10).should eq("[#####-----]")
    end

    it "clamps overflow to full" do
      ArrTop::Render.bar(150.0, 8).should eq("[########]")
    end

    it "clamps negative to empty" do
      ArrTop::Render.bar(-20.0, 8).should eq("[--------]")
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
      # 9.43 GB
      n = (9.43 * 1024 * 1024 * 1024).to_i64
      ArrTop::Render.human_bytes(n).should eq("9.43 GB")
    end

    it "is 0 B for non-positive" do
      ArrTop::Render.human_bytes(0_i64).should eq("0 B")
      ArrTop::Render.human_bytes(-5_i64).should eq("0 B")
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

  describe ".header" do
    it "summarizes non-zero counts and fits within cols" do
      counts = {
        ArrTop::State::Importing   => 3,
        ArrTop::State::Downloading => 1,
      } of ArrTop::State => Int32
      header = ArrTop::Render.header(80, counts)
      header.should contain("arrtop")
      header.should contain("3 importing")
      header.should contain("1 downloading")
      header.size.should be <= 80
    end

    it "says idle when everything is zero" do
      ArrTop::Render.header(80, {} of ArrTop::State => Int32).should contain("idle")
    end
  end

  describe ".render_row" do
    it "renders an importing row from the import percent and fits cols" do
      row = build_row(ArrTop::State::Importing, title: "The Big Movie")
      import = ArrTop::ImportProgress.new("/data/f.mkv", bytes: 26_i64, target: 100_i64)
      line = ArrTop::Render.render_row(row, import, 30.seconds, 80)

      line.size.should be <= 80
      line.should contain("Importing")
      # 26% of a 20-cell bar rounds to 5 filled cells.
      line.should contain("[#####")
      line.should contain("26.0%")
      line.should contain("~30s")
    end

    it "renders a downloading row from the download percent" do
      # size 1000, size_left 500 => 50% download.
      row = build_row(ArrTop::State::Downloading, title: "Show", size: 1000_i64, size_left: 500_i64, timeleft: "00:10:00")
      line = ArrTop::Render.render_row(row, nil, nil, 80)

      line.size.should be <= 80
      line.should contain("Downloading")
      line.should contain("[##########----------]")
      line.should contain("50.0%")
      line.should contain("00:10:00")
    end

    it "never exceeds a narrow terminal width" do
      row = build_row(ArrTop::State::Downloading, title: "A very very very long title that will not fit")
      line = ArrTop::Render.render_row(row, nil, nil, 30)
      line.size.should be <= 30
    end
  end
end
