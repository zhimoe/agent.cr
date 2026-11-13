require "json"
require "../base"

class Agent
  module Provider
    class Responses < Base
      # Converts canonical messages/options into the Responses API body.
      module RequestBody
        extend self

        RESERVED_KEYS = %w[
          model input instructions stream tools tool_choice text
          max_output_tokens include prompt_cache_key
        ]

        def build(
          messages : Array(Message),
          tools : Array(Tool)?,
          config : Agent::Config,
          cache_key : String,
          options : RequestOptions,
        ) : Hash(String, JSON::Any)
          caps = config.capabilities
          input = [] of JSON::Any
          instructions = [] of String

          messages.each do |message|
            case message.role
            when Role::System
              if content = message.content
                instructions << content unless content.empty?
              end
            when Role::User
              input << user_item(message)
            when Role::Assistant
              if items = replayable_items(message, config)
                items.each { |item| input << item }
              else
                assistant_items(message, input)
              end
            when Role::Tool
              input << tool_result_item(message)
            end
          end

          body = {
            "model"  => JSON::Any.new(config.model),
            "stream" => JSON::Any.new(true),
            "input"  => JSON::Any.new(input),
          }
          body["instructions"] = JSON::Any.new(instructions.join("\n\n")) unless instructions.empty?

          if tools && !tools.empty?
            body["tools"] = JSON::Any.new(tools.map(&.to_responses_json))
          end

          add_options(body, caps, options, config, cache_key)

          extra = merge_hashes(config.request_options.extra_body, options.extra_body)
          merge_extra_body!(body, extra)

          body
        end

        private def user_item(message : Message) : JSON::Any
          if parts = message.content_parts
            content = parts.map { |part| content_part(part) }
            JSON::Any.new({
              "role"    => JSON::Any.new("user"),
              "content" => JSON::Any.new(content),
            })
          else
            text = message.content || ""
            JSON::Any.new({
              "role"    => JSON::Any.new("user"),
              "content" => JSON::Any.new([
                JSON::Any.new({
                  "type" => JSON::Any.new("input_text"),
                  "text" => JSON::Any.new(text),
                }),
              ]),
            })
          end
        end

        private def content_part(part : ContentPart) : JSON::Any
          case part.type
          when ContentPart::PartType::Text
            JSON::Any.new({
              "type" => JSON::Any.new("input_text"),
              "text" => JSON::Any.new(part.text || ""),
            })
          when ContentPart::PartType::ImageUrl
            item = {
              "type"      => JSON::Any.new("input_image"),
              "image_url" => JSON::Any.new(part.url || ""),
            } of String => JSON::Any
            if detail = part.image_detail
              item["detail"] = JSON::Any.new(detail)
            end
            JSON::Any.new(item)
          when ContentPart::PartType::File
            item = {
              "type"      => JSON::Any.new("input_file"),
              "file_data" => JSON::Any.new(part.url || ""),
            } of String => JSON::Any
            if filename = part.filename
              item["filename"] = JSON::Any.new(filename)
            end
            JSON::Any.new(item)
          when ContentPart::PartType::InputAudio
            raise UnsupportedCapabilityError.new(
              "responses", "input", "audio input content"
            )
          else
            raise UnsupportedCapabilityError.new(
              "responses", "input", "unsupported content part"
            )
          end
        end

        private def assistant_items(message : Message, input : Array(JSON::Any)) : Nil
          if content = message.content
            unless content.empty?
              input << JSON::Any.new({
                "role"    => JSON::Any.new("assistant"),
                "content" => JSON::Any.new(content),
              })
            end
          end

          if tool_calls = message.tool_calls
            tool_calls.each do |tool_call|
              input << JSON::Any.new({
                "type"      => JSON::Any.new("function_call"),
                "call_id"   => JSON::Any.new(tool_call.id),
                "name"      => JSON::Any.new(tool_call.name),
                "arguments" => JSON::Any.new(tool_call.arguments),
              })
            end
          end
        end

        private def tool_result_item(message : Message) : JSON::Any
          JSON::Any.new({
            "type"    => JSON::Any.new("function_call_output"),
            "call_id" => JSON::Any.new(message.tool_call_id || ""),
            "output"  => JSON::Any.new(message.content || ""),
          })
        end

        private def replayable_items(message : Message, config : Agent::Config) : Array(JSON::Any)?
          data = message.provider_data
          return unless data
          hash = data.as_h?
          return unless hash
          return unless hash["provider"]?.try(&.as_s?) == config.provider_name
          return unless hash["model"]?.try(&.as_s?) == config.model
          items = hash["items"]?.try(&.as_a?)
          return if items.nil? || items.empty?
          items
        end

        private def add_options(
          body : Hash(String, JSON::Any),
          caps : Agent::Provider::Capabilities,
          options : RequestOptions,
          config : Agent::Config,
          cache_key : String,
        ) : Nil
          if max_tokens = options.max_completion_tokens || options.max_tokens
            body["max_output_tokens"] = JSON::Any.new(max_tokens.to_i64)
          end

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

          unless options.thinking.nil?
            raise UnsupportedCapabilityError.new(config.provider_name, config.model, "thinking")
          end

          if value = options.reasoning_effort
            if caps.reasoning_effort
              body["reasoning"] = JSON::Any.new({"effort" => JSON::Any.new(value)})
            else
              warn_unsupported(config, "reasoning_effort")
            end
          end

          parallel = options.parallel_tool_calls
          unless parallel.nil?
            if caps.parallel_tool_calls
              body["parallel_tool_calls"] = JSON::Any.new(parallel)
            else
              warn_unsupported(config, "parallel_tool_calls")
            end
          end

          if choice = options.tool_choice
            check_tool_choice!(choice, caps, config)
            body["tool_choice"] = choice.to_responses_json
          end

          add_text_config(body, caps, options, config)

          store = options.store
          unless store.nil?
            if caps.store
              body["store"] = JSON::Any.new(store)
            else
              warn_unsupported(config, "store")
            end
          end
          body["store"] = JSON::Any.new(false) unless body.has_key?("store")

          if value = options.service_tier
            if caps.service_tier
              body["service_tier"] = JSON::Any.new(value)
            else
              warn_unsupported(config, "service_tier")
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

          cache_value = options.prompt_cache_key ||
                        (config.prompt_cache_key ? cache_key : nil)
          if cache_value
            if caps.prompt_cache_key
              body["prompt_cache_key"] = JSON::Any.new(cache_value)
            else
              warn_unsupported(config, "prompt_cache_key")
            end
          end

          includes = options.include || [] of String
          if body["store"]?.try(&.as_bool?) == false && options.reasoning_effort
            includes = includes + ["reasoning.encrypted_content"]
          end
          body["include"] = JSON::Any.new(includes.map { |v| JSON::Any.new(v) }) unless includes.empty?
        end

        private def add_text_config(
          body : Hash(String, JSON::Any),
          caps : Agent::Provider::Capabilities,
          options : RequestOptions,
          config : Agent::Config,
        ) : Nil
          text = {} of String => JSON::Any

          if format = options.response_format
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
            text["format"] = format.to_responses_json
          end

          if value = options.verbosity
            if caps.verbosity
              text["verbosity"] = JSON::Any.new(value)
            else
              warn_unsupported(config, "verbosity")
            end
          end

          body["text"] = JSON::Any.new(text) unless text.empty?
        end

        private def check_tool_choice!(
          choice : ToolChoice,
          caps : Agent::Provider::Capabilities,
          config : Agent::Config,
        ) : Nil
          return unless choice.forced?

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
