require "./spec_helper"

private class ResponsesMockServer
  getter port : Int32
  getter requests : Array(String)
  getter paths : Array(String)

  def initialize(&handler : HTTP::Server::Context -> Nil)
    @requests = [] of String
    @paths = [] of String
    @server = HTTP::Server.new do |ctx|
      @paths << ctx.request.path
      @requests << (ctx.request.body.try(&.gets_to_end) || "")
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

private def responses_event(ctx : HTTP::Server::Context, event : String, data : String) : Nil
  ctx.response.puts "event: #{event}"
  ctx.response.puts "data: #{data}"
  ctx.response.puts
  ctx.response.flush
end

private def write_responses_tool_call(ctx : HTTP::Server::Context) : Nil
  ctx.response.content_type = "text/event-stream"
  ctx.response.status_code = 200

  responses_event(ctx, "response.created", %({"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}))
  responses_event(ctx, "response.output_item.added", %({"type":"response.output_item.added","item":{"id":"fc_item","type":"function_call","call_id":"call_data","name":"echo","arguments":""}}))
  responses_event(ctx, "response.function_call_arguments.delta", %({"type":"response.function_call_arguments.delta","item_id":"fc_item","delta":"{}"}))
  responses_event(ctx, "response.function_call_arguments.done", %({"type":"response.function_call_arguments.done","item_id":"fc_item","arguments":"{}"}))
  responses_event(ctx, "response.output_item.done", %({"type":"response.output_item.done","item":{"id":"fc_item","type":"function_call","call_id":"call_data","name":"echo","arguments":"{}","status":"completed"}}))
  responses_event(ctx, "response.completed", %({"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"id":"fc_item","type":"function_call","call_id":"call_data","name":"echo","arguments":"{}"}],"usage":{"input_tokens":2,"output_tokens":1,"total_tokens":3}}}))
  ctx.response.puts "data: [DONE]"
  ctx.response.flush
  ctx.response.close
end

private def write_responses_text(ctx : HTTP::Server::Context, text : String) : Nil
  ctx.response.content_type = "text/event-stream"
  ctx.response.status_code = 200

  responses_event(ctx, "response.created", %({"type":"response.created","response":{"id":"resp_2","status":"in_progress"}}))
  responses_event(ctx, "response.output_text.delta", %({"type":"response.output_text.delta","item_id":"msg_1","delta":"#{text}"}))
  responses_event(ctx, "response.completed", %({"type":"response.completed","response":{"id":"resp_2","status":"completed","output":[{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"#{text}"}]}],"usage":{"input_tokens":3,"output_tokens":2,"total_tokens":5}}}))
  ctx.response.puts "data: [DONE]"
  ctx.response.flush
  ctx.response.close
end

describe "Agent Responses API" do
  it "runs a tool loop and echoes call_id in the follow-up request" do
    count = 0
    server = ResponsesMockServer.new do |ctx|
      if ctx.request.path.includes?("/responses")
        count += 1
        if count == 1
          write_responses_tool_call(ctx)
        else
          write_responses_text(ctx, "done")
        end
      else
        ctx.response.status_code = 404
        ctx.response.close
      end
    end

    begin
      config = Agent::Config.new(
        provider: "openai",
        api_endpoint: server.url,
        model: "gpt-5",
        api_key: "test-key",
        api_style: :responses,
        max_retries: 0,
      )
      agent = Agent.new(config)
      agent.register_tool("echo", "Echo") { |_args| "ok" }

      resp = agent.ask("hi")
      resp.join

      resp.error?.should be_false
      resp.message.content.should eq("done")
      resp.metadata.total_tokens.should eq(8) # 3 from tool call + 5 from final
      agent.history.size.should eq(4)
      server.paths.all?(&.includes?("/responses")).should be_true
      server.requests.size.should eq(2)

      second = JSON.parse(server.requests[1]).as_h
      input = second["input"].as_a
      output_item = input.find { |item| item.as_h["type"]?.try(&.as_s?) == "function_call_output" }
      output_item.should_not be_nil
      output_json = output_item.as(JSON::Any)
      output_json.as_h["call_id"].as_s.should eq("call_data")
      output_json.as_h["output"].as_s.should eq("ok")

      first = JSON.parse(server.requests[0]).as_h
      first["stream"].as_bool.should be_true
      first["store"].as_bool.should be_false
      first["tools"].as_a.first.as_h["type"].as_s.should eq("function")

      agent.close
    ensure
      server.close
    end
  end
end
