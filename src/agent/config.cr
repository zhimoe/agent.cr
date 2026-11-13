require "uri"

class Agent
  class Config
    getter api_endpoint : String
    getter api_key : String?
    getter model : String
    getter system_prompt : String?
    getter max_tokens : Int32?
    getter temperature : Float64?
    getter read_timeout : Time::Span?
    getter connect_timeout : Time::Span?
    getter max_history : Int32?
    getter? auto_execute_tools : Bool
    getter extra_headers : Hash(String, String)?
    getter max_tool_iterations : Int32?
    # Explicit prompt cache key. If nil, Agent auto-generates one as
    # "agent-cr:<16-char-hex>" from its own session_id.
    getter prompt_cache_key : String?

    # Provider preset and resolved modern-request settings.
    getter provider_name : String
    getter preset : Provider::Preset
    getter? provider_explicit : Bool
    getter? api_key_explicit : Bool
    getter fallbacks : Array(Config)
    getter request_options : RequestOptions
    getter api_style : Symbol
    getter retry_policy : RetryPolicy
    getter? strict_stream_end : Bool
    getter capabilities : Provider::Capabilities
    getter api_path : String?
    getter query_params : Hash(String, String)

    # --- Per-read SSE timeout knobs ---
    # See AGENTS.md "dynamic read-timeout to fail-fast on hung SSE connections".
    # All are applied to the persistent HTTP client's per-read socket timeout.
    # `read_timeout` (above) is the legacy total-read timeout; if both are set,
    # the dynamic first-byte / idle timeouts win for SSE streaming.

    # Floor for the first-byte (TTFT) timeout. Small prompts that emit nothing
    # for this long are considered dead.
    getter first_byte_timeout_min : Time::Span
    # Cap for the first-byte timeout — fail-fast ceiling even for huge prompts.
    getter first_byte_timeout_max : Time::Span
    # Routing + provider queue baseline added to the prompt-size estimate.
    getter first_byte_timeout_base : Time::Span
    # ms added per estimated input token (4 chars/token estimate).
    getter first_byte_timeout_ms_per_token : Int32
    # Gap allowed between any two consecutive lines mid-stream.
    getter idle_byte_timeout : Time::Span
    # Master switch — `false` disables dynamic first-byte; both the first
    # read and subsequent reads fall back to `idle_byte_timeout`.
    getter? compute_first_byte_timeout : Bool

    # Cached parsed URI — computed once at construction.
    getter parsed_uri : URI

    def initialize(
      api_key : String? = nil,
      api_endpoint : String? = nil,
      model : String? = nil,
      @system_prompt : String? = nil,
      @max_tokens : Int32? = nil,
      @temperature : Float64? = nil,
      read_timeout : Time::Span | Int32? = nil,
      connect_timeout : Time::Span | Int32? = nil,
      @max_history : Int32? = nil,
      @auto_execute_tools : Bool = true,
      @extra_headers : Hash(String, String)? = nil,
      @max_tool_iterations : Int32? = 100,
      @prompt_cache_key : String? = nil,
      provider : String? = nil,
      fallbacks : Array(Config)? = nil,
      request_options : RequestOptions? = nil,
      api_style : Symbol? = nil,
      api_path : String? = nil,
      query_params : Hash(String, String)? = nil,
      capabilities_override : Provider::CapabilityPatch? = nil,
      strict_stream_end : Bool? = nil,
      retry_policy : RetryPolicy? = nil,
      max_retries : Int32? = nil,
      retry_backoff_base : Time::Span | Int32? = nil,
      retry_backoff_max : Time::Span | Int32? = nil,
      max_retry_after : Time::Span | Int32? = nil,
      *,
      first_byte_timeout_min : Time::Span | Int32 = 60,
      first_byte_timeout_max : Time::Span | Int32 = 300,
      first_byte_timeout_base : Time::Span | Int32 = 3,
      @first_byte_timeout_ms_per_token : Int32 = 3,
      idle_byte_timeout : Time::Span | Int32 = 60,
      @compute_first_byte_timeout : Bool = true,
    )
      @provider_explicit = !provider.nil?
      @api_key_explicit = !api_key.nil?

      preset = provider ? Provider::Presets.fetch(provider) : Provider::Presets.infer(api_endpoint)
      @preset = preset
      @provider_name = preset.name

      @api_endpoint = api_endpoint || preset.default_base_url ||
                      raise ConfigurationError.new("api_endpoint is required for provider '#{preset.name}'")

      if model.nil? && preset.default_model.nil?
        if preset.name != "custom"
          raise ConfigurationError.new("model is required for provider '#{preset.name}'")
        end
        Log.warn { "No model configured for provider '#{preset.name}'; falling back to gpt-4o" }
      end
      @model = model || preset.default_model || "gpt-4o"
      raise ConfigurationError.new("model must not be empty") if @model.empty?
      if preset.name == "deepseek" && {"deepseek-chat", "deepseek-reasoner"}.includes?(@model)
        Log.warn do
          "DeepSeek model '#{@model}' was retired on 2026-07-24; " \
          "use 'deepseek-flash' or 'deepseek-v4-pro'"
        end
      end

      allow_env_key = @provider_explicit || (!api_endpoint.nil? && preset.name != "custom")
      @api_key = api_key || (allow_env_key ? env_key_for(preset) : nil)

      @capabilities = preset.capabilities_for(@model)
      @capabilities = capabilities_override.apply(@capabilities) if capabilities_override

      @api_style = api_style || :chat_completions
      validate_api_style(@api_style)

      @fallbacks = fallbacks || [] of Config
      @fallbacks.each do |fallback|
        unless fallback.fallbacks.empty?
          raise ConfigurationError.new("nested fallbacks are not supported")
        end
      end

      @api_path = api_path
      @query_params = query_params || {} of String => String
      strict_override = strict_stream_end
      @strict_stream_end = strict_override.nil? ? @capabilities.strict_stream_end : strict_override

      validate_temperature(@temperature)
      validate_max_tokens(@max_tokens)
      validate_max_history(@max_history)
      validate_max_tool_iterations(@max_tool_iterations)

      @read_timeout = parse_timeout(read_timeout)
      @connect_timeout = parse_timeout(connect_timeout)

      @retry_policy = retry_policy || RetryPolicy.new(
        max_retries: max_retries || 2,
        backoff_base: parse_timeout(retry_backoff_base) || 500.milliseconds,
        backoff_max: parse_timeout(retry_backoff_max) || 8.seconds,
        max_retry_after: parse_timeout(max_retry_after) || 120.seconds,
      )

      @request_options = fold_legacy_options(request_options)
      @request_options.validate!

      # SSE per-read timeouts. Same Int32-or-Span convenience as the legacy
      # timeouts above.
      @first_byte_timeout_min = parse_timeout(first_byte_timeout_min) || 60.seconds
      @first_byte_timeout_max = parse_timeout(first_byte_timeout_max) || 300.seconds
      @first_byte_timeout_base = parse_timeout(first_byte_timeout_base) || 3.seconds
      @idle_byte_timeout = parse_timeout(idle_byte_timeout) || 60.seconds
      validate_first_byte_timeout_bounds

      # Validate and parse the endpoint URI
      @parsed_uri = URI.parse(@api_endpoint)
      unless @parsed_uri.scheme && @parsed_uri.host
        raise ArgumentError.new("api_endpoint must be a valid URL, got #{@api_endpoint}")
      end
    end

    def max_retries : Int32
      @retry_policy.max_retries
    end

    private def fold_legacy_options(options : RequestOptions?) : RequestOptions
      legacy = RequestOptions.new
      legacy.max_tokens = @max_tokens
      legacy.temperature = @temperature
      legacy.merge(options)
    end

    private def env_key_for(preset : Provider::Preset) : String?
      if key = preset.env_key
        ENV[key]?
      end
    end

    private def validate_api_style(style : Symbol) : Nil
      unless style == :chat_completions || style == :responses
        raise ConfigurationError.new("api_style must be :chat_completions or :responses, got #{style}")
      end
      if style == :responses && !@capabilities.responses_api
        raise ConfigurationError.new("Provider '#{@provider_name}' does not support the Responses API")
      end
    end

    private def validate_temperature(t : Float64?) : Nil
      if t && (t < 0.0 || t > 2.0)
        raise ArgumentError.new("temperature must be between 0.0 and 2.0, got #{t}")
      end
    end

    private def validate_max_tokens(mt : Int32?) : Nil
      if mt && mt <= 0
        raise ArgumentError.new("max_tokens must be positive, got #{mt}")
      end
    end

    private def validate_max_history(mh : Int32?) : Nil
      if mh && mh < 0
        raise ArgumentError.new("max_history must be non-negative, got #{mh}")
      end
    end

    # NOTE: max_history: 0 and nil both mean "no limit" (never trim).

    private def validate_max_tool_iterations(mti : Int32?) : Nil
      if mti && mti < 1
        raise ArgumentError.new("max_tool_iterations must be >= 1, got #{mti}")
      end
    end

    private def parse_timeout(timeout : Time::Span | Int32?) : Time::Span?
      case timeout
      when Int32      then timeout.seconds
      when Time::Span then timeout
      end
    end

    private def validate_first_byte_timeout_bounds : Nil
      if @first_byte_timeout_min < Time::Span.zero
        raise ArgumentError.new("first_byte_timeout_min must be non-negative, got #{@first_byte_timeout_min}")
      end
      if @first_byte_timeout_max < @first_byte_timeout_min
        raise ArgumentError.new("first_byte_timeout_max (#{@first_byte_timeout_max}) must be >= first_byte_timeout_min (#{@first_byte_timeout_min})")
      end
      if @first_byte_timeout_base < Time::Span.zero
        raise ArgumentError.new("first_byte_timeout_base must be non-negative, got #{@first_byte_timeout_base}")
      end
      if @first_byte_timeout_ms_per_token < 0
        raise ArgumentError.new("first_byte_timeout_ms_per_token must be non-negative, got #{@first_byte_timeout_ms_per_token}")
      end
      if @idle_byte_timeout < Time::Span.zero
        raise ArgumentError.new("idle_byte_timeout must be non-negative, got #{@idle_byte_timeout}")
      end
    end

    # Compute the first-byte (TTFT) read timeout for a request whose wire
    # body is `prompt_bytes` long. Returns nil if dynamic first-byte timeouts
    # are disabled (`compute_first_byte_timeout? == false`) — callers should
    # fall back to `idle_byte_timeout` in that case.
    #
    # Formula (AGENTS.md):
    #   estimated_tokens = prompt_bytes / 4
    #   timeout = clamp(base + estimated_tokens * ms_per_token, min, max)
    def compute_first_byte_timeout(prompt_bytes : Int) : Time::Span?
      return unless @compute_first_byte_timeout
      estimated_tokens = (prompt_bytes.to_i64 / 4)
      timeout_ms = @first_byte_timeout_base.total_milliseconds.to_i64 +
                   estimated_tokens * @first_byte_timeout_ms_per_token.to_i64
      timeout = timeout_ms.milliseconds
      timeout.clamp(@first_byte_timeout_min, @first_byte_timeout_max)
    end

    # The per-read timeout actually applied to the HTTP client for a request
    # with the given prompt body size. When dynamic first-byte is disabled,
    # both the first read and subsequent reads use `idle_byte_timeout`.
    #
    # When dynamic first-byte is enabled, the *client*'s `read_timeout` is set to
    # the **smaller** of (first_byte_timeout, idle_byte_timeout). HTTP::Client
    # only honours `read_timeout` at socket-open time and there is no portable
    # way to mutate the per-read timeout mid-stream on `http_resp.body_io`
    # (HTTP::ChunkedContent does not surface `read_timeout=`). Taking the min
    # means idle fail-fast on a hung TTFT is preserved (idle budget wins), and
    # mid-stream stalls honour `idle_byte_timeout`. The provider's `parse_stream`
    # additionally re-applies `read_timeout=` to the body_io per successful read
    # when the IO supports it (true socket IOs that surface the setter), which
    # restores the first-byte-generous-then-idle-tight switch for those IOs.
    def effective_read_timeout(prompt_bytes : Int) : Time::Span?
      fb = compute_first_byte_timeout(prompt_bytes)
      return @idle_byte_timeout unless fb
      fb < @idle_byte_timeout ? fb : @idle_byte_timeout
    end

    # The chat completions path derived from api_endpoint.
    # Normalises duplicate slashes in the endpoint path.
    def chat_path : String
      build_path(@preset.chat_path)
    end

    def responses_path : String
      build_path(@preset.responses_path)
    end

    private def build_path(suffix : String) : String
      if path = @api_path
        return path.starts_with?("/") ? path : "/#{path}"
      end
      base_path = @parsed_uri.path.empty? || @parsed_uri.path == "/" ? "" : @parsed_uri.path.rstrip('/')
      # Normalize duplicate slashes (e.g. "//v1" -> "/v1")
      normalized = "#{base_path}/#{suffix.lstrip('/')}".gsub(/\/+/, "/")
      normalized = "/#{normalized}" unless normalized.starts_with?("/")
      normalized
    end
  end
end
