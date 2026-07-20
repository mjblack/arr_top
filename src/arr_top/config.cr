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

    def initialize(@backends : Array(Backend) = [] of Backend)
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
