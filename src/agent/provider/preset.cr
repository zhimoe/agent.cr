require "uri"

class Agent
  module Provider
    # Capability flags used by request builders and stream parsers.
    struct Capabilities
      getter max_tokens : Bool
      getter max_completion_tokens : Bool
      getter stream_usage : Bool
      getter json_schema : Bool
      getter json_object : Bool
      getter tool_choice_named : Bool
      getter tool_choice_required : Bool
      getter tool_choice_allowed : Bool
      getter parallel_tool_calls : Bool
      getter reasoning_effort : Bool
      getter verbosity : Bool
      getter temperature : Bool
      getter penalties : Bool
      getter service_tier : Bool
      getter store : Bool
      getter metadata : Bool
      getter prompt_cache_key : Bool
      getter reasoning_content_roundtrip : Bool
      getter responses_api : Bool
      getter thinking_param : String?
      getter thinking_field : String?
      getter thinking_enabled_by_default : Bool
      getter supports_forced_tool_choice_with_thinking : Bool
      getter reasoning_placeholder : String?
      getter strict_stream_end : Bool

      def initialize(
        @max_tokens : Bool = true,
        @max_completion_tokens : Bool = false,
        @stream_usage : Bool = true,
        @json_schema : Bool = false,
        @json_object : Bool = true,
        @tool_choice_named : Bool = true,
        @tool_choice_required : Bool = true,
        @tool_choice_allowed : Bool = false,
        @parallel_tool_calls : Bool = true,
        @reasoning_effort : Bool = false,
        @verbosity : Bool = false,
        @temperature : Bool = true,
        @penalties : Bool = true,
        @service_tier : Bool = false,
        @store : Bool = false,
        @metadata : Bool = false,
        @prompt_cache_key : Bool = false,
        @reasoning_content_roundtrip : Bool = false,
        @responses_api : Bool = false,
        @thinking_param : String? = nil,
        @thinking_field : String? = nil,
        @thinking_enabled_by_default : Bool = false,
        @supports_forced_tool_choice_with_thinking : Bool = true,
        @reasoning_placeholder : String? = nil,
        @strict_stream_end : Bool = false,
      )
      end
    end

    # Optional per-model capability overrides.
    struct CapabilityPatch
      getter max_tokens : Bool?
      getter max_completion_tokens : Bool?
      getter stream_usage : Bool?
      getter json_schema : Bool?
      getter json_object : Bool?
      getter tool_choice_named : Bool?
      getter tool_choice_required : Bool?
      getter tool_choice_allowed : Bool?
      getter parallel_tool_calls : Bool?
      getter reasoning_effort : Bool?
      getter verbosity : Bool?
      getter temperature : Bool?
      getter penalties : Bool?
      getter service_tier : Bool?
      getter store : Bool?
      getter metadata : Bool?
      getter prompt_cache_key : Bool?
      getter reasoning_content_roundtrip : Bool?
      getter responses_api : Bool?
      getter thinking_param : String?
      getter thinking_field : String?
      getter thinking_enabled_by_default : Bool?
      getter supports_forced_tool_choice_with_thinking : Bool?
      getter reasoning_placeholder : String?
      getter strict_stream_end : Bool?

      def initialize(
        @max_tokens : Bool? = nil,
        @max_completion_tokens : Bool? = nil,
        @stream_usage : Bool? = nil,
        @json_schema : Bool? = nil,
        @json_object : Bool? = nil,
        @tool_choice_named : Bool? = nil,
        @tool_choice_required : Bool? = nil,
        @tool_choice_allowed : Bool? = nil,
        @parallel_tool_calls : Bool? = nil,
        @reasoning_effort : Bool? = nil,
        @verbosity : Bool? = nil,
        @temperature : Bool? = nil,
        @penalties : Bool? = nil,
        @service_tier : Bool? = nil,
        @store : Bool? = nil,
        @metadata : Bool? = nil,
        @prompt_cache_key : Bool? = nil,
        @reasoning_content_roundtrip : Bool? = nil,
        @responses_api : Bool? = nil,
        @thinking_param : String? = nil,
        @thinking_field : String? = nil,
        @thinking_enabled_by_default : Bool? = nil,
        @supports_forced_tool_choice_with_thinking : Bool? = nil,
        @reasoning_placeholder : String? = nil,
        @strict_stream_end : Bool? = nil,
      )
      end

      def apply(caps : Capabilities) : Capabilities
        Capabilities.new(
          max_tokens: bool_or(@max_tokens, caps.max_tokens),
          max_completion_tokens: bool_or(@max_completion_tokens, caps.max_completion_tokens),
          stream_usage: bool_or(@stream_usage, caps.stream_usage),
          json_schema: bool_or(@json_schema, caps.json_schema),
          json_object: bool_or(@json_object, caps.json_object),
          tool_choice_named: bool_or(@tool_choice_named, caps.tool_choice_named),
          tool_choice_required: bool_or(@tool_choice_required, caps.tool_choice_required),
          tool_choice_allowed: bool_or(@tool_choice_allowed, caps.tool_choice_allowed),
          parallel_tool_calls: bool_or(@parallel_tool_calls, caps.parallel_tool_calls),
          reasoning_effort: bool_or(@reasoning_effort, caps.reasoning_effort),
          verbosity: bool_or(@verbosity, caps.verbosity),
          temperature: bool_or(@temperature, caps.temperature),
          penalties: bool_or(@penalties, caps.penalties),
          service_tier: bool_or(@service_tier, caps.service_tier),
          store: bool_or(@store, caps.store),
          metadata: bool_or(@metadata, caps.metadata),
          prompt_cache_key: bool_or(@prompt_cache_key, caps.prompt_cache_key),
          reasoning_content_roundtrip: bool_or(@reasoning_content_roundtrip, caps.reasoning_content_roundtrip),
          responses_api: bool_or(@responses_api, caps.responses_api),
          thinking_param: string_or(@thinking_param, caps.thinking_param),
          thinking_field: string_or(@thinking_field, caps.thinking_field),
          thinking_enabled_by_default: bool_or(@thinking_enabled_by_default, caps.thinking_enabled_by_default),
          supports_forced_tool_choice_with_thinking: bool_or(@supports_forced_tool_choice_with_thinking, caps.supports_forced_tool_choice_with_thinking),
          reasoning_placeholder: string_or(@reasoning_placeholder, caps.reasoning_placeholder),
          strict_stream_end: bool_or(@strict_stream_end, caps.strict_stream_end),
        )
      end

      private def bool_or(value : Bool?, fallback : Bool) : Bool
        value.nil? ? fallback : value
      end

      private def string_or(value : String?, fallback : String?) : String?
        value.nil? ? fallback : value
      end
    end

    # Provider metadata. Presets are data, not classes.
    struct Preset
      getter name : String
      getter default_base_url : String?
      getter default_model : String?
      getter env_key : String?
      getter inferred_hosts : Array(String)
      getter capabilities : Capabilities
      getter model_overrides : Array(NamedTuple(prefix: String, patch: CapabilityPatch))
      getter api_key_header : String
      getter api_key_prefix : String?
      getter default_headers : Hash(String, String)?
      getter chat_path : String
      getter responses_path : String
      getter verified_at : String?

      def initialize(
        @name : String,
        @default_base_url : String? = nil,
        @default_model : String? = nil,
        @env_key : String? = nil,
        @inferred_hosts : Array(String) = [] of String,
        @capabilities : Capabilities = Capabilities.new,
        @model_overrides : Array(NamedTuple(prefix: String, patch: CapabilityPatch)) = [] of NamedTuple(prefix: String, patch: CapabilityPatch),
        @api_key_header : String = "Authorization",
        @api_key_prefix : String? = "Bearer ",
        @default_headers : Hash(String, String)? = nil,
        @chat_path : String = "/chat/completions",
        @responses_path : String = "/responses",
        @verified_at : String? = nil,
      )
      end

      def capabilities_for(model : String) : Capabilities
        caps = @capabilities
        @model_overrides.each do |override|
          if model.downcase.starts_with?(override[:prefix].downcase)
            caps = override[:patch].apply(caps)
          end
        end
        caps
      end
    end

    # Built-in provider presets and endpoint-based inference.
    module Presets
      extend self

      OPENAI_CAPS = Capabilities.new(
        max_tokens: false,
        max_completion_tokens: true,
        stream_usage: true,
        json_schema: true,
        json_object: true,
        tool_choice_named: true,
        tool_choice_required: true,
        tool_choice_allowed: true,
        parallel_tool_calls: true,
        reasoning_effort: true,
        verbosity: true,
        temperature: true,
        penalties: true,
        service_tier: true,
        store: true,
        metadata: true,
        prompt_cache_key: true,
        responses_api: true,
        strict_stream_end: true,
      )

      MODERN_OPENAI_PATCH = CapabilityPatch.new(
        max_tokens: false,
        max_completion_tokens: true,
        temperature: false,
        penalties: false,
      )

      DEEPSEEK_CAPS = Capabilities.new(
        max_tokens: true,
        max_completion_tokens: false,
        stream_usage: true,
        json_schema: false,
        json_object: true,
        tool_choice_named: true,
        tool_choice_required: true,
        tool_choice_allowed: false,
        parallel_tool_calls: true,
        reasoning_effort: true,
        verbosity: false,
        temperature: true,
        penalties: false,
        service_tier: false,
        store: false,
        metadata: false,
        prompt_cache_key: false,
        reasoning_content_roundtrip: true,
        responses_api: false,
        thinking_param: "thinking",
        thinking_field: "reasoning_content",
        thinking_enabled_by_default: true,
        supports_forced_tool_choice_with_thinking: false,
        reasoning_placeholder: " ",
        strict_stream_end: true,
      )

      PRESETS = {
        "openai" => Preset.new(
          name: "openai",
          default_base_url: "https://api.openai.com/v1",
          default_model: "gpt-4o",
          env_key: "OPENAI_API_KEY",
          inferred_hosts: ["api.openai.com"],
          capabilities: OPENAI_CAPS,
          model_overrides: [
            {prefix: "o1", patch: MODERN_OPENAI_PATCH},
            {prefix: "o3", patch: MODERN_OPENAI_PATCH},
            {prefix: "o4", patch: MODERN_OPENAI_PATCH},
            {prefix: "gpt-5", patch: MODERN_OPENAI_PATCH},
          ],
          verified_at: "2026-11-12",
        ),
        "deepseek" => Preset.new(
          name: "deepseek",
          default_base_url: "https://api.deepseek.com",
          default_model: "deepseek-flash",
          env_key: "DEEPSEEK_API_KEY",
          inferred_hosts: ["api.deepseek.com"],
          capabilities: DEEPSEEK_CAPS,
          verified_at: "2026-11-12",
        ),
        "openrouter" => Preset.new(
          name: "openrouter",
          default_base_url: "https://openrouter.ai/api/v1",
          env_key: "OPENROUTER_API_KEY",
          inferred_hosts: ["openrouter.ai"],
          capabilities: Capabilities.new(
            max_tokens: true,
            max_completion_tokens: false,
            stream_usage: false,
            json_schema: false,
            json_object: true,
            tool_choice_named: true,
            tool_choice_required: true,
            tool_choice_allowed: false,
            parallel_tool_calls: true,
            reasoning_effort: false,
            verbosity: false,
            temperature: true,
            penalties: true,
            strict_stream_end: true,
          ),
          verified_at: "2026-11-12",
        ),
        "groq" => Preset.new(
          name: "groq",
          default_base_url: "https://api.groq.com/openai/v1",
          env_key: "GROQ_API_KEY",
          inferred_hosts: ["api.groq.com"],
          capabilities: Capabilities.new(
            max_tokens: true,
            max_completion_tokens: true,
            stream_usage: true,
            json_schema: true,
            json_object: true,
            tool_choice_named: true,
            tool_choice_required: true,
            tool_choice_allowed: false,
            parallel_tool_calls: true,
            reasoning_effort: true,
            verbosity: false,
            temperature: true,
            penalties: false,
            strict_stream_end: true,
          ),
          verified_at: "2026-11-12",
        ),
        "together" => Preset.new(
          name: "together",
          default_base_url: "https://api.together.xyz/v1",
          env_key: "TOGETHER_API_KEY",
          inferred_hosts: ["api.together.xyz", "api.together.ai"],
          capabilities: Capabilities.new(
            max_tokens: true,
            max_completion_tokens: false,
            stream_usage: true,
            json_schema: false,
            json_object: true,
            tool_choice_named: true,
            tool_choice_required: true,
            tool_choice_allowed: false,
            parallel_tool_calls: true,
            reasoning_effort: true,
            verbosity: false,
            temperature: true,
            penalties: true,
            strict_stream_end: true,
          ),
          verified_at: "2026-11-12",
        ),
        "ollama" => Preset.new(
          name: "ollama",
          default_base_url: "http://localhost:11434/v1",
          inferred_hosts: ["localhost:11434"],
          capabilities: Capabilities.new(
            max_tokens: true,
            max_completion_tokens: false,
            stream_usage: false,
            json_schema: true,
            json_object: true,
            tool_choice_named: true,
            tool_choice_required: true,
            tool_choice_allowed: false,
            parallel_tool_calls: true,
            reasoning_effort: true,
            verbosity: false,
            temperature: true,
            penalties: true,
            strict_stream_end: false,
          ),
          verified_at: "2026-11-12",
        ),
        "vllm" => Preset.new(
          name: "vllm",
          default_base_url: "http://localhost:8000/v1",
          env_key: "VLLM_API_KEY",
          inferred_hosts: ["localhost:8000"],
          capabilities: Capabilities.new(
            max_tokens: true,
            max_completion_tokens: false,
            stream_usage: true,
            json_schema: true,
            json_object: true,
            tool_choice_named: true,
            tool_choice_required: true,
            tool_choice_allowed: false,
            parallel_tool_calls: true,
            reasoning_effort: true,
            verbosity: false,
            temperature: true,
            penalties: true,
            strict_stream_end: false,
          ),
          verified_at: "2026-11-12",
        ),
        "custom" => Preset.new(
          name: "custom",
          capabilities: Capabilities.new(
            max_tokens: true,
            max_completion_tokens: false,
            stream_usage: true,
            json_schema: false,
            json_object: true,
            tool_choice_named: true,
            tool_choice_required: true,
            tool_choice_allowed: false,
            parallel_tool_calls: true,
            reasoning_effort: false,
            verbosity: false,
            temperature: true,
            penalties: true,
            strict_stream_end: false,
          ),
          verified_at: "2026-11-12",
        ),
      }

      def names : Array(String)
        PRESETS.keys
      end

      def fetch(name : String) : Preset
        key = name.downcase
        PRESETS[key]? || raise ConfigurationError.new(
          "Unknown provider '#{name}'. Available providers: #{names.join(", ")}"
        )
      end

      # Infer a preset from an endpoint. Unknown endpoints use the conservative
      # `custom` preset; nil means the default OpenAI endpoint.
      #
      # Match the parsed host exactly (and host:port for local servers). Do not
      # use substring matching: `api.openai.com.evil.test` must not inherit the
      # OpenAI env key.
      def infer(endpoint : String?) : Preset
        return PRESETS["openai"] if endpoint.nil?

        uri = begin
          URI.parse(endpoint)
        rescue URI::Error
          nil
        end
        host = uri.try(&.host)
        port = uri.try(&.port)
        host_port = host ? "#{host}:#{port}" : nil

        PRESETS.each_value do |preset|
          preset.inferred_hosts.each do |known|
            if known.includes?(':')
              return preset if host_port == known
            else
              return preset if host == known
            end
          end
        end
        PRESETS["custom"]
      end
    end
  end
end
