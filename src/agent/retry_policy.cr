class Agent
  # Retry/backoff policy shared by all provider runtimes.
  #
  # A class (not a struct) so tests can subclass and override `await`/`jitter`
  # without sleeping.
  class RetryPolicy
    getter max_retries : Int32
    getter backoff_base : Time::Span
    getter backoff_max : Time::Span
    getter max_retry_after : Time::Span

    def initialize(
      @max_retries : Int32 = 2,
      @backoff_base : Time::Span = 500.milliseconds,
      @backoff_max : Time::Span = 8.seconds,
      @max_retry_after : Time::Span = 120.seconds,
    )
      raise ConfigurationError.new("max_retries must be non-negative, got #{@max_retries}") if @max_retries < 0
      raise ConfigurationError.new("backoff_base must be positive") if @backoff_base <= Time::Span.zero
      raise ConfigurationError.new("backoff_max must be >= backoff_base") if @backoff_max < @backoff_base
      raise ConfigurationError.new("max_retry_after must be non-negative") if @max_retry_after < Time::Span.zero
    end

    def retryable?(err : Agent::Error) : Bool
      return false if err.fatal?
      if err.is_a?(ApiError) && (retry_after = err.retry_after)
        return false if retry_after > @max_retry_after
      end
      err.retryable?
    end

    # Retry number is 1-based (first retry after the initial attempt).
    def delay_for(retry_number : Int32, err : Agent::Error) : Time::Span
      if err.is_a?(ApiError) && (retry_after = err.retry_after)
        if retry_after > Time::Span.zero && retry_after <= @max_retry_after
          return retry_after
        end
      end

      factor = 2.0 ** (retry_number - 1).clamp(0, 30)
      base_ms = @backoff_base.total_milliseconds.to_f
      max_ms = @backoff_max.total_milliseconds.to_f
      delay_ms = Math.min(base_ms * factor, max_ms) * jitter
      delay_ms.milliseconds
    end

    # Wait for `delay`, returning false if the caller cancelled or the agent
    # shut down. `shutdown` is a Channel(Nil) closed by Agent#close.
    def await(delay : Time::Span, response : Response, shutdown : Channel(Nil)) : Bool
      return true if delay <= Time::Span.zero
      select
      when response.cancel_signal.receive
        false
      when shutdown.receive
        false
      when timeout(delay)
        true
      end
    rescue Channel::ClosedError
      false
    end

    # 75–100% of the computed delay (full jitter would be 0–100%).
    protected def jitter : Float64
      0.75 + Random.rand * 0.25
    end
  end
end
