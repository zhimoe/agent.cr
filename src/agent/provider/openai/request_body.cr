require "json"
require "../base"

class Agent
  module Provider
    class OpenAI < Base
      # Builds the JSON request body for OpenAI-compatible Chat Completions.
      module RequestBody
        extend self

        RESERVED_KEYS = %w[
          model messages stream tools tool_choice response_format
          max_tokens max_completion_tokens prompt_cache_key
        ]

        def build(
          messages : Array(Message),
          tools : Array(Tool)?,
          config : Agent::Config,
          cache_key : String,
          options : RequestOptions,
        ) : Hash(String, JSON::Any)
          caps = config.capabilities
          tools_present = !tools.nil? && !tools.empty?

          body = {
            "model"    => JSON::Any.new(config.model),
            "messages" => JSON::Any.new(messages.map { |m| JSON::Any.new(message_body(m, caps, tools_present)) }),
            "stream"   => JSON::Any.new(true),
          }

          if caps.stream_usage && options.include_usage != false
            body["stream_options"] = JSON::Any.new({"include_usage" => JSON::Any.new(true)})
          end

          token_key, token_value = effective_max_tokens(caps, options)
          if token_key && token_value
            body[token_key] = JSON::Any.new(token_value.to_i64)
          end

          add_sampling(body, caps, options, config)
          add_reasoning(body, caps, options, config)
          add_tool_choice(body, caps, options, config)
          add_response_format(body, caps, options, config)
          add_misc(body, caps, options, config)

          if tools && !tools.empty?
            body["tools"] = JSON::Any.new(tools.map(&.to_chat_json))
          end

          cache_value = options.prompt_cache_key ||
                        (config.prompt_cache_key ? cache_key : nil)
          if cache_value
            if caps.prompt_cache_key
              body["prompt_cache_key"] = JSON::Any.new(cache_value)
            else
              warn_unsupported(config, "prompt_cache_key")
            end
          end

          extra = merge_hashes(
            config.request_options.extra_body,
            options.extra_body,
          )
          merge_extra_body!(body, extra)

          body
        end

        private def message_body(
          message : Message,
          caps : Agent::Provider::Capabilities,
          tools_present : Bool,
        ) : Hash(String, JSON::Any)
          include_reasoning = caps.reasoning_content_roundtrip && tools_present
          message.to_request_body(
            include_reasoning_content: include_reasoning,
            reasoning_placeholder: caps.reasoning_placeholder,
          )
        end

        private def effective_max_tokens(
          caps : Agent::Provider::Capabilities,
          options : RequestOptions,
        ) : {String?, Int32?}
          if caps.max_completion_tokens && (value = options.max_completion_tokens || options.max_tokens)
            {"max_completion_tokens", value}
          elsif caps.max_tokens && (value = options.max_tokens || options.max_completion_tokens)
            {"max_tokens", value}
          else
            {nil, nil}
          end
        end

        private def add_sampling(
          body : Hash(String, JSON::Any),
          caps : Agent::Provider::Capabilities,
          options : RequestOptions,
          config : Agent::Config,
        ) : Nil
          if value = options.temperature
            if caps.temperature
              body["temperature"] = JSON::Any.new(value)
            else
              warn_unsupported(config, "temperature")
            end
          end

          if value = options.top_p
            body["top_p"] = JSON::Any.new(value)
          end
          if value = options.seed
            body["seed"] = JSON::Any.new(value)
          end
          if value = options.n
            body["n"] = JSON::Any.new(value.to_i64)
          end

          if value = options.presence_penalty
            if caps.penalties
              body["presence_penalty"] = JSON::Any.new(value)
            else
              warn_unsupported(config, "presence_penalty")
            end
          end

          if value = options.frequency_penalty
            if caps.penalties
              body["frequency_penalty"] = JSON::Any.new(value)
            else
              warn_unsupported(config, "frequency_penalty")
            end
          end

          if stop = options.stop
            case stop
            when String
              body["stop"] = JSON::Any.new(stop)
            when Array(String)
              body["stop"] = JSON::Any.new(stop.map { |s| JSON::Any.new(s) })
            end
          end
        end

        private def add_reasoning(
          body : Hash(String, JSON::Any),
          caps : Agent::Provider::Capabilities,
          options : RequestOptions,
          config : Agent::Config,
        ) : Nil
          thinking = options.thinking
          unless thinking.nil?
            if param = caps.thinking_param
              body[param] = JSON::Any.new({
                "type" => JSON::Any.new(thinking ? "enabled" : "disabled"),
              })
            else
              raise UnsupportedCapabilityError.new(
                config.provider_name, config.model, "thinking"
              )
            end
          end

          if value = options.reasoning_effort
            if caps.reasoning_effort
              body["reasoning_effort"] = JSON::Any.new(value)
            else
              warn_unsupported(config, "reasoning_effort")
            end
          end

          if value = options.verbosity
            if caps.verbosity
              body["verbosity"] = JSON::Any.new(value)
            else
              warn_unsupported(config, "verbosity")
            end
          end
        end

        private def add_tool_choice(
          body : Hash(String, JSON::Any),
          caps : Agent::Provider::Capabilities,
          options : RequestOptions,
          config : Agent::Config,
        ) : Nil
          choice = options.tool_choice
          return if choice.nil?

          if choice.forced?
            thinking = options.thinking
            thinking_on = thinking.nil? ? caps.thinking_enabled_by_default : thinking
            if thinking_on && !caps.supports_forced_tool_choice_with_thinking
              raise UnsupportedCapabilityError.new(
                config.provider_name, config.model, "forced tool_choice while thinking is enabled"
              )
            end
          end

          case choice.kind
          when ToolChoice::Kind::Function
            unless caps.tool_choice_named
              raise UnsupportedCapabilityError.new(config.provider_name, config.model, "named tool_choice")
            end
          when ToolChoice::Kind::Required
            unless caps.tool_choice_required
              raise UnsupportedCapabilityError.new(config.provider_name, config.model, "required tool_choice")
            end
          when ToolChoice::Kind::AllowedTools
            unless caps.tool_choice_allowed
              raise UnsupportedCapabilityError.new(config.provider_name, config.model, "allowed_tools tool_choice")
            end
          end

          body["tool_choice"] = choice.to_chat_json
        end

        private def add_response_format(
          body : Hash(String, JSON::Any),
          caps : Agent::Provider::Capabilities,
          options : RequestOptions,
          config : Agent::Config,
        ) : Nil
          format = options.response_format
          return if format.nil?

          case format.kind
          when ResponseFormat::Kind::JsonObject
            unless caps.json_object
              raise UnsupportedCapabilityError.new(config.provider_name, config.model, "response_format json_object")
            end
          when ResponseFormat::Kind::JsonSchema
            unless caps.json_schema
              raise UnsupportedCapabilityError.new(config.provider_name, config.model, "response_format json_schema")
            end
          end

          body["response_format"] = format.to_chat_json
        end

        private def add_misc(
          body : Hash(String, JSON::Any),
          caps : Agent::Provider::Capabilities,
          options : RequestOptions,
          config : Agent::Config,
        ) : Nil
          parallel = options.parallel_tool_calls
          unless parallel.nil?
            if caps.parallel_tool_calls
              body["parallel_tool_calls"] = JSON::Any.new(parallel)
            else
              warn_unsupported(config, "parallel_tool_calls")
            end
          end

          if value = options.service_tier
            if caps.service_tier
              body["service_tier"] = JSON::Any.new(value)
            else
              warn_unsupported(config, "service_tier")
            end
          end

          store = options.store
          unless store.nil?
            if caps.store
              body["store"] = JSON::Any.new(store)
            else
              warn_unsupported(config, "store")
            end
          end

          if metadata = options.metadata
            if caps.metadata
              json_metadata = {} of String => JSON::Any
              metadata.each { |k, v| json_metadata[k] = JSON::Any.new(v) }
              body["metadata"] = JSON::Any.new(json_metadata)
            else
              warn_unsupported(config, "metadata")
            end
          end

          if options.include
            warn_unsupported(config, "include")
          end
        end

        private def merge_hashes(
          base : Hash(String, JSON::Any)?,
          override : Hash(String, JSON::Any)?,
        ) : Hash(String, JSON::Any)?
          return override if base.nil?
          return base if override.nil?
          base.merge(override)
        end

        private def merge_extra_body!(
          body : Hash(String, JSON::Any),
          extra : Hash(String, JSON::Any)?,
        ) : Nil
          return if extra.nil?

          extra.each do |key, value|
            if RESERVED_KEYS.includes?(key)
              raise ConfigurationError.new("extra_body cannot override reserved key '#{key}'")
            end

            if key == "stream_options"
              existing = body["stream_options"]?.try(&.as_h?)
              incoming = value.as_h?
              if existing && incoming
                body["stream_options"] = JSON::Any.new(existing.merge(incoming))
                next
              end
            end

            body[key] = value
          end
        end

        private def warn_unsupported(config : Agent::Config, parameter : String) : Nil
          Log.warn do
            "Provider '#{config.provider_name}' model '#{config.model}' does not support '#{parameter}'; ignoring it"
          end
        end
      end
    end
  end
end
