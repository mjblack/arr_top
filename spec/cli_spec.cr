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
end
