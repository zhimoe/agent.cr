require "./spec_helper"

describe Agent::ErrorFactory do
  it "parses the standard OpenAI error body and maps status classes" do
    headers = HTTP::Headers{
      "x-request-id" => "req_123",
      "retry-after"  => "2",
    }
    body = %({"error":{"message":"slow down","type":"rate_limit_error","param":null,"code":"rate_limit_exceeded"}})

    err = Agent::ErrorFactory.api_error(429, "Too Many Requests", headers, body)
    err.should be_a(Agent::RateLimitError)
    err.status_code.should eq(429)
    err.message.should eq("slow down")
    err.request_id.should eq("req_123")
    err.api_type.should eq("rate_limit_error")
    err.code.should eq("rate_limit_exceeded")
    err.retry_after.should eq(2.seconds)
    err.retryable?.should be_true
  end

  it "tolerates plain-text errors and numeric codes" do
    err = Agent::ErrorFactory.api_error(
      400, "Bad Request", HTTP::Headers.new, %({"error":{"message":"bad","code":42}})
    )
    err.should be_a(Agent::BadRequestError)
    err.message.should eq("bad")
    err.code.should eq("42")
    err.retryable?.should be_false

    plain = Agent::ErrorFactory.api_error(401, "Unauthorized", HTTP::Headers.new, "Unauthorized")
    plain.should be_a(Agent::AuthenticationError)
    plain.message.should eq("Unauthorized")
  end

  it "honors x-should-retry overrides" do
    headers = HTTP::Headers{"x-should-retry" => "true"}
    err = Agent::ErrorFactory.api_error(400, "Bad Request", headers, %({"error":{"message":"bad"}}))
    err.retryable?.should be_true

    headers = HTTP::Headers{"x-should-retry" => "false"}
    err = Agent::ErrorFactory.api_error(500, "Server Error", headers, "")
    err.retryable?.should be_false
  end

  it "parses Retry-After milliseconds, seconds, and HTTP dates" do
    Agent::ErrorFactory.parse_retry_after(HTTP::Headers{"retry-after-ms" => "1500"}).should eq(1.5.seconds)
    Agent::ErrorFactory.parse_retry_after(HTTP::Headers{"retry-after" => "3"}).should eq(3.seconds)
    Agent::ErrorFactory.parse_retry_after(HTTP::Headers{"retry-after" => "not-a-date"}).should be_nil
  end

  it "builds a retryable StreamTruncatedError and parses stream error payloads" do
    Agent::ErrorFactory.stream_truncated.retryable?.should be_true

    payload = JSON.parse(%({"error":{"message":"overloaded","type":"server_error","code":"overloaded"}}))
    err = Agent::ErrorFactory.stream_error(payload)
    err.message.should eq("overloaded")
    err.retryable?.should be_true
  end
end
