require "./spec_helper"

describe Agent::RequestOptions do
  it "merges per-request values over defaults, including false booleans" do
    base = Agent::RequestOptions.new
    base.max_tokens = 100
    base.parallel_tool_calls = true
    base.extra_body = {"a" => JSON::Any.new(1)}

    override = Agent::RequestOptions.new
    override.max_tokens = 200
    override.parallel_tool_calls = false
    override.extra_body = {"b" => JSON::Any.new(2)}

    merged = base.merge(override)
    merged.max_tokens.should eq(200)
    merged.parallel_tool_calls.should be_false
    merged.extra_body.should eq({
      "a" => JSON::Any.new(1),
      "b" => JSON::Any.new(2),
    })
  end

  it "rejects n > 1 and out-of-range sampling values" do
    opts = Agent::RequestOptions.new
    opts.n = 2
    expect_raises(Agent::ConfigurationError, /n > 1/) { opts.validate! }

    opts = Agent::RequestOptions.new
    opts.temperature = 3.0
    expect_raises(Agent::ConfigurationError, /temperature/) { opts.validate! }
  end

  it "serializes Chat and Responses response formats differently" do
    schema = Agent::JSONConverter.from({
      type:       "object",
      properties: {answer: {type: "string"}},
      required:   ["answer"],
    })
    fmt = Agent::ResponseFormat.json_schema("answer", schema, strict: true)

    chat = fmt.to_chat_json.as_h
    chat["type"].as_s.should eq("json_schema")
    chat["json_schema"].as_h["name"].as_s.should eq("answer")
    chat["json_schema"].as_h["strict"].as_bool.should be_true

    responses = fmt.to_responses_json.as_h
    responses["type"].as_s.should eq("json_schema")
    responses["name"].as_s.should eq("answer")
    responses["strict"].as_bool.should be_true
  end

  it "serializes tool choices for both APIs" do
    chat = Agent::ToolChoice.function("get_weather").to_chat_json.as_h
    chat["type"].as_s.should eq("function")
    chat["function"].as_h["name"].as_s.should eq("get_weather")

    responses = Agent::ToolChoice.function("get_weather").to_responses_json.as_h
    responses["type"].as_s.should eq("function")
    responses["name"].as_s.should eq("get_weather")
  end
end
