require "./spec_helper"

private class FixedJitterPolicy < Agent::RetryPolicy
  protected def jitter : Float64
    1.0
  end
end

describe Agent::RetryPolicy do
  it "uses exponential backoff capped at the maximum" do
    policy = FixedJitterPolicy.new
    err = Agent::ConnectionError.new("boom")

    policy.delay_for(1, err).should eq(500.milliseconds)
    policy.delay_for(2, err).should eq(1.second)
    policy.delay_for(3, err).should eq(2.seconds)
    policy.delay_for(6, err).should eq(8.seconds)
  end

  it "prefers a valid Retry-After and refuses values over the cap" do
    policy = FixedJitterPolicy.new
    err = Agent::RateLimitError.new(429, "slow", retry_after: 2.seconds)
    policy.delay_for(1, err).should eq(2.seconds)
    policy.retryable?(err).should be_true

    too_long = Agent::RateLimitError.new(429, "slow", retry_after: 200.seconds)
    policy.retryable?(too_long).should be_false
  end

  it "respects error retryability and fatal errors" do
    policy = FixedJitterPolicy.new
    policy.retryable?(Agent::ApiError.new(500, "server")).should be_true
    policy.retryable?(Agent::ApiError.new(401, "auth")).should be_false
    policy.retryable?(Agent::ConfigurationError.new("bad config")).should be_false
  end

  it "can be interrupted by response cancellation or agent shutdown" do
    policy = Agent::RetryPolicy.new
    response = Agent::Response.new
    shutdown = Channel(Nil).new

    spawn do
      sleep 5.milliseconds
      response.cancel
    end
    policy.await(1.second, response, shutdown).should be_false

    response = Agent::Response.new
    shutdown = Channel(Nil).new
    spawn do
      sleep 5.milliseconds
      shutdown.close
    end
    policy.await(1.second, response, shutdown).should be_false
  end
end
