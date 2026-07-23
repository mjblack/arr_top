require "./spec_helper"
require "file_utils"

private ENV_KEY = "ARR_TOP_CONFIG"

# Runs *block* inside a fresh empty temp dir as the CWD, cleaning up after.
private def in_empty_dir(&)
  dir = File.join(Dir.tempdir, "arrtop-cli-#{Random.rand(1_000_000)}")
  Dir.mkdir_p(dir)
  begin
    Dir.cd(dir) { yield dir }
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe ArrTop::CLI do
  describe ".config_path" do
    it "returns the -c/--config value" do
      in_empty_dir do
        ArrTop::CLI.config_path(["-c", "/etc/arrtop.yaml"]).should eq("/etc/arrtop.yaml")
        ArrTop::CLI.config_path(["--config", "/etc/arrtop.json"]).should eq("/etc/arrtop.json")
      end
    end

    it "lets -c/--config beat the ARR_TOP_CONFIG env var" do
      ENV[ENV_KEY] = "/from/env.yaml"
      begin
        in_empty_dir do
          ArrTop::CLI.config_path(["-c", "/from/flag.yaml"]).should eq("/from/flag.yaml")
        end
      ensure
        ENV.delete(ENV_KEY)
      end
    end

    it "uses ARR_TOP_CONFIG when no flag is given" do
      ENV[ENV_KEY] = "/from/env.yaml"
      begin
        in_empty_dir do
          ArrTop::CLI.config_path([] of String).should eq("/from/env.yaml")
        end
      ensure
        ENV.delete(ENV_KEY)
      end
    end

    it "lets the env var beat the current-directory default search" do
      ENV[ENV_KEY] = "/from/env.yaml"
      begin
        in_empty_dir do
          File.write("config.yaml", "backends: []")
          ArrTop::CLI.config_path([] of String).should eq("/from/env.yaml")
        end
      ensure
        ENV.delete(ENV_KEY)
      end
    end

    it "falls back to the first existing default config file in the CWD" do
      ENV.delete(ENV_KEY)
      in_empty_dir do
        File.write("config.json", "{}")
        ArrTop::CLI.config_path([] of String).should eq("config.json")
      end
    end

    it "prefers config.yaml over config.yml over config.json" do
      ENV.delete(ENV_KEY)
      in_empty_dir do
        File.write("config.yaml", "backends: []")
        File.write("config.yml", "backends: []")
        File.write("config.json", "{}")
        ArrTop::CLI.config_path([] of String).should eq("config.yaml")
      end
    end

    it "returns nil when nothing resolves" do
      ENV.delete(ENV_KEY)
      in_empty_dir do
        ArrTop::CLI.config_path([] of String).should be_nil
      end
    end
  end

  describe ".default_config_candidates" do
    it "searches the CWD defaults before the /etc/arr_top system defaults" do
      candidates = ArrTop::CLI.default_config_candidates

      # The current-directory defaults come first, in the documented order.
      candidates.first(3).should eq(["config.yaml", "config.yml", "config.json"])

      # The /etc/arr_top fallbacks come after them, so a local config wins.
      candidates.should contain("/etc/arr_top/config.yaml")
      candidates.should contain("/etc/arr_top/config.yml")
      candidates.should contain("/etc/arr_top/config.json")

      candidates.index!("/etc/arr_top/config.yaml")
        .should be > candidates.index!("config.json")
    end

    it "orders the /etc fallbacks yaml, yml, json" do
      etc = ArrTop::CLI.default_config_candidates.select(&.starts_with?("/etc/arr_top/"))
      etc.should eq([
        "/etc/arr_top/config.yaml",
        "/etc/arr_top/config.yml",
        "/etc/arr_top/config.json",
      ])
    end
  end

  describe ".build_backends" do
    it "maps sonarr → SonarrBackend and radarr → RadarrBackend, preserving order" do
      config = ArrTop::Config.from_yaml(<<-YAML)
        backends:
          - name: s1
            type: sonarr
            url: http://localhost:8989
            api_key: a
          - name: r1
            type: radarr
            url: http://localhost:7878
            api_key: b
          - name: s2
            type: sonarr
            url: http://localhost:8990
            api_key: c
        YAML

      backends = ArrTop::CLI.build_backends(config)
      backends.size.should eq(3)
      backends[0].should be_a(ArrTop::SonarrBackend)
      backends[0].name.should eq("s1")
      backends[1].should be_a(ArrTop::RadarrBackend)
      backends[1].name.should eq("r1")
      backends[2].should be_a(ArrTop::SonarrBackend)
      backends[2].name.should eq("s2")
    end

    it "skips a backend with an unrecognized (nil) type" do
      config = ArrTop::Config.from_yaml(<<-YAML)
        backends:
          - name: good
            type: sonarr
            url: http://localhost:8989
            api_key: a
          - name: bogus
            type: lidarr
            url: http://localhost:8686
            api_key: b
        YAML

      backends = ArrTop::CLI.build_backends(config)
      backends.size.should eq(1)
      backends[0].name.should eq("good")
    end
  end

  # The IMPORT% cell renders straight off the resolved display progress, so the
  # snapshot always agrees with the TUI (both go through TUI.resolve_display).
  describe ".import_cell" do
    it "shows — when there is no progress (pending / non-importing / unwatchable)" do
      ArrTop::CLI.import_cell(nil).should eq("—")
    end

    it "shows a finished episode as 100.0%" do
      done = ArrTop::ImportProgress.new("/tv/E01.mkv", 2_870_i64, 2_870_i64)
      ArrTop::CLI.import_cell(done).should eq("100.0%")
    end

    it "shows an actively-copying episode's estimated percentage" do
      active = ArrTop::ImportProgress.new("/tv/E04.mkv", 574_i64, 2_870_i64)
      ArrTop::CLI.import_cell(active).should eq("20.0%")
    end
  end

  describe ".snapshot_header" do
    it "includes a SIZE column between STATUS and DL%" do
      header = ArrTop::CLI.snapshot_header
      header.should contain("STATUS")
      header.should contain("SIZE")
      header.should contain("DL%")
      header.should contain("IMPORT%")
      # SIZE sits after STATUS and before DL%.
      header.index!("SIZE").should be > header.index!("STATUS")
      header.index!("SIZE").should be < header.index!("DL%")
    end
  end

  describe ".snapshot_row" do
    gb = 1024_i64 * 1024 * 1024

    private_row = ->(state : ArrTop::State, size : Int64, size_left : Int64) do
      ArrTop::QueueRow.new(
        backend_name: "b", media_kind: :episode, state: state,
        size: size, size_left: size_left, import_target: size,
        title: "Some.Release", media_name: "Show S01E01", dest_folder: "/tv",
      )
    end

    it "renders the combined on-disk/total size pair, ANSI-free" do
      row = private_row.call(ArrTop::State::Importing, 2_i64 * gb, 0_i64)
      import = ArrTop::ImportProgress.new("/tv/E01.mkv", (1.2 * gb).to_i64, 2_i64 * gb)
      line = ArrTop::CLI.snapshot_row(row, ArrTop::State::Importing, (1.2 * gb).to_i64, 2_i64 * gb, import)
      line.should contain("1.2/2 GB")
      line.should contain("Show S01E01")
      line.should_not contain("\e[") # no ANSI escapes
    end

    it "shows —/total for a pending row with nothing on disk" do
      row = private_row.call(ArrTop::State::ImportPending, 3_i64 * gb, 3_i64 * gb)
      line = ArrTop::CLI.snapshot_row(row, ArrTop::State::ImportPending, nil, 3_i64 * gb, nil)
      line.should contain("—/3 GB")
      line.should contain("pending")
    end
  end
end
