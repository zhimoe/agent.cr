require "../spec_helper"

private def with_env(name : String, value : String?, &)
  previous = ENV[name]?
  if value
    ENV[name] = value
  else
    ENV.delete(name)
  end
  yield
ensure
  if previous
    ENV[name] = previous
  else
    ENV.delete(name)
  end
end

describe Agent::Provider::Presets do
  it "keeps the legacy OpenAI defaults" do
    config = Agent::Config.new(api_key: "sk-test")
    config.provider_name.should eq("openai")
    config.api_endpoint.should eq("https://api.openai.com/v1")
    config.model.should eq("gpt-4o")
  end

  it "resolves DeepSeek defaults and reads its env key when explicitly named" do
    with_env("DEEPSEEK_API_KEY", "ds-test") do
      config = Agent::Config.new(provider: "deepseek")
      config.api_endpoint.should eq("https://api.deepseek.com")
      config.model.should eq("deepseek-flash")
      config.api_key.should eq("ds-test")
      config.capabilities.thinking_enabled_by_default.should be_true
      config.capabilities.json_schema.should be_false
    end
  end

  it "does not leak OPENAI_API_KEY into an unknown custom host" do
    with_env("OPENAI_API_KEY", "sk-secret") do
      config = Agent::Config.new(api_endpoint: "https://gateway.example.com/v1", model: "local")
      config.provider_name.should eq("custom")
      config.api_key.should be_nil
    end
  end

  it "does not confuse a lookalike host with a known preset" do
    with_env("OPENAI_API_KEY", "sk-secret") do
      config = Agent::Config.new(
        api_endpoint: "https://api.openai.com.evil.test/v1",
        model: "local",
      )
      config.provider_name.should eq("custom")
      config.api_key.should be_nil
    end
  end

  it "lets explicit endpoint/model/key override a preset" do
    config = Agent::Config.new(
      provider: "deepseek",
      api_endpoint: "https://proxy.example.com/v1",
      model: "custom-deepseek",
      api_key: "explicit",
    )
    config.provider_name.should eq("deepseek")
    config.api_endpoint.should eq("https://proxy.example.com/v1")
    config.model.should eq("custom-deepseek")
    config.api_key.should eq("explicit")
  end

  it "infers a preset from a known host" do
    Agent::Provider::Presets.infer("https://api.deepseek.com/v1").name.should eq("deepseek")
    Agent::Provider::Presets.infer("http://localhost:11434/v1").name.should eq("ollama")
    Agent::Provider::Presets.infer("https://unknown.example.com/v1").name.should eq("custom")
  end

  it "rejects unknown providers and Responses on unsupported presets" do
    expect_raises(Agent::ConfigurationError, /Unknown provider/) do
      Agent::Config.new(provider: "nope", api_endpoint: "https://x.test/v1", model: "m")
    end

    expect_raises(Agent::ConfigurationError, /Responses API/) do
      Agent::Config.new(provider: "deepseek", api_style: :responses)
    end

    expect_raises(Agent::ConfigurationError, /model is required/) do
      Agent::Config.new(provider: "groq")
    end
  end
end
