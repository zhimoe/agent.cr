require "../../spec_helper"

private def build_body(
  config : Agent::Config,
  messages : Array(Agent::Message),
  tools : Array(Agent::Tool)? = nil,
  options : Agent::RequestOptions? = nil,
) : Hash(String, JSON::Any)
  provider = Agent::Provider::OpenAI.new(config, "cache-key")
  request = provider.build_request(messages, tools, options || config.request_options)
  JSON.parse(request[:body]).as_h
end

private def weather_tool : Agent::Tool
  Agent::Tool.new(Agent::Tool::FunctionDef.new(
    name: "get_weather",
    description: "Get weather",
    parameters: Agent::JSONConverter.from({
      type:       "object",
      properties: {city: {type: "string"}},
      required:   ["city"],
    }),
    strict: true,
  ))
end

describe Agent::Provider::OpenAI::RequestBody do
  it "sends modern OpenAI parameters" do
    schema = Agent::JSONConverter.from({
      type:       "object",
      properties: {answer: {type: "string"}},
      required:   ["answer"],
    })
    options = Agent::RequestOptions.new
    options.max_completion_tokens = 256
    options.reasoning_effort = "medium"
    options.parallel_tool_calls = false
    options.response_format = Agent::ResponseFormat.json_schema("answer", schema, strict: true)

    config = Agent::Config.new(api_key: "sk-test", model: "gpt-5")
    body = build_body(config, [Agent::Message.user("hi")], [weather_tool], options)

    body["max_completion_tokens"].as_i.should eq(256)
    body["max_tokens"]?.should be_nil
    body["stream_options"].as_h["include_usage"].as_bool.should be_true
    body["reasoning_effort"].as_s.should eq("medium")
    body["parallel_tool_calls"].as_bool.should be_false
    body["response_format"].as_h["json_schema"].as_h["name"].as_s.should eq("answer")
    body["tools"].as_a.first.as_h["function"].as_h["strict"].as_bool.should be_true
  end

  it "maps max_completion_tokens to max_tokens for DeepSeek and round-trips reasoning" do
    options = Agent::RequestOptions.new
    options.max_completion_tokens = 128
    options.thinking = true
    options.reasoning_effort = "high"
    options.response_format = Agent::ResponseFormat.json_object

    assistant = Agent::Message.new(
      role: Agent::Role::Assistant,
      tool_calls: [Agent::ToolCall.new("call_1", "get_weather", %({"city":"Paris"}))],
      reasoning: "need weather",
    )
    tool = Agent::Message.tool_result(assistant.tool_calls.as(Array(Agent::ToolCall)).first, "sunny")
    messages = [Agent::Message.user("weather?"), assistant, tool]

    config = Agent::Config.new(provider: "deepseek", api_key: "ds-test")
    body = build_body(config, messages, [weather_tool], options)

    body["max_tokens"].as_i.should eq(128)
    body["max_completion_tokens"]?.should be_nil
    body["thinking"].as_h["type"].as_s.should eq("enabled")
    body["reasoning_effort"].as_s.should eq("high")
    body["stream_options"].as_h["include_usage"].as_bool.should be_true
    body["prompt_cache_key"]?.should be_nil
    body["messages"].as_a[1].as_h["reasoning_content"].as_s.should eq("need weather")
  end

  it "rejects DeepSeek json_schema and forced tool choice while thinking" do
    config = Agent::Config.new(provider: "deepseek", api_key: "ds-test")
    schema = Agent::JSONConverter.from({type: "object", properties: {} of String => String})
    options = Agent::RequestOptions.new
    options.response_format = Agent::ResponseFormat.json_schema("x", schema)
    expect_raises(Agent::UnsupportedCapabilityError, /json_schema/) do
      build_body(config, [Agent::Message.user("hi")], nil, options)
    end

    forced = Agent::RequestOptions.new
    forced.tool_choice = Agent::ToolChoice.required
    expect_raises(Agent::UnsupportedCapabilityError, /tool_choice/) do
      build_body(config, [Agent::Message.user("hi")], [weather_tool], forced)
    end
  end

  it "keeps a conservative custom preset and protects reserved extra_body keys" do
    config = Agent::Config.new(api_endpoint: "https://gateway.example.com/v1", model: "local")
    body = build_body(config, [Agent::Message.user("hi")])
    body["stream_options"].as_h["include_usage"].as_bool.should be_true
    body["max_tokens"]?.should be_nil

    options = Agent::RequestOptions.new
    options.response_format = Agent::ResponseFormat.json_schema("x", Agent::JSONConverter.from({type: "object"}))
    expect_raises(Agent::UnsupportedCapabilityError, /json_schema/) do
      build_body(config, [Agent::Message.user("hi")], nil, options)
    end

    extra = Agent::RequestOptions.new
    extra.extra_body = {"messages" => JSON::Any.new("override")}
    expect_raises(Agent::ConfigurationError, /reserved key/) do
      build_body(config, [Agent::Message.user("hi")], nil, extra)
    end
  end

  it "builds auth headers, path overrides, and query params" do
    config = Agent::Config.new(
      provider: "custom",
      api_endpoint: "https://gateway.example.com",
      api_path: "/openai/deployments/dep/chat/completions",
      model: "dep",
      api_key: "secret",
      query_params: {"api-version" => "2024-10-21"},
      extra_headers: {"X-Test" => "yes"},
    )
    provider = Agent::Provider::OpenAI.new(config, "cache-key")
    request = provider.build_request([Agent::Message.user("hi")], nil)
    request[:path].should eq("/openai/deployments/dep/chat/completions?api-version=2024-10-21")
    request[:headers]["Authorization"].should eq("Bearer secret")
    request[:headers]["X-Test"].should eq("yes")
  end
end
