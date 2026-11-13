require "dotenv"
require "../src/agent"

Dotenv.load(".env.local")

# Example: retries with Retry-After/backoff plus a cross-provider fallback.
#
# Usage:
#   crystal run examples/reliability.cr -- --endpoint https://api.openai.com/v1 \
#     --model gpt-5 --api-key "$OPENAI_API_KEY"
#
# Optional fallback:
#   LLM_FALLBACK_ENDPOINT=https://api.deepseek.com \
#   LLM_FALLBACK_MODEL=deepseek-flash \
#   LLM_FALLBACK_API_KEY="$DEEPSEEK_API_KEY" \
#   crystal run examples/reliability.cr ...

endpoint = nil
model = nil
api_key = nil

args = ARGV.dup
i = 0
while i < args.size
  case args[i]
  when "--endpoint" then endpoint = args[i + 1] if i + 1 < args.size
  when "--model"    then model = args[i + 1] if i + 1 < args.size
  when "--api-key"  then api_key = args[i + 1] if i + 1 < args.size
  end
  i += 1
end

endpoint ||= ENV.fetch("LLM_ENDPOINT") { raise "Missing LLM_ENDPOINT" }
model ||= ENV.fetch("LLM_MODEL") { raise "Missing LLM_MODEL" }
api_key ||= ENV.fetch("LLM_API_KEY") { raise "Missing LLM_API_KEY" }

fallbacks = [] of Agent::Config
if fallback_endpoint = ENV["LLM_FALLBACK_ENDPOINT"]?
  fallbacks << Agent::Config.new(
    api_endpoint: fallback_endpoint,
    model: ENV.fetch("LLM_FALLBACK_MODEL") { raise "Missing LLM_FALLBACK_MODEL" },
    api_key: ENV.fetch("LLM_FALLBACK_API_KEY") { raise "Missing LLM_FALLBACK_API_KEY" },
    max_retries: 0,
  )
end

config = Agent::Config.new(
  api_endpoint: endpoint,
  model: model,
  api_key: api_key,
  max_retries: 2,
  retry_backoff_base: 500.milliseconds,
  retry_backoff_max: 8.seconds,
  max_retry_after: 120.seconds,
  fallbacks: fallbacks,
  system_prompt: "You are a concise assistant.",
)

agent = Agent.new(config)
resp = agent.ask("Say hello.")
resp.join

puts resp.message.content
resp.attempts.each do |attempt|
  puts "attempt=#{attempt.index} provider=#{attempt.provider} model=#{attempt.model} " \
       "status=#{attempt.status_code} error=#{attempt.error.try(&.class)} " \
       "delay_before=#{attempt.delay_before.try(&.total_milliseconds)}ms"
end

agent.close
