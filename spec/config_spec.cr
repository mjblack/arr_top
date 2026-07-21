require "./spec_helper"

private VALID_YAML = <<-YAML
  backends:
    - name: sonarr
      type: sonarr
      url: http://localhost:8989
      api_key: abc123
    - name: radarr
      type: radarr
      url: http://localhost:7878
      api_key: def456
  YAML

private VALID_JSON = <<-JSON
  {
    "backends": [
      { "name": "sonarr", "type": "sonarr", "url": "http://localhost:8989", "api_key": "abc123" },
      { "name": "radarr", "type": "radarr", "url": "http://localhost:7878", "api_key": "def456" }
    ]
  }
  JSON

describe ArrTop::Config do
  describe ".from_yaml" do
    it "parses backends with lowercase type" do
      config = ArrTop::Config.from_yaml(VALID_YAML)
      config.backends.size.should eq(2)
      config.backends[0].name.should eq("sonarr")
      config.backends[0].type.should eq(ArrTop::Config::BackendType::Sonarr)
      config.backends[0].url.should eq("http://localhost:8989")
      config.backends[0].api_key.should eq("abc123")
      config.backends[1].type.should eq(ArrTop::Config::BackendType::Radarr)
      config.validation_errors.should be_empty
    end

    it "leniently parses an unknown type as nil rather than crashing" do
      yaml = <<-YAML
        backends:
          - name: bogus
            type: lidarr
            url: http://localhost:8686
            api_key: xyz
        YAML
      config = ArrTop::Config.from_yaml(yaml)
      config.backends[0].type.should be_nil
    end

    it "raises Config::Error on malformed YAML" do
      expect_raises(ArrTop::Config::Error, /invalid YAML/) do
        ArrTop::Config.from_yaml("backends: [unterminated")
      end
    end
  end

  describe ".from_json" do
    it "parses backends with lowercase type" do
      config = ArrTop::Config.from_json(VALID_JSON)
      config.backends.size.should eq(2)
      config.backends[0].type.should eq(ArrTop::Config::BackendType::Sonarr)
      config.backends[1].type.should eq(ArrTop::Config::BackendType::Radarr)
      config.validation_errors.should be_empty
    end

    it "raises Config::Error on malformed JSON" do
      expect_raises(ArrTop::Config::Error, /invalid JSON/) do
        ArrTop::Config.from_json("{ not json")
      end
    end
  end

  describe "serialization round-trips lowercase type" do
    it "emits type lowercase in YAML and JSON" do
      config = ArrTop::Config.from_yaml(VALID_YAML)
      config.to_yaml.should contain("type: sonarr")
      config.to_json.should contain(%("type":"sonarr"))
    end
  end

  describe "#validation_errors" do
    it "reports when there are no backends" do
      config = ArrTop::Config.from_yaml("backends: []")
      config.validation_errors.should eq(["config must define at least one backend"])
    end

    it "reports blank name, url, and api_key" do
      yaml = <<-YAML
        backends:
          - name: ""
            type: sonarr
            url: ""
            api_key: ""
        YAML
      errors = ArrTop::Config.from_yaml(yaml).validation_errors
      errors.any?(&.includes?("name is required")).should be_true
      errors.any?(&.includes?("url is required")).should be_true
      errors.any?(&.includes?("api_key is required")).should be_true
    end

    it "reports an unknown type" do
      yaml = <<-YAML
        backends:
          - name: bogus
            type: lidarr
            url: http://localhost:8686
            api_key: xyz
        YAML
      errors = ArrTop::Config.from_yaml(yaml).validation_errors
      errors.any?(&.includes?("type must be one of sonarr, radarr")).should be_true
    end
  end

  describe "#validate" do
    it "returns self when valid" do
      config = ArrTop::Config.from_yaml(VALID_YAML)
      config.validate.should be(config)
    end

    it "raises Config::Error listing all problems when invalid" do
      expect_raises(ArrTop::Config::Error, /at least one backend/) do
        ArrTop::Config.from_yaml("backends: []").validate
      end
    end
  end

  describe "#refresh_span" do
    it "defaults to 2 seconds when unset" do
      ArrTop::Config.from_yaml(VALID_YAML).refresh_span.should eq(2.seconds)
    end

    it "parses an <int>s value" do
      yaml = "#{VALID_YAML}\nrefresh: 5s"
      ArrTop::Config.from_yaml(yaml).refresh_span.should eq(5.seconds)
    end

    it "parses an <int>ms value" do
      yaml = "#{VALID_YAML}\nrefresh: 500ms"
      ArrTop::Config.from_yaml(yaml).refresh_span.should eq(500.milliseconds)
    end

    it "parses a bare integer as seconds" do
      yaml = "#{VALID_YAML}\nrefresh: 3"
      ArrTop::Config.from_yaml(yaml).refresh_span.should eq(3.seconds)
    end

    it "falls back to the default for an unparseable value" do
      yaml = "#{VALID_YAML}\nrefresh: soon"
      ArrTop::Config.from_yaml(yaml).refresh_span.should eq(2.seconds)
    end
  end

  describe "#validation_errors (refresh)" do
    it "reports an unparseable refresh value" do
      yaml = "#{VALID_YAML}\nrefresh: soon"
      errors = ArrTop::Config.from_yaml(yaml).validation_errors
      errors.any?(&.includes?("refresh")).should be_true
    end

    it "accepts a valid refresh value" do
      yaml = "#{VALID_YAML}\nrefresh: 250ms"
      ArrTop::Config.from_yaml(yaml).validation_errors.should be_empty
    end
  end

  describe ".from_file" do
    it "picks the YAML parser for .yaml and .yml" do
      ["config.yaml", "config.yml"].each do |name|
        path = File.join(Dir.tempdir, "arrtop-#{Random.rand(1_000_000)}-#{name}")
        File.write(path, VALID_YAML)
        begin
          config = ArrTop::Config.from_file(path)
          config.backends.size.should eq(2)
        ensure
          File.delete(path) if File.exists?(path)
        end
      end
    end

    it "picks the JSON parser for .json" do
      path = File.join(Dir.tempdir, "arrtop-#{Random.rand(1_000_000)}-config.json")
      File.write(path, VALID_JSON)
      begin
        config = ArrTop::Config.from_file(path)
        config.backends.size.should eq(2)
        config.backends[1].type.should eq(ArrTop::Config::BackendType::Radarr)
      ensure
        File.delete(path) if File.exists?(path)
      end
    end

    it "falls back to YAML then JSON for an unknown extension" do
      path = File.join(Dir.tempdir, "arrtop-#{Random.rand(1_000_000)}-config.conf")
      File.write(path, VALID_JSON)
      begin
        config = ArrTop::Config.from_file(path)
        config.backends.size.should eq(2)
      ensure
        File.delete(path) if File.exists?(path)
      end
    end

    it "wraps a missing file as Config::Error" do
      expect_raises(ArrTop::Config::Error, /cannot read config file/) do
        ArrTop::Config.from_file("/nonexistent/arrtop/config.yaml")
      end
    end
  end
end
