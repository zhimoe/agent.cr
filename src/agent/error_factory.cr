require "http"
require "json"

class Agent
  # Parses provider HTTP errors and in-stream error payloads into Agent errors.
  module ErrorFactory
    extend self

    MAX_BODY = 64 * 1024

    alias ParsedError = NamedTuple(message: String?, type: String?, param: String?, code: String?)

    def read_body(io : IO) : String
      body = io.gets_to_end
      body.size > MAX_BODY ? body[0, MAX_BODY] : body
    end

    def api_error(
      status : Int32,
      status_message : String,
      headers : HTTP::Headers,
      body : String,
    ) : ApiError
      parsed = parse_error_body(body)
      message = parsed[:message] || "#{status} #{status_message}"
      request_id = header(headers, "x-request-id") ||
                   header(headers, "request-id") ||
                   header(headers, "openai-request-id")
      retry_after = parse_retry_after(headers)
      should_retry = parse_should_retry(headers)

      case status
      when 400
        BadRequestError.new(status, message, body: body, request_id: request_id,
          retry_after: retry_after, api_type: parsed[:type], param: parsed[:param],
          code: parsed[:code], should_retry: should_retry)
      when 401
        AuthenticationError.new(status, message, body: body, request_id: request_id,
          retry_after: retry_after, api_type: parsed[:type], param: parsed[:param],
          code: parsed[:code], should_retry: should_retry)
      when 403
        PermissionDeniedError.new(status, message, body: body, request_id: request_id,
          retry_after: retry_after, api_type: parsed[:type], param: parsed[:param],
          code: parsed[:code], should_retry: should_retry)
      when 404
        NotFoundError.new(status, message, body: body, request_id: request_id,
          retry_after: retry_after, api_type: parsed[:type], param: parsed[:param],
          code: parsed[:code], should_retry: should_retry)
      when 408
        RequestTimeoutError.new(status, message, body: body, request_id: request_id,
          retry_after: retry_after, api_type: parsed[:type], param: parsed[:param],
          code: parsed[:code], should_retry: should_retry)
      when 409
        ConflictError.new(status, message, body: body, request_id: request_id,
          retry_after: retry_after, api_type: parsed[:type], param: parsed[:param],
          code: parsed[:code], should_retry: should_retry)
      when 422
        UnprocessableEntityError.new(status, message, body: body, request_id: request_id,
          retry_after: retry_after, api_type: parsed[:type], param: parsed[:param],
          code: parsed[:code], should_retry: should_retry)
      when 429
        RateLimitError.new(status, message, body: body, request_id: request_id,
          retry_after: retry_after, api_type: parsed[:type], param: parsed[:param],
          code: parsed[:code], should_retry: should_retry)
      when 500..599
        InternalServerError.new(status, message, body: body, request_id: request_id,
          retry_after: retry_after, api_type: parsed[:type], param: parsed[:param],
          code: parsed[:code], should_retry: should_retry)
      else
        UnexpectedStatusError.new(status, message, body: body, request_id: request_id,
          retry_after: retry_after, api_type: parsed[:type], param: parsed[:param],
          code: parsed[:code], should_retry: should_retry)
      end
    end

    # Build a StreamError from an SSE error payload. `payload` may be the whole
    # data object (`{"error": {...}}`) or the inner error object.
    def stream_error(payload : JSON::Any, fallback_message : String = "provider stream error") : StreamError
      h = payload.as_h?
      error_obj = h.try(&.["error"]?)
      details = case error_obj
                when JSON::Any
                  error_obj.as_h? || h
                else
                  h
                end

      message = if d = details
                  d["message"]?.try(&.as_s?)
                end
      message ||= error_obj.try(&.as_s?)
      message ||= fallback_message
      code = string_value(details.try { |detail_hash| detail_hash["code"]? })
      api_type = string_value(details.try { |detail_hash| detail_hash["type"]? })
      param = string_value(details.try { |detail_hash| detail_hash["param"]? })
      request_id = string_value(details.try { |detail_hash| detail_hash["request_id"]? })

      retryable = transient_code?(code) || transient_code?(api_type)
      StreamError.new(
        message,
        code: code,
        api_type: api_type,
        param: param,
        request_id: request_id,
        retryable: retryable,
      )
    end

    def stream_truncated(message : String = "stream ended without a terminal event") : StreamTruncatedError
      StreamTruncatedError.new(message)
    end

    def parse_retry_after(headers : HTTP::Headers) : Time::Span?
      if raw = header(headers, "retry-after-ms")
        if value = raw.to_f?
          return value.milliseconds if finite_non_negative?(value)
        end
      end

      if raw = header(headers, "retry-after")
        if value = raw.to_f?
          return value.seconds if finite_non_negative?(value)
        end
        if date = HTTP.parse_time(raw)
          delta = date - Time.utc
          return delta > Time::Span.zero ? delta : Time::Span.zero
        end
      end

      nil
    end

    private def parse_error_body(body : String) : ParsedError
      parsed = begin
        JSON.parse(body)
      rescue JSON::ParseException
        nil
      end

      if h = parsed.try(&.as_h?)
        error_value = h["error"]?
        details = case error_value
                  when JSON::Any
                    error_value.as_h?
                  end

        if details
          message = details["message"]?.try(&.as_s?) ||
                    details["error_description"]?.try(&.as_s?)
          return {
            message: message,
            type:    string_value(details["type"]?),
            param:   string_value(details["param"]?),
            code:    string_value(details["code"]?),
          }
        end

        if (error_string = error_value.try(&.as_s?)) && !error_string.empty?
          return {
            message: h["error_description"]?.try(&.as_s?) || error_string,
            type:    nil,
            param:   nil,
            code:    error_string,
          }
        end

        return {
          message: h["message"]?.try(&.as_s?),
          type:    string_value(h["type"]?),
          param:   string_value(h["param"]?),
          code:    string_value(h["code"]?),
        }
      end

      text = body.strip
      {message: text.empty? ? nil : text, type: nil, param: nil, code: nil}
    end

    private def parse_should_retry(headers : HTTP::Headers) : Bool?
      raw = header(headers, "x-should-retry")
      case raw.try(&.downcase)
      when "true"  then true
      when "false" then false
      end
    end

    private def header(headers : HTTP::Headers, name : String) : String?
      value = headers[name]?
      return if value.nil? || value.empty?
      value
    end

    private def string_value(value : JSON::Any?) : String?
      return if value.nil?
      raw = value.raw
      case raw
      when String
        raw
      when Int64, Float64, Bool
        raw.to_s
      end
    end

    private def finite_non_negative?(value : Float64) : Bool
      value.finite? && value >= 0.0
    end

    private def transient_code?(value : String?) : Bool
      return false if value.nil?
      normalized = value.downcase
      normalized.includes?("rate_limit") ||
        normalized.includes?("server_error") ||
        normalized.includes?("overloaded") ||
        normalized.includes?("timeout")
    end
  end
end
