require "uri"
require "./config"
require "./request_body"
require "./stream_parser"

class Agent
  module Provider
    # OpenAI-compatible Chat Completions provider.
    #
    # One generic engine handles OpenAI and every OpenAI-compatible endpoint;
    # behavior differences come from `Agent::Config#preset` capabilities.
    class OpenAI < Base
      @config : Agent::Config
      @cache_key : String

      def initialize(@config : Agent::Config, @cache_key : String)
      end

      def name : String
        "#{@config.provider_name}/chat"
      end

      def base_uri : URI
        @config.parsed_uri
      end

      def build_request(messages : Array(Message), tools : Array(Tool)?) : Request
        build_request(messages, tools, @config.request_options)
      end

      def build_request(messages : Array(Message), tools : Array(Tool)?, options : RequestOptions) : Request
        body = RequestBody.build(messages, tools, @config, @cache_key, options)
        {path: request_path(@config.chat_path), headers: headers(options), body: body.to_json}
      end

      def parse_stream(
        io : IO,
        response : Response,
        cancel : -> Bool,
        first_byte_timeout : Time::Span? = nil,
        idle_timeout : Time::Span? = nil,
      ) : {Message, Usage, String?}
        StreamParser.parse(io, response, cancel,
          first_byte_timeout: first_byte_timeout,
          idle_timeout: idle_timeout,
          strict_end: @config.strict_stream_end?)
      end

      def close : Nil
      end

      private def headers(options : RequestOptions) : HTTP::Headers
        headers = HTTP::Headers.new

        if key = @config.api_key
          header = @config.preset.api_key_header
          prefix = @config.preset.api_key_prefix || ""
          headers[header] = "#{prefix}#{key}" unless header.empty?
        end

        if defaults = @config.preset.default_headers
          defaults.each { |k, v| headers[k] = v }
        end
        if extra = @config.extra_headers
          extra.each { |k, v| headers[k] = v }
        end
        if extra = options.extra_headers
          extra.each { |k, v| headers[k] = v }
        end

        headers["Content-Type"] = "application/json" unless headers["Content-Type"]?
        headers["Accept"] = "text/event-stream" unless headers["Accept"]?
        headers["User-Agent"] = "agent-cr/#{Agent::VERSION}" unless headers["User-Agent"]?
        headers
      end

      private def request_path(base_path : String) : String
        query_parts = [] of String
        if (base_query = @config.parsed_uri.query) && !base_query.empty?
          query_parts << base_query
        end
        unless @config.query_params.empty?
          query_parts << URI::Params.encode(@config.query_params)
        end

        return base_path if query_parts.empty?
        separator = base_path.includes?('?') ? '&' : '?'
        "#{base_path}#{separator}#{query_parts.join('&')}"
      end
    end
  end
end
