require "../../spec_helper"

private def responses_body(
  messages : Array(Agent::Message),
  tools : Array(Agent::Tool)? = nil,
  options : Agent::RequestOptions? = nil,
) : Hash(String, JSON::Any)
  config = Agent::Config.new(
    provider: "openai",
    api_key: "test-key",
    model: "gpt-5",
    api_style: :responses,
  )
  provider = Agent::Provider::Responses.new(config, "cache-key")
  request = provider.build_request(messages, tools, options || config.request_options)
  JSON.parse(request[:body]).as_h
end

private def responses_echo_tool : Agent::Tool
  Agent::Tool.new(Agent::Tool::FunctionDef.new(
    name: "echo",
    description: "Echo",
    parameters: Agent::JSONConverter.from({
      type:       "object",
      properties: {text: {type: "string"}},
      required:   ["text"],
    }),
    strict: true,
  ))
end

describe Agent::Provider::Responses::RequestBody do
  it "converts system/user/assistant/tool history into Responses items" do
    assistant = Agent::Message.new(
      role: Agent::Role::Assistant,
      content: "calling",
      tool_calls: [Agent::ToolCall.new("call_1", "echo", %({"text":"hi"}))],
    )
    tool = Agent::Message.tool_result(assistant.tool_calls.as(Array(Agent::ToolCall)).first, "ok")
    messages = [
      Agent::Message.system("be nice"),
      Agent::Message.user("hello"),
      assistant,
      tool,
    ]

    options = Agent::RequestOptions.new
    options.max_completion_tokens = 100
    options.reasoning_effort = "medium"
    options.parallel_tool_calls = false
    options.tool_choice = Agent::ToolChoice.auto
    options.response_format = Agent::ResponseFormat.json_schema(
      "answer",
      Agent::JSONConverter.from({type: "object", properties: {answer: {type: "string"}}}),
    )

    body = responses_body(messages, [responses_echo_tool], options)

    body["instructions"].as_s.should eq("be nice")
    body["max_output_tokens"].as_i.should eq(100)
    body["reasoning"].as_h["effort"].as_s.should eq("medium")
    body["parallel_tool_calls"].as_bool.should be_false
    body["tool_choice"].as_s.should eq("auto")
    body["store"].as_bool.should be_false
    body["include"].as_a.map(&.as_s).should contain("reasoning.encrypted_content")
    body["text"].as_h["format"].as_h["type"].as_s.should eq("json_schema")

    tool_json = body["tools"].as_a.first.as_h
    tool_json["type"].as_s.should eq("function")
    tool_json["name"].as_s.should eq("echo")
    tool_json["strict"].as_bool.should be_true
    tool_json["function"]?.should be_nil

    input = body["input"].as_a
    input[0].as_h["role"].as_s.should eq("user")
    input[0].as_h["content"].as_a.first.as_h["text"].as_s.should eq("hello")
    input[1].as_h["role"].as_s.should eq("assistant")
    input[2].as_h["type"].as_s.should eq("function_call")
    input[2].as_h["call_id"].as_s.should eq("call_1")
    input[3].as_h["type"].as_s.should eq("function_call_output")
    input[3].as_h["call_id"].as_s.should eq("call_1")
    input[3].as_h["output"].as_s.should eq("ok")
  end

  it "replays provider_data items instead of synthesizing when provider/model match" do
    provider_data = JSON.parse(<<-JSON)
      {
        "provider":"openai",
        "model":"gpt-5",
        "items":[
          {"type":"reasoning","id":"rs_1","summary":[]},
          {"type":"function_call","id":"fc_1","call_id":"call_1","name":"echo","arguments":"{}"}
        ]
      }
      JSON
    assistant = Agent::Message.new(
      role: Agent::Role::Assistant,
      tool_calls: [Agent::ToolCall.new("call_1", "echo", "{}")],
      provider_data: provider_data,
    )
    tool = Agent::Message.tool_result(assistant.tool_calls.as(Array(Agent::ToolCall)).first, "ok")

    body = responses_body([Agent::Message.user("hi"), assistant, tool])
    input = body["input"].as_a

    input.any? { |item| item.as_h["type"]?.try(&.as_s?) == "reasoning" }.should be_true
    input.count { |item| item.as_h["type"]?.try(&.as_s?) == "function_call" }.should eq(1)
  end
end
