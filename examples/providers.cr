require "dotenv"
require "../src/agent"

Dotenv.load(".env.local")

# Example: pick a provider preset and override the modern request options.
#
# Usage:
#   crystal run examples/providers.cr -- --provider deepseek
#   crystal run examples/providers.cr -- --provider custom \
#     --endpoint http://localhost:8080/v1 --model local-model --api-key x
#
# Configuration precedence (checked in order):
#   CLI arguments > environment variables > preset defaults

provider = "openai"
endpoint = nil
model = nil
api_key = nil

args = ARGV.dup
i = 0
while i < args.size
  case args[i]
  when "--provider" then provider = args[i + 1] if i + 1 < args.size
  when "--endpoint" then endpoint = args[i + 1] if i + 1 < args.size
  when "--model"    then model = args[i + 1] if i + 1 < args.size
  when "--api-key"  then api_key = args[i + 1] if i + 1 < args.size
  when "--help"
    puts "Usage: crystal run examples/providers.cr -- [options]"
    puts "  --provider NAME  Preset: openai, deepseek, openrouter, groq,"
    puts "                   together, ollama, vllm, custom"
    puts "  --endpoint URL   Override the preset endpoint"
    puts "  --model NAME     Override the preset model"
    puts "  --api-key KEY    Override the preset/env API key"
    exit 0
  end
  i += 1
end

options = Agent::RequestOptions.new
options.max_completion_tokens = 512
options.temperature = 0.2
options.parallel_tool_calls = false

config = Agent::Config.new(
  provider: provider,
  api_endpoint: endpoint,
  model: model,
  api_key: api_key,
  system_prompt: "You are a concise coding assistant.",
  request_options: options,
)

agent = Agent.new(config)
resp = agent.ask("In one sentence, what is a fiber?")
resp.stream { |chunk| print chunk.text }
puts
puts "provider=#{config.provider_name} model=#{config.model} attempts=#{resp.attempts.size}"
agent.close
