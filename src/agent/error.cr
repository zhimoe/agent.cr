class Agent
  # Base error for all Agent-related failures.
  class Error < Exception
    # Whether the same request may be retried against the same provider.
    def retryable? : Bool
      false
    end

    # Whether the turn must stop immediately (no fallback). Configuration and
    # explicit cancellation are fatal; provider/API errors are not.
    def fatal? : Bool
      false
    end
  end

  # Raised for invalid client-side configuration or unsupported combinations.
  class ConfigurationError < Error
    def fatal? : Bool
      true
    end
  end

  # Raised when a network or connection error occurs during an API request.
  class ConnectionError < Error
    def initialize(message : String, cause : Exception? = nil)
      super(message, cause: cause)
    end

    def retryable? : Bool
      true
    end
  end

  # Raised when the API returns a non-2xx status code.
  class ApiError < Error
    getter status_code : Int32
    getter body : String?
    getter request_id : String?
    getter retry_after : Time::Span?
    getter api_type : String?
    getter param : String?
    getter code : String?
    getter should_retry : Bool?

    def initialize(
      @status_code : Int32,
      message : String,
      *,
      @body : String? = nil,
      @request_id : String? = nil,
      @retry_after : Time::Span? = nil,
      @api_type : String? = nil,
      @param : String? = nil,
      @code : String? = nil,
      @should_retry : Bool? = nil,
    )
      super(message)
    end

    def retryable? : Bool
      should_retry = @should_retry
      return should_retry unless should_retry.nil?
      @status_code == 408 || @status_code == 409 || @status_code == 429 || @status_code >= 500
    end
  end

  class BadRequestError < ApiError
  end

  class AuthenticationError < ApiError
  end

  class PermissionDeniedError < ApiError
  end

  class NotFoundError < ApiError
  end

  class RequestTimeoutError < ApiError
  end

  class ConflictError < ApiError
  end

  class UnprocessableEntityError < ApiError
  end

  class RateLimitError < ApiError
  end

  class InternalServerError < ApiError
  end

  class UnexpectedStatusError < ApiError
  end

  # Raised when an SSE stream contains a provider error event.
  class StreamError < Error
    getter code : String?
    getter api_type : String?
    getter param : String?
    getter request_id : String?

    def initialize(
      message : String,
      *,
      @code : String? = nil,
      @api_type : String? = nil,
      @param : String? = nil,
      @request_id : String? = nil,
      @retryable : Bool = false,
      cause : Exception? = nil,
    )
      super(message, cause: cause)
    end

    def retryable? : Bool
      @retryable
    end
  end

  # Raised when a stream ends before any terminal event (finish_reason or
  # [DONE]) and no output was produced, or when strict stream-end checking is
  # enabled.
  class StreamTruncatedError < StreamError
    def initialize(
      message : String = "stream ended without a terminal event",
      *,
      code : String? = nil,
      api_type : String? = nil,
      param : String? = nil,
      request_id : String? = nil,
      cause : Exception? = nil,
    )
      super(message, code: code, api_type: api_type, param: param,
        request_id: request_id, retryable: true, cause: cause)
    end

    def retryable? : Bool
      true
    end
  end

  # Raised when the configured provider/model cannot honor a requested feature.
  # Non-fatal: another fallback provider may support it.
  class UnsupportedCapabilityError < Error
    getter provider : String
    getter model : String
    getter capability : String

    def initialize(@provider : String, @model : String, @capability : String, message : String? = nil)
      super(message || "Provider '#{@provider}' model '#{@model}' does not support #{@capability}")
    end
  end

  # Raised when the automatic tool-resolution loop exceeds the iteration limit.
  class ToolLoopError < Error
    getter max_iterations : Int32

    def initialize(@max_iterations : Int32, message : String)
      super(message)
    end

    def fatal? : Bool
      true
    end
  end

  # Raised when the caller cancels an in-flight response.
  class CancelledError < Error
    def initialize
      super("Response was cancelled by caller")
    end

    def fatal? : Bool
      true
    end
  end

  # Raised when an SSE stream stalls — no bytes arrive on `body_io` within
  # the configured first-byte or idle read timeout. The HTTP fiber catches
  # `IO::TimeoutError` from the underlying socket and re-raises it as this so
  # callers can pattern-match on `Agent::Error` types.
  #
  # `phase` is `:first_byte` (no data between POST-send and the first SSE
  # line) or `:idle` (gap between two consecutive lines mid-stream).
  class IdleTimeoutError < Error
    getter phase : Symbol
    getter timeout : Time::Span?

    def initialize(@phase : Symbol, @timeout : Time::Span? = nil, cause : Exception? = nil)
      budget = timeout.try(&.total_seconds.try(&.round(2)))
      msg = case @phase
            when :first_byte then "provider did not emit the first byte within #{budget}s of sending the request"
            else                  "provider stream stalled — no bytes received within the #{budget}s idle timeout"
            end
      super(msg, cause: cause)
    end

    def retryable? : Bool
      @phase == :first_byte
    end
  end

  # Raised when loading a session from serialised data fails due to
  # missing fields, type mismatches, or invalid message format.
  class SessionLoadError < Error
    getter reason : String

    def initialize(@reason : String, cause : Exception? = nil)
      super("Failed to load session: #{reason}", cause: cause)
    end
  end
end
