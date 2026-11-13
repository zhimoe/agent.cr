require "json"
require "../base"

class Agent
  module Provider
    class Responses < Base
      # Parses the Responses API SSE event stream.
      module StreamParser
        extend self

        private class ToolCallState
          property id : String
          property call_id : String
          property name : String
          property arguments : String

          def initialize
            @id = ""
            @call_id = ""
            @name = ""
            @arguments = ""
          end
        end

        private class State
          property content = ""
          property reasoning = ""
          getter tool_calls = {} of String => ToolCallState
          getter tool_order = [] of String
          property usage : Usage = Usage.new
          property finish_reason : String?
          property response_id : String?
          property terminal = false
          property saw_done = false
          property reasoning_kind : String?
          property final_response : JSON::Any?
          property content_done : String?
          property cancelled = false
        end

        def parse(
          body_io : IO,
          response : Response,
          cancel : -> Bool,
          *,
          first_byte_timeout : Time::Span? = nil,
          idle_timeout : Time::Span? = nil,
          strict_end : Bool = false,
          provider_name : String? = nil,
          model : String? = nil,
        ) : {Message, Usage, String?}
          state = State.new
          event_name = nil
          data_lines = [] of String
          read_count = 0

          effective_first = first_byte_timeout || idle_timeout
          apply_read_timeout(body_io, effective_first) if effective_first

          loop do
            if cancel.call
              state.cancelled = true
              break
            end

            line = begin
              body_io.gets(chomp: true)
            rescue ex : IO::TimeoutError
              phase = read_count.zero? ? :first_byte : :idle
              timeout = read_count.zero? ? effective_first : idle_timeout
              raise IdleTimeoutError.new(phase, timeout, cause: ex)
            end
            break if line.nil?
            read_count += 1

            if idle_timeout && idle_timeout != effective_first
              apply_read_timeout(body_io, idle_timeout)
            end

            stripped = line.strip
            if stripped.empty?
              dispatch_frame(state, response, event_name, data_lines)
              event_name = nil
              data_lines.clear
              next
            end

            if stripped.starts_with?("event:")
              event_name = stripped[6..].strip
            elsif stripped.starts_with?("data:")
              data_lines << stripped[5..].lstrip(' ')
            elsif stripped.starts_with?(":")
              # SSE comment / heartbeat
            end
          end

          dispatch_frame(state, response, event_name, data_lines) unless data_lines.empty?

          if !state.cancelled && !state.terminal && !state.saw_done
            if !response.output_started?
              raise StreamTruncatedError.new("stream ended without any output or terminal event")
            elsif strict_end
              raise StreamTruncatedError.new("stream ended without a terminal event")
            end
          end

          message = build_final_message(state, provider_name, model)
          {message, state.usage, final_reason(state, message)}
        end

        private def dispatch_frame(
          state : State,
          response : Response,
          event_name : String?,
          data_lines : Array(String),
        ) : Nil
          return if data_lines.empty?
          raw = data_lines.join('\n')
          if raw.strip == "[DONE]"
            state.saw_done = true
            return
          end

          parsed = begin
            JSON.parse(raw)
          rescue JSON::ParseException
            return
          end
          data = parsed.as_h?
          return if data.nil?

          type = event_name
          type = data["type"]?.try(&.as_s?) if type.nil? || type.empty?
          return if type.nil? || type.empty?

          case type
          when "response.created", "response.in_progress"
            state.response_id ||= response_id_from(data)
          when "response.output_item.added"
            if item = data["item"]?.try(&.as_h?)
              handle_item_added(state, response, data, item)
            end
          when "response.output_text.delta"
            if delta = data["delta"]?.try(&.as_s?)
              state.content += delta
              response.push_chunk(Response::Chunk.new(delta, Response::ChunkKind::Content))
            end
          when "response.output_text.done"
            if text = data["text"]?.try(&.as_s?)
              state.content_done = text if state.content.empty?
            end
          when "response.reasoning_text.delta", "response.reasoning_summary_text.delta"
            if delta = data["delta"]?.try(&.as_s?)
              state.reasoning_kind ||= type
              if state.reasoning_kind == type
                state.reasoning += delta
                response.push_chunk(Response::Chunk.new(delta, Response::ChunkKind::Reasoning))
              end
            end
          when "response.refusal.delta"
            if delta = data["delta"]?.try(&.as_s?)
              state.content += delta
              response.push_chunk(Response::Chunk.new(delta, Response::ChunkKind::Content))
            end
          when "response.function_call_arguments.delta"
            if key = item_key(data)
              if delta = data["delta"]?.try(&.as_s?)
                tool = tool_state(state, key)
                tool.arguments += delta
                response.push_chunk(Response::Chunk.new(delta, Response::ChunkKind::ToolCallArgs))
              end
            end
          when "response.function_call_arguments.done"
            if key = item_key(data)
              if args = data["arguments"]?.try(&.as_s?)
                tool_state(state, key).arguments = args
              end
            end
          when "response.output_item.done"
            if item = data["item"]?.try(&.as_h?)
              handle_item_done(state, data, item)
            end
          when "response.completed", "response.incomplete"
            state.terminal = true
            if response_any = data["response"]?
              state.final_response = response_any
              if response_hash = response_any.as_h?
                state.response_id ||= response_hash["id"]?.try(&.as_s?)
                state.usage = Usage.from_responses(response_hash["usage"]?.try(&.as_h?))
                if type == "response.incomplete"
                  details = response_hash["incomplete_details"]?.try(&.as_h?)
                  reason = details.try { |d| d["reason"]?.try(&.as_s?) }
                  state.finish_reason = map_incomplete_reason(reason)
                end
              end
            end
          when "response.failed"
            state.terminal = true
            error_payload = data["response"]?.try(&.as_h?).try { |h| h["error"]? }
            raise ErrorFactory.stream_error(error_payload || parsed)
          when "error"
            raise ErrorFactory.stream_error(data["error"]? || parsed)
          end
        end

        private def handle_item_added(
          state : State,
          response : Response,
          data : Hash(String, JSON::Any),
          item : Hash(String, JSON::Any),
        ) : Nil
          return unless item["type"]?.try(&.as_s?) == "function_call"

          key = item["id"]?.try(&.as_s?) ||
                item["call_id"]?.try(&.as_s?) ||
                item_key(data) ||
                "0"
          tool = tool_state(state, key)
          tool.id = item["id"]?.try(&.as_s?) || tool.id
          tool.call_id = item["call_id"]?.try(&.as_s?) || tool.call_id

          if name = item["name"]?.try(&.as_s?)
            unless name.empty?
              tool.name = name
              response.push_chunk(Response::Chunk.new(name, Response::ChunkKind::ToolCallName))
            end
          end

          if args = item["arguments"]?.try(&.as_s?)
            tool.arguments = args
          end
        end

        private def handle_item_done(
          state : State,
          data : Hash(String, JSON::Any),
          item : Hash(String, JSON::Any),
        ) : Nil
          case item["type"]?.try(&.as_s?)
          when "function_call"
            key = item["id"]?.try(&.as_s?) ||
                  item["call_id"]?.try(&.as_s?) ||
                  item_key(data) ||
                  "0"
            tool = tool_state(state, key)
            tool.id = item["id"]?.try(&.as_s?) || tool.id
            tool.call_id = item["call_id"]?.try(&.as_s?) || tool.call_id
            tool.name = item["name"]?.try(&.as_s?) || tool.name
            tool.arguments = item["arguments"]?.try(&.as_s?) || tool.arguments
          when "message"
            if state.content.empty?
              if text = extract_output_text(item)
                state.content_done = text unless text.empty?
              end
            end
          end
        end

        private def tool_state(state : State, key : String) : ToolCallState
          state.tool_order << key unless state.tool_order.includes?(key)
          state.tool_calls[key] ||= ToolCallState.new
        end

        private def item_key(data : Hash(String, JSON::Any)) : String?
          if id = data["item_id"]?.try(&.as_s?)
            return id
          end
          if index = data["output_index"]?.try(&.as_i?)
            index.to_s
          end
        end

        private def response_id_from(data : Hash(String, JSON::Any)) : String?
          data["response"]?.try(&.as_h?).try { |h| h["id"]?.try(&.as_s?) }
        end

        private def extract_output_text(item : Hash(String, JSON::Any)) : String?
          content = item["content"]?.try(&.as_a?)
          return if content.nil?

          builder = String::Builder.new
          content.each do |part_any|
            part = part_any.as_h?
            next unless part
            next unless part["type"]?.try(&.as_s?) == "output_text"
            if text = part["text"]?.try(&.as_s?)
              builder << text
            end
          end
          builder.to_s
        end

        private def map_incomplete_reason(reason : String?) : String
          case reason
          when "max_output_tokens" then "length"
          when "content_filter"    then "content_filter"
          else                          reason || "length"
          end
        end

        private def build_final_message(
          state : State,
          provider_name : String?,
          model : String?,
        ) : Message
          content = state.content
          if content.empty?
            if done = state.content_done
              content = done
            end
          end
          reasoning = state.reasoning
          tool_calls = [] of ToolCall
          output_items : Array(JSON::Any)? = nil

          if final = state.final_response.try(&.as_h?)
            output_items = final["output"]?.try(&.as_a?)
            if output = output_items
              output.each do |item_any|
                item = item_any.as_h?
                next unless item
                case item["type"]?.try(&.as_s?)
                when "message"
                  if content.empty?
                    if text = extract_output_text(item)
                      content = text unless text.empty?
                    end
                  end
                when "function_call"
                  call_id = item["call_id"]?.try(&.as_s?) || item["id"]?.try(&.as_s?) || ""
                  name = item["name"]?.try(&.as_s?) || ""
                  arguments = item["arguments"]?.try(&.as_s?) || ""
                  unless tool_calls.any? { |existing| existing.id == call_id }
                    tool_calls << ToolCall.new(call_id, name, arguments)
                  end
                end
              end
            end
          end

          if tool_calls.empty?
            state.tool_order.each do |key|
              tool = state.tool_calls[key]
              next if tool.name.empty? && tool.arguments.empty?
              id = tool.call_id.empty? ? tool.id : tool.call_id
              tool_calls << ToolCall.new(id, tool.name, tool.arguments)
            end
          end

          if reasoning.empty?
            reasoning = extract_final_reasoning(state.final_response)
          end

          Message.new(
            role: Role::Assistant,
            content: content.empty? ? nil : content,
            tool_calls: tool_calls.empty? ? nil : tool_calls,
            reasoning: reasoning.empty? ? nil : reasoning,
            provider_data: build_provider_data(state, output_items, provider_name, model),
          )
        end

        private def extract_final_reasoning(response : JSON::Any?) : String
          final = response.try(&.as_h?)
          return "" unless final
          output = final["output"]?.try(&.as_a?)
          return "" unless output

          builder = String::Builder.new
          output.each do |item_any|
            item = item_any.as_h?
            next unless item
            next unless item["type"]?.try(&.as_s?) == "reasoning"
            summary = item["summary"]?.try(&.as_a?)
            next unless summary
            summary.each do |part_any|
              part = part_any.as_h?
              next unless part
              if text = part["text"]?.try(&.as_s?)
                builder << text
              end
            end
          end
          builder.to_s
        end

        private def build_provider_data(
          state : State,
          output_items : Array(JSON::Any)?,
          provider_name : String?,
          model : String?,
        ) : JSON::Any?
          return if output_items.nil? || provider_name.nil? || model.nil?

          data = {} of String => JSON::Any
          data["provider"] = JSON::Any.new(provider_name)
          data["model"] = JSON::Any.new(model)
          if response_id = state.response_id
            data["response_id"] = JSON::Any.new(response_id)
          end
          data["items"] = JSON::Any.new(output_items)
          JSON::Any.new(data)
        end

        private def final_reason(state : State, message : Message) : String
          return "tool_calls" if message.has_tool_calls?
          state.finish_reason || "stop"
        end

        private def apply_read_timeout(io : IO, timeout : Time::Span?) : Nil
          return unless timeout
          case io
          when .responds_to?(:read_timeout=)
            io.read_timeout = timeout
          end
        end
      end
    end
  end
end
