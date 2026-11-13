require "../../spec_helper"

private def add_responses_event(lines : Array(String), event : String, data : JSON::Any) : Nil
  lines << "event: #{event}"
  lines << "data: #{data.to_json}"
  lines << ""
end

private def parse_responses(lines : Array(String), strict_end : Bool = false)
  response = Agent::Response.new
  io = IO::Memory.new(lines.join('\n'))
  msg, usage, finish = Agent::Provider::Responses::StreamParser.parse(
    io, response, -> { false },
    strict_end: strict_end,
    provider_name: "openai",
    model: "gpt-5",
  )
  response.finish(msg, usage) unless response.finished?
  {msg, usage, finish, response}
end

private def completed_response(output : Array(JSON::Any), usage : Hash(String, JSON::Any)) : JSON::Any
  JSON.parse({
    "type"     => "response.completed",
    "response" => {
      "id"     => "resp_1",
      "status" => "completed",
      "output" => output,
      "usage"  => usage,
    },
  }.to_json)
end

describe Agent::Provider::Responses::StreamParser do
  it "parses text deltas and completed usage" do
    lines = [] of String
    add_responses_event(lines, "response.created", JSON.parse(%({"type":"response.created","response":{"id":"resp_1","status":"in_progress"}})))
    add_responses_event(lines, "response.output_item.added", JSON.parse(%({"type":"response.output_item.added","item":{"id":"msg_1","type":"message","role":"assistant","content":[]}})))
    add_responses_event(lines, "response.output_text.delta", JSON.parse(%({"type":"response.output_text.delta","item_id":"msg_1","delta":"Hi"})))
    add_responses_event(lines, "response.output_text.delta", JSON.parse(%({"type":"response.output_text.delta","item_id":"msg_1","delta":" there"})))
    add_responses_event(lines, "response.output_text.done", JSON.parse(%({"type":"response.output_text.done","item_id":"msg_1","text":"Hi there"})))
    add_responses_event(lines, "response.output_item.done", JSON.parse(%({"type":"response.output_item.done","item":{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"Hi there"}]}})))
    completed = completed_response(
      [JSON.parse(%({"id":"msg_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"Hi there"}]}))],
      {"input_tokens" => JSON::Any.new(2_i64), "output_tokens" => JSON::Any.new(1_i64), "total_tokens" => JSON::Any.new(3_i64)},
    )
    add_responses_event(lines, "response.completed", completed)
    lines << "data: [DONE]"

    msg, usage, finish, response = parse_responses(lines)
    msg.content.should eq("Hi there")
    usage.total_tokens.should eq(3)
    finish.should eq("stop")
    response.output_started?.should be_true
    msg.provider_data.should_not be_nil
  end

  it "parses function call deltas using item_id and echoes call_id" do
    lines = [] of String
    add_responses_event(lines, "response.output_item.added", JSON.parse(%({"type":"response.output_item.added","item":{"id":"fc_item","type":"function_call","call_id":"call_data","name":"record","arguments":""}})))
    add_responses_event(lines, "response.function_call_arguments.delta", JSON.parse({"type" => "response.function_call_arguments.delta", "item_id" => "fc_item", "delta" => %({"x":)}.to_json))
    add_responses_event(lines, "response.function_call_arguments.delta", JSON.parse({"type" => "response.function_call_arguments.delta", "item_id" => "fc_item", "delta" => "1}"}.to_json))
    add_responses_event(lines, "response.function_call_arguments.done", JSON.parse({"type" => "response.function_call_arguments.done", "item_id" => "fc_item", "arguments" => %({"x":1})}.to_json))
    add_responses_event(lines, "response.output_item.done", JSON.parse({
      "type" => "response.output_item.done",
      "item" => {
        "id" => "fc_item", "type" => "function_call", "call_id" => "call_data",
        "name" => "record", "arguments" => %({"x":1}), "status" => "completed",
      },
    }.to_json))
    completed = completed_response(
      [JSON.parse({"id" => "fc_item", "type" => "function_call", "call_id" => "call_data", "name" => "record", "arguments" => %({"x":1})}.to_json)],
      {"input_tokens" => JSON::Any.new(2_i64), "output_tokens" => JSON::Any.new(2_i64), "total_tokens" => JSON::Any.new(4_i64)},
    )
    add_responses_event(lines, "response.completed", completed)
    lines << "data: [DONE]"

    msg, _usage, finish, _response = parse_responses(lines)
    calls = msg.tool_calls.should_not be_nil
    calls.size.should eq(1)
    calls[0].id.should eq("call_data")
    calls[0].name.should eq("record")
    calls[0].arguments.should eq(%({"x":1}))
    finish.should eq("tool_calls")
  end

  it "raises StreamError on response.failed and error events" do
    lines = [] of String
    add_responses_event(lines, "response.failed", JSON.parse(%({"type":"response.failed","response":{"status":"failed","error":{"message":"boom","type":"server_error"}}})))
    expect_raises(Agent::StreamError, /boom/) { parse_responses(lines) }

    lines = [] of String
    add_responses_event(lines, "error", JSON.parse(%({"type":"error","message":"nope","code":"server_error"})))
    expect_raises(Agent::StreamError, /nope/) { parse_responses(lines) }
  end

  it "maps incomplete max_output_tokens to length" do
    lines = [] of String
    add_responses_event(lines, "response.incomplete", JSON.parse(%({"type":"response.incomplete","response":{"id":"resp_1","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}})))
    lines << "data: [DONE]"

    msg, usage, finish, _response = parse_responses(lines)
    msg.content.should be_nil
    usage.total_tokens.should eq(3)
    finish.should eq("length")
  end

  it "handles data-only frames" do
    lines = [
      %(data: {"type":"response.output_text.delta","item_id":"msg_1","delta":"ok"}),
      "",
      %(data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}),
      "",
      "data: [DONE]",
    ]

    msg, _usage, finish, _response = parse_responses(lines)
    msg.content.should eq("ok")
    finish.should eq("stop")
  end

  it "enforces strict stream endings only when requested" do
    lines = [
      %(event: response.output_text.delta),
      %(data: {"type":"response.output_text.delta","item_id":"msg_1","delta":"partial"}),
      "",
    ]

    msg, _usage, _finish, _response = parse_responses(lines)
    msg.content.should eq("partial")

    expect_raises(Agent::StreamTruncatedError) do
      parse_responses(lines, strict_end: true)
    end
  end
end
