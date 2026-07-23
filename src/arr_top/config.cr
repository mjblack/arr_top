require "yaml"
require "json"

module ArrTop
  # Application configuration: the list of Sonarr/Radarr backends arrtop polls.
  # Parses from either YAML or JSON (the same shape in both), so a config file
  # can be authored in whichever the operator prefers.
  class Config
    include YAML::Serializable
    include JSON::Serializable

    # Raised when a config file cannot be read/parsed or fails validation.
    class Error < Exception
    end

    # Which *arr flavour a backend speaks. Serialized as lowercase
    # `sonarr`/`radarr`; parsed leniently (see `BackendTypeConverter`).
    enum BackendType
      Sonarr
      Radarr

      def to_yaml(yaml : YAML::Nodes::Builder) : Nil
        yaml.scalar(to_s.downcase)
      end

      def to_json(json : JSON::Builder) : Nil
        json.string(to_s.downcase)
      end
    end

    # Which download client a `DownloadClient` speaks. Currently only
    # qBittorrent. Serialized as lowercase `qbittorrent`; parsed leniently (see
    # `DownloadClient::DownloadClientTypeConverter`).
    enum DownloadClientType
      Qbittorrent

      def to_yaml(yaml : YAML::Nodes::Builder) : Nil
        yaml.scalar(to_s.downcase)
      end

      def to_json(json : JSON::Builder) : Nil
        json.string(to_s.downcase)
      end
    end

    # An optional download client arrtop can query for **exact** per-episode
    # sizes. A Sonarr season pack reports only the whole-pack total on every
    # episode row, so without this arrtop estimates each episode as
    # `pack_total / episode_count`. When a client is configured, arrtop asks it
    # for the real size of each episode's file in the torrent instead. Fully
    # optional: absent ⇒ the feature is off and behaviour is unchanged.
    #
    # A queue row is matched to a client by the row's `download_client` name, so
    # a client's `name` here must equal the download-client name Sonarr reports.
    class DownloadClient
      include YAML::Serializable
      include JSON::Serializable

      # Must equal the download-client name the *arr reports on a queue row
      # (`downloadClient`), so a row can be matched to this client.
      property name : String

      # Parsed leniently so an unknown value surfaces as a validation error
      # rather than a parse crash. `nil` means the raw value was unrecognized.
      @[YAML::Field(converter: ArrTop::Config::DownloadClient::DownloadClientTypeConverter)]
      @[JSON::Field(converter: ArrTop::Config::DownloadClient::DownloadClientTypeConverter)]
      property type : DownloadClientType?

      # The client's Web UI base URL, e.g. `http://localhost:8080`.
      property url : String

      property username : String
      property password : String

      def initialize(@name : String, @type : DownloadClientType?, @url : String,
                     @username : String, @password : String)
      end

      # Leniently parses `DownloadClientType`, yielding `nil` for unknown values
      # so validation can report a helpful message instead of crashing the parse.
      module DownloadClientTypeConverter
        def self.from_yaml(ctx : YAML::ParseContext, node : YAML::Nodes::Node) : DownloadClientType?
          unless node.is_a?(YAML::Nodes::Scalar)
            node.raise "Expected scalar, not #{node.class}"
          end
          DownloadClientType.parse?(node.value)
        end

        def self.to_yaml(value : DownloadClientType?, yaml : YAML::Nodes::Builder) : Nil
          value.to_yaml(yaml)
        end

        def self.from_json(pull : JSON::PullParser) : DownloadClientType?
          DownloadClientType.parse?(pull.read_string)
        end

        def self.to_json(value : DownloadClientType?, json : JSON::Builder) : Nil
          value.to_json(json)
        end
      end
    end

    # A single Sonarr/Radarr instance to poll.
    class Backend
      include YAML::Serializable
      include JSON::Serializable

      property name : String

      # Parsed leniently so an unknown value surfaces as a validation error
      # rather than a parse crash. `nil` means the raw value was unrecognized.
      @[YAML::Field(converter: ArrTop::Config::Backend::BackendTypeConverter)]
      @[JSON::Field(converter: ArrTop::Config::Backend::BackendTypeConverter)]
      property type : BackendType?

      property url : String

      @[YAML::Field(key: "api_key")]
      @[JSON::Field(key: "api_key")]
      property api_key : String

      def initialize(@name : String, @type : BackendType?, @url : String,
                     @api_key : String)
      end

      # Leniently parses `BackendType`, yielding `nil` for unknown values so
      # validation can report a helpful message instead of crashing the parse.
      module BackendTypeConverter
        def self.from_yaml(ctx : YAML::ParseContext, node : YAML::Nodes::Node) : BackendType?
          unless node.is_a?(YAML::Nodes::Scalar)
            node.raise "Expected scalar, not #{node.class}"
          end
          BackendType.parse?(node.value)
        end

        def self.to_yaml(value : BackendType?, yaml : YAML::Nodes::Builder) : Nil
          value.to_yaml(yaml)
        end

        def self.from_json(pull : JSON::PullParser) : BackendType?
          BackendType.parse?(pull.read_string)
        end

        def self.to_json(value : BackendType?, json : JSON::Builder) : Nil
          value.to_json(json)
        end
      end
    end

    property backends : Array(Backend) = [] of Backend

    # Optional download clients arrtop queries for exact per-episode sizes. `nil`
    # / absent ⇒ the feature is off and behaviour is identical to before (each
    # season-pack episode is estimated as `pack_total / episode_count`). When
    # present, every entry is validated by `#validation_errors`.
    property download_clients : Array(DownloadClient)? = nil

    # How often the TUI redraws, as `<int>s` / `<int>ms` / a bare integer
    # (seconds). `nil` (unset) means the default; see `#refresh_span`. Validated
    # by `#validation_errors` when set.
    property refresh : String? = nil

    def initialize(@backends : Array(Backend) = [] of Backend, @refresh : String? = nil,
                   @download_clients : Array(DownloadClient)? = nil)
    end

    # Default TUI refresh interval when `refresh` is unset/blank/unparseable.
    DEFAULT_REFRESH = 2.seconds

    # The refresh interval as a `Time::Span`: the parsed `refresh` value, or
    # `DEFAULT_REFRESH` (2s) otherwise. (An unparseable value is also reported by
    # `#validation_errors`.)
    def refresh_span : Time::Span
      parse_refresh(refresh) || DEFAULT_REFRESH
    end

    # Parses a refresh string: `<int>ms` → milliseconds, `<int>s` → seconds, a
    # bare positive integer → seconds. Returns `nil` for nil/blank/malformed
    # input or a non-positive number.
    private def parse_refresh(value : String?) : Time::Span?
      return nil if value.nil?
      text = value.strip.downcase
      return nil if text.empty?

      if text.ends_with?("ms")
        positive_int(text[0...-2]).try(&.milliseconds)
      elsif text.ends_with?("s")
        positive_int(text[0...-1]).try(&.seconds)
      else
        positive_int(text).try(&.seconds)
      end
    end

    # Parses *text* as a strictly-positive integer, or `nil` when it is not a
    # positive whole number.
    private def positive_int(text : String) : Int32?
      number = text.to_i?
      number if number && number > 0
    end

    # Loads a config from `path`. YAML wins: `.yml`/`.yaml` parse as YAML,
    # `.json` as JSON, and anything else tries YAML first then JSON.
    def self.from_file(path : String) : Config
      content = File.read(path)

      case File.extname(path).downcase
      when ".yml", ".yaml"
        from_yaml(content)
      when ".json"
        from_json(content)
      else
        begin
          from_yaml(content)
        rescue
          from_json(content)
        end
      end
    rescue ex : File::Error
      raise Error.new("cannot read config file #{path.inspect}: #{ex.message}")
    end

    # Parses a config from a YAML string.
    def self.from_yaml(string : String) : Config
      document = YAML::Nodes.parse(string)
      node = document.nodes.first? || YAML::Nodes::Scalar.new("")
      new(YAML::ParseContext.new, node)
    rescue ex : YAML::ParseException
      raise Error.new("invalid YAML config: #{ex.message}")
    end

    # Parses a config from a JSON string.
    def self.from_json(string : String) : Config
      new(JSON::PullParser.new(string))
    rescue ex : JSON::ParseException
      raise Error.new("invalid JSON config: #{ex.message}")
    end

    # Returns a list of all validation problems (empty when valid).
    def validation_errors : Array(String)
      return ["config must define at least one backend"] if backends.empty?

      errors = [] of String
      backends.each_with_index do |backend, i|
        label = backend.name.blank? ? "backend ##{i + 1}" : "backend #{backend.name.inspect}"
        errors << "#{label}: name is required" if backend.name.blank?
        errors << "#{label}: url is required" if backend.url.blank?
        errors << "#{label}: api_key is required" if backend.api_key.blank?
        errors << "#{label}: type must be one of sonarr, radarr" if backend.type.nil?
      end

      if (value = refresh) && parse_refresh(value).nil?
        errors << "refresh #{value.inspect} is invalid; use <int>s, <int>ms, or a bare integer (seconds)"
      end

      errors.concat(download_client_errors)
      errors
    end

    # Validation problems for the optional `download_clients` block (empty when
    # absent — the feature is simply off — or when every client is well-formed).
    private def download_client_errors : Array(String)
      errors = [] of String
      clients = download_clients
      return errors if clients.nil?

      clients.each_with_index do |client, i|
        label = client.name.blank? ? "download client ##{i + 1}" : "download client #{client.name.inspect}"
        errors << "#{label}: name is required" if client.name.blank?
        errors << "#{label}: url is required" if client.url.blank?
        errors << "#{label}: username is required" if client.username.blank?
        errors << "#{label}: password is required" if client.password.blank?
        errors << "#{label}: type must be qbittorrent" if client.type.nil?
      end
      errors
    end

    # Validates the config, raising `Config::Error` listing all problems.
    # Returns `self` when valid.
    def validate : self
      errors = validation_errors
      unless errors.empty?
        raise Error.new("invalid config:\n  - #{errors.join("\n  - ")}")
      end
      self
    end
  end
end
