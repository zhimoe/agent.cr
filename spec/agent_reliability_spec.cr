require "./spec_helper"

private class ReliabilityMockServer
  getter port : Int32
  getter requests : Array(String)

  def initialize(&handler : HTTP::Server::Context -> Nil)
    @requests = [] of String
    @server = HTTP::Server.new do |ctx|
      body = ctx.request.body.try(&.gets_to_end) || ""
      @requests << body
      handler.call(ctx)
    end
    address = @server.bind_tcp(0)
    @port = address.port
    ready = Channel(Nil).new
    spawn do
      ready.send(nil)
      @server.listen
    end
    ready.receive
  end

  def url : String
    "http://localhost:#{@port}"
  end

  def close : Nil
    @server.close
  end
end

private def write_text_sse(ctx : HTTP::Server::Context, text : String) : Nil
  ctx.response.content_type = "text/event-stream"
  ctx.response.status_code = 200
  text.each_char do |ch|
    data = {"choices" => [{"index" => 0, "delta" => {"content" => ch.to_s}}]}.to_json
    ctx.response.puts "data: #{data}"
    ctx.response.flush
  end
  final = {
    "choices" => [{"index" => 0, "delta" => {} of String => JSON::Any, "finish_reason" => "stop"}],
    "usage"   => {"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2},
  }.to_json
  ctx.response.puts "data: #{final}"
  ctx.response.puts "data: [DONE]"
  ctx.response.flush
  ctx.response.close
end

private def write_tool_call_sse(ctx : HTTP::Server::Context, name : String) : Nil
  ctx.response.content_type = "text/event-stream"
  ctx.response.status_code = 200
  delta = {
    "tool_calls" => [{
      "index"    => 0,
      "id"       => "call_1",
      "type"     => "function",
      "function" => {"name" => name, "arguments" => "{}"},
    }],
  }
  ctx.response.puts "data: #{{"choices" => [{"index" => 0, "delta" => delta}]}.to_json}"
  final = {
    "choices" => [{"index" => 0, "delta" => {} of String => JSON::Any, "finish_reason" => "tool_calls"}],
  }.to_json
  ctx.response.puts "data: #{final}"
  ctx.response.puts "data: [DONE]"
  ctx.response.flush
  ctx.response.close
end

private def write_partial_sse(ctx : HTTP::Server::Context) : Nil
  ctx.response.content_type = "text/event-stream"
  ctx.response.status_code = 200
  data = {"choices" => [{"index" => 0, "delta" => {"content" => "partial"}}]}.to_json
  ctx.response.puts "data: #{data}"
  ctx.response.flush
  ctx.response.close
end

private def write_empty_sse(ctx : HTTP::Server::Context) : Nil
  ctx.response.content_type = "text/event-stream"
  ctx.response.status_code = 200
  ctx.response.close
end

private def write_content_then_error(ctx : HTTP::Server::Context) : Nil
  ctx.response.content_type = "text/event-stream"
  ctx.response.status_code = 200
  data = {"choices" => [{"index" => 0, "delta" => {"content" => "partial"}}]}.to_json
  ctx.response.puts "data: #{data}"
  ctx.response.flush
  ctx.response.puts %(data: {"error":{"message":"boom","type":"server_error","code":"server_error"}})
  ctx.response.flush
  ctx.response.close
end

private def write_error(
  ctx : HTTP::Server::Context,
  status : Int32,
  body : String,
  headers : Hash(String, String)? = nil,
) : Nil
  ctx.response.status_code = status
  if headers
    headers.each { |k, v| ctx.response.headers[k] = v }
  end
  ctx.response.print body
  ctx.response.close
end

private def reliability_config(
  server : ReliabilityMockServer,
  max_retries : Int32 = 0,
  strict : Bool? = nil,
) : Agent::Config
  Agent::Config.new(
    api_endpoint: server.url,
    model: "test-model",
    api_key: "test-key",
    max_retries: max_retries,
    retry_backoff_base: 1.millisecond,
    retry_backoff_max: 1.millisecond,
    strict_stream_end: strict,
  )
end

private class ErrorCountHandler < Agent::Handler
  getter count = 0

  def handle(ctx : Agent::ErrorContext, next_proc) : Agent::Error
    @count += 1
    next_proc.call(ctx)
  end
end

describe "Agent reliability" do
  it "retries a 429 and succeeds" do
    count = 0
    server = ReliabilityMockServer.new do |ctx|
      count += 1
      if count == 1
        write_error(ctx, 429, %({"error":{"message":"slow"}}), {"Retry-After" => "0"})
      else
        write_text_sse(ctx, "ok")
      end
    end

    begin
      agent = Agent.new(reliability_config(server, max_retries: 1))
      resp = agent.ask("hi")
      resp.join

      resp.error?.should be_false
      resp.message.content.should eq("ok")
      resp.attempts.size.should eq(2)
      resp.attempts[0].status_code.should eq(429)
      count.should eq(2)
      agent.close
    ensure
      server.close
    end
  end

  it "retries 500s and succeeds on the third attempt" do
    count = 0
    server = ReliabilityMockServer.new do |ctx|
      count += 1
      if count < 3
        write_error(ctx, 500, %({"error":{"message":"server"}}))
      else
        write_text_sse(ctx, "recovered")
      end
    end

    begin
      agent = Agent.new(reliability_config(server, max_retries: 2))
      resp = agent.ask("hi")
      resp.join

      resp.error?.should be_false
      resp.message.content.should eq("recovered")
      resp.attempts.size.should eq(3)
      count.should eq(3)
      agent.close
    ensure
      server.close
    end
  end

  it "does not retry a 401" do
    server = ReliabilityMockServer.new do |ctx|
      write_error(ctx, 401, %({"error":{"message":"bad key","type":"invalid_request_error"}}))
    end

    begin
      agent = Agent.new(reliability_config(server, max_retries: 2))
      resp = agent.ask("hi")
      resp.join

      resp.error.should be_a(Agent::AuthenticationError)
      server.requests.size.should eq(1)
      agent.close
    ensure
      server.close
    end
  end

  it "honors x-should-retry: false" do
    server = ReliabilityMockServer.new do |ctx|
      write_error(ctx, 500, "{}", {"x-should-retry" => "false"})
    end

    begin
      agent = Agent.new(reliability_config(server, max_retries: 2))
      resp = agent.ask("hi")
      resp.join

      resp.error.should be_a(Agent::InternalServerError)
      server.requests.size.should eq(1)
      agent.close
    ensure
      server.close
    end
  end

  it "falls back to another provider" do
    primary = ReliabilityMockServer.new do |ctx|
      write_error(ctx, 500, %({"error":{"message":"down"}}))
    end
    fallback = ReliabilityMockServer.new do |ctx|
      write_text_sse(ctx, "fallback")
    end

    begin
      fallback_config = Agent::Config.new(
        api_endpoint: fallback.url,
        model: "test-model",
        api_key: "test-key",
        max_retries: 0,
      )
      config_with_fallback = Agent::Config.new(
        api_endpoint: primary.url,
        model: "test-model",
        api_key: "test-key",
        max_retries: 0,
        fallbacks: [fallback_config],
      )
      agent = Agent.new(config_with_fallback)
      resp = agent.ask("hi")
      resp.join

      resp.error?.should be_false
      resp.message.content.should eq("fallback")
      primary.requests.size.should eq(1)
      fallback.requests.size.should eq(1)
      resp.attempts.size.should eq(2)
      agent.close
    ensure
      primary.close
      fallback.close
    end
  end

  it "falls back on an unsupported capability without contacting the primary" do
    primary = ReliabilityMockServer.new do |ctx|
      write_text_sse(ctx, "should-not-be-called")
    end
    fallback = ReliabilityMockServer.new do |ctx|
      write_text_sse(ctx, "openai")
    end

    begin
      fallback_config = Agent::Config.new(
        provider: "openai",
        api_endpoint: fallback.url,
        model: "test-model",
        api_key: "test-key",
        max_retries: 0,
      )
      config = Agent::Config.new(
        provider: "deepseek",
        api_endpoint: primary.url,
        model: "deepseek-flash",
        api_key: "ds-key",
        max_retries: 0,
        fallbacks: [fallback_config],
      )
      agent = Agent.new(config)
      options = Agent::RequestOptions.new
      options.response_format = Agent::ResponseFormat.json_schema(
        "answer",
        Agent::JSONConverter.from({type: "object", properties: {answer: {type: "string"}}}),
      )
      resp = agent.ask("hi", options: options)
      resp.join

      resp.error?.should be_false
      resp.message.content.should eq("openai")
      primary.requests.size.should eq(0)
      fallback.requests.size.should eq(1)
      agent.close
    ensure
      primary.close
      fallback.close
    end
  end

  it "does not fall back after output started" do
    primary = ReliabilityMockServer.new do |ctx|
      write_partial_sse(ctx)
    end
    fallback = ReliabilityMockServer.new do |ctx|
      write_text_sse(ctx, "fallback")
    end

    begin
      fallback_config = Agent::Config.new(
        api_endpoint: fallback.url,
        model: "test-model",
        api_key: "test-key",
        max_retries: 0,
      )
      config = Agent::Config.new(
        api_endpoint: primary.url,
        model: "test-model",
        api_key: "test-key",
        max_retries: 0,
        strict_stream_end: true,
        fallbacks: [fallback_config],
      )
      agent = Agent.new(config)
      resp = agent.ask("hi")
      resp.join

      resp.error.should be_a(Agent::StreamTruncatedError)
      fallback.requests.size.should eq(0)
      agent.close
    ensure
      primary.close
      fallback.close
    end
  end

  it "does not retry an in-stream error after output started" do
    server = ReliabilityMockServer.new do |ctx|
      write_content_then_error(ctx)
    end

    begin
      agent = Agent.new(reliability_config(server, max_retries: 2))
      resp = agent.ask("hi")
      resp.join

      resp.error.should be_a(Agent::StreamError)
      server.requests.size.should eq(1)
      agent.close
    ensure
      server.close
    end
  end

  it "retries a truncated stream that produced no output" do
    count = 0
    server = ReliabilityMockServer.new do |ctx|
      count += 1
      if count == 1
        write_empty_sse(ctx)
      else
        write_text_sse(ctx, "ok")
      end
    end

    begin
      agent = Agent.new(reliability_config(server, max_retries: 1))
      resp = agent.ask("hi")
      resp.join

      resp.error?.should be_false
      resp.message.content.should eq("ok")
      resp.attempts.size.should eq(2)
      agent.close
    ensure
      server.close
    end
  end

  it "cancels during backoff without appending a synthetic assistant message" do
    server = ReliabilityMockServer.new do |ctx|
      write_error(ctx, 500, %({"error":{"message":"server"}}))
    end

    begin
      config = Agent::Config.new(
        api_endpoint: server.url,
        model: "test-model",
        api_key: "test-key",
        max_retries: 2,
        retry_backoff_base: 200.milliseconds,
        retry_backoff_max: 200.milliseconds,
      )
      agent = Agent.new(config)
      resp = agent.ask("hi")
      sleep 20.milliseconds
      resp.cancel
      resp.join

      resp.error.should be_a(Agent::CancelledError)
      agent.history.size.should eq(1)
      agent.history[0].role.should eq(Agent::Role::User)
      agent.close
    ensure
      server.close
    end
  end

  it "restores history when a later tool-loop iteration fails" do
    count = 0
    server = ReliabilityMockServer.new do |ctx|
      count += 1
      if count == 1
        write_tool_call_sse(ctx, "echo")
      else
        write_error(ctx, 500, %({"error":{"message":"server"}}))
      end
    end

    begin
      config = reliability_config(server, max_retries: 0)
      agent = Agent.new(config)
      agent.register_tool("echo", "Echo") { |_args| "ok" }
      resp = agent.ask("hi")
      resp.join

      resp.error?.should be_true
      agent.history.should be_empty
      agent.close
    ensure
      server.close
    end
  end

  it "runs the error handler once on exhaustion and never on recovery" do
    failed = ReliabilityMockServer.new do |ctx|
      write_error(ctx, 500, %({"error":{"message":"server"}}))
    end
    recovered = ReliabilityMockServer.new do |ctx|
      write_text_sse(ctx, "ok")
    end

    begin
      handler = ErrorCountHandler.new
      agent = Agent.new(reliability_config(failed, max_retries: 0))
      agent.use(handler)
      agent.ask("hi").join
      handler.count.should eq(1)
      agent.close

      handler = ErrorCountHandler.new
      agent = Agent.new(reliability_config(recovered, max_retries: 0))
      agent.use(handler)
      agent.ask("hi").join
      handler.count.should eq(0)
      agent.close
    ensure
      failed.close
      recovered.close
    end
  end
end
