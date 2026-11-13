require "json"

class Agent
  # Structured response format for Chat Completions and Responses.
  struct ResponseFormat
    enum Kind
      Text
      JsonObject
      JsonSchema
    end

    getter kind : Kind
    getter name : String?
    getter description : String?
    getter schema : Hash(String, JSON::Any)?
    getter strict : Bool

    def initialize(
      @kind : Kind,
      @name : String? = nil,
      @description : String? = nil,
      @schema : Hash(String, JSON::Any)? = nil,
      @strict : Bool = false,
    )
    end

    def self.text : self
      new(Kind::Text)
    end

    def self.json_object : self
      new(Kind::JsonObject)
    end

    def self.json_schema(
      name : String,
      schema : Hash(String, JSON::Any),
      description : String? = nil,
      strict : Bool = false,
    ) : self
      raise ConfigurationError.new("response_format json_schema name must not be empty") if name.empty?
      new(Kind::JsonSchema, name: name, description: description, schema: schema, strict: strict)
    end

    # Chat Completions uses a nested `json_schema` object.
    def to_chat_json : JSON::Any
      case @kind
      when Kind::Text
        JSON::Any.new({"type" => JSON::Any.new("text")})
      when Kind::JsonObject
        JSON::Any.new({"type" => JSON::Any.new("json_object")})
      when Kind::JsonSchema
        inner = {} of String => JSON::Any
        inner["name"] = JSON::Any.new(@name || "")
        if description = @description
          inner["description"] = JSON::Any.new(description)
        end
        inner["schema"] = JSON::Any.new(@schema || {} of String => JSON::Any)
        inner["strict"] = JSON::Any.new(@strict)
        JSON::Any.new({
          "type"        => JSON::Any.new("json_schema"),
          "json_schema" => JSON::Any.new(inner),
        })
      else
        raise "unreachable ResponseFormat kind"
      end
    end

    # Responses API uses a flat `text.format` object.
    def to_responses_json : JSON::Any
      case @kind
      when Kind::Text
        JSON::Any.new({"type" => JSON::Any.new("text")})
      when Kind::JsonObject
        JSON::Any.new({"type" => JSON::Any.new("json_object")})
      when Kind::JsonSchema
        outer = {} of String => JSON::Any
        outer["type"] = JSON::Any.new("json_schema")
        outer["name"] = JSON::Any.new(@name || "")
        if description = @description
          outer["description"] = JSON::Any.new(description)
        end
        outer["schema"] = JSON::Any.new(@schema || {} of String => JSON::Any)
        outer["strict"] = JSON::Any.new(@strict)
        JSON::Any.new(outer)
      else
        raise "unreachable ResponseFormat kind"
      end
    end
  end

  # Tool selection mode for Chat Completions and Responses.
  struct ToolChoice
    enum Kind
      Auto
      None
      Required
      Function
      AllowedTools
    end

    getter kind : Kind
    getter name : String?
    getter mode : String?
    getter tools : Array(Tool)?

    def initialize(
      @kind : Kind,
      @name : String? = nil,
      @mode : String? = nil,
      @tools : Array(Tool)? = nil,
    )
    end

    def self.auto : self
      new(Kind::Auto)
    end

    def self.none : self
      new(Kind::None)
    end

    def self.required : self
      new(Kind::Required)
    end

    def self.function(name : String) : self
      raise ConfigurationError.new("tool_choice function name must not be empty") if name.empty?
      new(Kind::Function, name: name)
    end

    def self.allowed_tools(mode : String, tools : Array(Tool)) : self
      new(Kind::AllowedTools, mode: mode, tools: tools)
    end

    def forced? : Bool
      @kind == Kind::Required || @kind == Kind::Function || @kind == Kind::AllowedTools
    end

    def to_chat_json : JSON::Any
      case @kind
      when Kind::Auto
        JSON::Any.new("auto")
      when Kind::None
        JSON::Any.new("none")
      when Kind::Required
        JSON::Any.new("required")
      when Kind::Function
        JSON::Any.new({
          "type"     => JSON::Any.new("function"),
          "function" => JSON::Any.new({"name" => JSON::Any.new(@name || "")}),
        })
      when Kind::AllowedTools
        items = (@tools || [] of Tool).map do |tool|
          JSON::Any.new({
            "type"     => JSON::Any.new("function"),
            "function" => JSON::Any.new({"name" => JSON::Any.new(tool.function.name)}),
          })
        end
        JSON::Any.new({
          "type"          => JSON::Any.new("allowed_tools"),
          "allowed_tools" => JSON::Any.new({
            "mode"  => JSON::Any.new(@mode || "auto"),
            "tools" => JSON::Any.new(items),
          }),
        })
      else
        raise "unreachable ToolChoice kind"
      end
    end

    def to_responses_json : JSON::Any
      case @kind
      when Kind::Auto
        JSON::Any.new("auto")
      when Kind::None
        JSON::Any.new("none")
      when Kind::Required
        JSON::Any.new("required")
      when Kind::Function
        JSON::Any.new({
          "type" => JSON::Any.new("function"),
          "name" => JSON::Any.new(@name || ""),
        })
      when Kind::AllowedTools
        items = (@tools || [] of Tool).map do |tool|
          JSON::Any.new({
            "type" => JSON::Any.new("function"),
            "name" => JSON::Any.new(tool.function.name),
          })
        end
        JSON::Any.new({
          "type"  => JSON::Any.new("allowed_tools"),
          "mode"  => JSON::Any.new(@mode || "auto"),
          "tools" => JSON::Any.new(items),
        })
      else
        raise "unreachable ToolChoice kind"
      end
    end
  end

  # Per-request overrides for modern Chat Completions / Responses parameters.
  #
  # Global defaults live in `Agent::Config#request_options`; `Agent#ask` accepts
  # a RequestOptions and merges it on top.
  class RequestOptions
    property max_completion_tokens : Int32?
    property max_tokens : Int32?
    property temperature : Float64?
    property top_p : Float64?
    property stop : String | Array(String)?
    property seed : Int64?
    property n : Int32?
    property presence_penalty : Float64?
    property frequency_penalty : Float64?
    property service_tier : String?
    property store : Bool?
    property metadata : Hash(String, String)?
    property reasoning_effort : String?
    property verbosity : String?
    property thinking : Bool?
    property include_usage : Bool?
    property parallel_tool_calls : Bool?
    property tool_choice : ToolChoice?
    property response_format : ResponseFormat?
    property prompt_cache_key : String?
    property include : Array(String)?
    property extra_body : Hash(String, JSON::Any)?
    property extra_headers : Hash(String, String)?
    property max_retries : Int32?

    def initialize
    end

    # Merge `other` on top of self. A nil member means "inherit"; false is a
    # real override and must not be treated as missing.
    def merge(other : RequestOptions?) : RequestOptions
      return self if other.nil?

      result = RequestOptions.new
      {% for ivar in @type.instance_vars %}
        {% unless ivar.name == "extra_body" || ivar.name == "extra_headers" %}
          result.{{ ivar.name }} = self.{{ ivar.name }}
          result.{{ ivar.name }} = other.{{ ivar.name }} unless other.{{ ivar.name }}.nil?
        {% end %}
      {% end %}
      result.extra_body = merge_extra_body(extra_body, other.extra_body)
      result.extra_headers = merge_extra_headers(extra_headers, other.extra_headers)
      result
    end

    def validate! : Nil
      validate_positive("max_tokens", @max_tokens)
      validate_positive("max_completion_tokens", @max_completion_tokens)
      validate_range("temperature", @temperature, 0.0, 2.0)
      validate_range("top_p", @top_p, 0.0, 1.0)
      validate_range("presence_penalty", @presence_penalty, -2.0, 2.0)
      validate_range("frequency_penalty", @frequency_penalty, -2.0, 2.0)
      if n = @n
        raise ConfigurationError.new("n must be >= 1, got #{n}") if n < 1
        raise ConfigurationError.new("n > 1 is not supported because responses are assembled into one message") if n > 1
      end
      if (retries = @max_retries) && retries < 0
        raise ConfigurationError.new("max_retries must be non-negative, got #{retries}")
      end
      if meta = @metadata
        raise ConfigurationError.new("metadata supports at most 16 entries, got #{meta.size}") if meta.size > 16
      end
    end

    private def validate_positive(name : String, value : Int32?) : Nil
      return if value.nil?
      raise ConfigurationError.new("#{name} must be positive, got #{value}") if value <= 0
    end

    private def validate_range(name : String, value : Float64?, min : Float64, max : Float64) : Nil
      return if value.nil?
      if value < min || value > max
        raise ConfigurationError.new("#{name} must be between #{min} and #{max}, got #{value}")
      end
    end

    private def merge_extra_body(
      base : Hash(String, JSON::Any)?,
      override : Hash(String, JSON::Any)?,
    ) : Hash(String, JSON::Any)?
      return override if base.nil?
      return base if override.nil?
      base.merge(override)
    end

    private def merge_extra_headers(
      base : Hash(String, String)?,
      override : Hash(String, String)?,
    ) : Hash(String, String)?
      return override if base.nil?
      return base if override.nil?
      base.merge(override)
    end
  end
end
