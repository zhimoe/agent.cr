# agent-cr

[![CI](https://github.com/anykeyh/agent.cr/actions/workflows/ci.yml/badge.svg)](https://github.com/anykeyh/agent.cr/actions/workflows/ci.yml)

A Crystal shard for building agentic loops with OpenAI-compatible APIs.

Inspired by [RubyLLM](https://rubyllm.com/) — a fantastic Ruby gem for interacting with AI models.

`agent-cr` wraps any OpenAI-compatible streaming chat-completion endpoint behind a fiber-based async interface. It handles streaming, tool calls, multimodal content, conversation history, automatic tool resolution, named provider presets (OpenAI, DeepSeek, OpenRouter, Groq, Together, Ollama, vLLM, custom), retries/backoff, and cross-provider fallback — all in a background fiber so your code never blocks.

---

## Installation

Add this to your `shard.yml`:

```yaml
dependencies:
  agent-cr:
    github: anykeyh/agent.cr
```

Then run:

```sh
shards install
```

> Built with Crystal >= 1.19 (uses the stdlib `sync` module)

> **Fiber safety:** Safe to call `#ask` from multiple fibers; the agent serialises requests through a single background fiber. Multi-thread mode (`-Dpreview_mt`) is not tested.

---

## Quick start

```crystal
require "agent"

config = Agent::Config.new(
  api_key: ENV["OPENAI_API_KEY"],
  system_prompt: "You are a helpful assistant."
)

agent = Agent.new(config)
resp = agent.ask("What is the capital of France?")

puts resp.message.content # => "The capital of France is Paris."
```

The `#ask` call returns immediately (the HTTP request runs in a background fiber). Calling `.message` blocks until the full response is ready.

---

## Streaming

When you want to show tokens as they arrive, use `.stream`:

```crystal
resp = agent.ask("Write a short poem about AI.")

resp.stream do |chunk|
  print chunk.text  # each token as it arrives
end

puts # newline after stream ends

# The final message is still available after streaming:
puts resp.message.content
puts "Used #{resp.metadata.total_tokens} tokens"
```

### Chunk kinds

Each chunk is tagged with its origin via `chunk.kind`:

```crystal
resp.stream do |chunk|
  case chunk.kind
  when Agent::Response::ChunkKind::Content
    print chunk.text
  when Agent::Response::ChunkKind::Reasoning
    print chunk.text.colorize(:dark_gray)  # dimmed for reasoning
  when Agent::Response::ChunkKind::ToolCallName
    puts "\n[Calling tool: #{chunk.text}]"
  when Agent::Response::ChunkKind::ToolCallArgs
    # tool argument deltas
  end
end
```

---

## Conversation history

History is tracked automatically — each `#ask` appends the user message, and the agent's reply is added to the conversation.

```crystal
agent.ask("My name is Alice.").join
agent.ask("What is my name?").join

puts agent.history.size # => 4 (user, assistant, user, assistant)
```

### Reset

Start a fresh conversation without creating a new agent:

```crystal
agent.reset
```

### History trimming

Set `max_history` to limit the number of conversation turns kept in memory. The agent trims complete turn units (never orphaning tool messages).

```crystal
config = Agent::Config.new(
  api_key: ENV["OPENAI_API_KEY"],
  max_history: 10   # keep at most 10 user+assistant turns
)
```

### Save and restore sessions

Serialise a session (including cache key for prompt caching affinity):

```crystal
# Save
File.write("session.json", agent.dump)

# Restore — register tools first, then load session data:
config = Agent::Config.new(api_key: ENV["OPENAI_API_KEY"])
agent = Agent.new(config)
agent.register_tool(...) { |args| ... }
agent.load(File.read("session.json"))
agent.ask("Continue where we left off")  # 🚀 cache hit
```

---

## Attachments (multimodal)

Pass file paths, URLs, or data URIs as `attachments`. Local files are
auto-detected by extension: images become `image_url` parts, text files
are inlined, audio becomes `input_audio`, and everything else is sent as
`file` parts.

```crystal
# Remote image URL
resp = agent.ask(
  "What's in this image?",
  attachments: ["https://example.com/photo.jpg"]
)
resp.join
puts resp.message.content

# Local file — MIME auto-detected from extension
resp = agent.ask(
  "Review this document",
  attachments: ["./doc.md"]
)
```

See `Agent::ContentPart.from_path` for the MIME detection rules.

---

## Tools / function calling

### Registered tools with auto-resolve (recommended)

Register tools with a callback block. The agent automatically resolves tool calls inline — no manual while-loop needed.

```crystal
# Define JSON Schema parameters using a plain Crystal NamedTuple
params = Agent::JSONConverter.from({
  type: "object",
  properties: {
    city: {type: "string", description: "The city name"},
  },
  required: ["city"],
})

agent.register_tool("get_weather", "Get the current weather for a city",
  parameters: params
) do |args|
  city = args["city"]?.try(&.as_s) || "unknown"
  "The weather in #{city} is sunny."
end

# Registered tools are automatically included in all #ask calls.
# When the model calls a tool, the agent executes it and re-asks the
# model — all in the background fiber. The Response you get back is
# the final one (after all tool resolutions).
resp = agent.ask("What's the weather in Paris?")
resp.stream { |chunk| print chunk.text }
puts resp.message.content # => "The weather in Paris is sunny."
```

Pass `strict: true` to `register_tool` (or set `Agent::Tool::FunctionDef#strict`)
to request provider-side strict schema validation. You can `register_tool`
multiple times; all registered tools are merged into every request
automatically. If a per-request tool has the same name as a registered tool,
the registered callback wins.

### Tool activation control

You can register a tool as initially **disabled** — the definition is stored but not sent to the model until you `enable_tool`:

```crystal
agent.register_tool("roll_dice", "Roll dice in NdS format",
  parameters: params,
  enabled: false
) do |args|
  # ...
end

# Later, activate it mid-conversation:
agent.enable_tool("roll_dice")

# Or deactivate without unregistering:
agent.disable_tool("roll_dice")

# Query which tools are currently active:
agent.enabled_tools # => ["get_weather"]
```

### Session persistence

> Saved session state (including enabled tools) is serialized via `agent.dump`. On restore, create a fresh agent, register your tools, then call `agent.load(data)` — it restores the session identity, history, and re-enables any tools that match:

```crystal
agent = Agent.new(config)
agent.register_tool("get_weather", ...) { |args| ... }
agent.register_tool("roll_dice", ..., enabled: false) { |args| ... }

# Restore session identity, history, and enabled-tool state:
saved = File.read("session.json")
agent.load(saved)  # warnings for tools not re-registered
```

### Disable auto-resolve

To handle tool calls manually (e.g. only some tools are registered, or you need user approval):

```crystal
config = Agent::Config.new(
  api_key: ENV["OPENAI_API_KEY"],
  auto_execute_tools: false
)
```

With `auto_execute_tools: false`, the agent returns tool calls to the caller and you dispatch manually in a loop. You pass tool definitions per-request (see [#tool-definitions](#tool-definitions) for the syntax) and implement the tool logic yourself with a `case`:

```crystal
resp = agent.ask("What's the weather in Paris?", tools: [weather_tool])
resp.stream { |chunk| print chunk }
msg = resp.message

while msg.has_tool_calls?
  results = msg.tool_calls.not_nil!.map do |tc|
    args = JSON.parse(tc.arguments).as_h
    case tc.name
    when "get_weather"
      result = fetch_weather(args["city"].to_s)
      Agent::Message.tool_result(tc, result)
    else
      Agent::Message.tool_result(tc, "Unknown tool: #{tc.name}")
    end
  end

  resp = agent.ask(results, tools: [weather_tool])
  resp.stream { |chunk| print chunk }
  msg = resp.message
end

puts msg.content
```

### Tool definitions

When passing tools per-request without `register_tool`, you build a `Tool` object directly. Use `Agent::JSONConverter` to avoid the `JSON::Any.new(...)` boilerplate:

```crystal
weather_tool = Agent::Tool.new(Agent::Tool::FunctionDef.new(
  name: "get_weather",
  description: "Get the current weather for a city",
  parameters: Agent::JSONConverter.from({
    type:       "object",
    properties: {
      city: {type: "string", description: "The city name"},
    },
    required: ["city"],
  })
))
```

Then pass it to `#ask`: `agent.ask("...", tools: [weather_tool])` — see the manual dispatch loop above for how to handle tool calls when they arrive.

---

## Handler chain

`agent-cr` provides a middleware-style handler chain that wraps every stage of the request pipeline. Handlers can inspect, mutate, or short-circuit requests before they reach the API, and responses before they reach your code.

### Architecture

Four context types correspond to the four pipeline stages. A `Handler` subclass overrides the `handle` overloads it cares about; each receives the context and a `next_proc` that invokes the rest of the chain:

| Context | Stage | Attack surface |
|---|---|---|
| `TurnContext` | Before the HTTP request is built | Mutate `ctx.messages` and `ctx.tools` before they're sent to the model |
| `ChunkContext` | Each streamed SSE delta | Replace `ctx.chunk` to rewrite tokens in-flight |
| `ToolCallContext` | Around each tool call — argument parse and validation failures included | Approve/deny tool execution, cancel the response |
| `ErrorContext` | After an exception escapes the pipeline | Wrap or replace the error before it's recorded |

### Writing a handler

```crystal
class LoggingHandler < Agent::Handler
  # Override only the stages you care about — the default is a pass-through.
  def handle(ctx : Agent::TurnContext, next_proc) : {Agent::Message, Agent::Usage, String?}
    puts "Sending #{ctx.messages.size} messages..."
    result = next_proc.call(ctx)
    puts "Received response."
    result
  end
end
```

> **Mutation rules:** `Chunk` is a class; reassign `ctx.chunk = Chunk.new(...)` to rewrite chunks. `Message` is immutable; replace entries in `ctx.messages` with new `Message` objects to rewrite user input.

### Registration

Append handlers with `agent.use`. Handlers run left-to-right in registration order — the first handler registered wraps the outermost layer:

```crystal
agent.use(LoggingHandler.new)
agent.use(TokenBudgetHandler.new)
```

### Short-circuiting

A handler can prevent the rest of the chain from running by returning a value without calling `next_proc`. This is useful for gating tool calls, denying requests, or serving cached responses:

```crystal
class GateKeeper < Agent::Handler
  def handle(ctx : Agent::ToolCallContext, next_proc) : Agent::Message
    if ctx.tool_call.name == "dangerous_op"
      Agent::Message.new(
        role: Agent::Role::Tool,
        content: "Tool '#{ctx.tool_call.name}' denied by policy.",
        tool_call_id: ctx.tool_call.id,
        name: ctx.tool_call.name,
      )
    else
      next_proc.call(ctx)
    end
  end
end
```

### Example

See `examples/handlers.cr` for a working CLI that demonstrates four handlers:

| Handler | Context | What it does |
|---|---|---|
| `TokenBudgetHandler` | `TurnContext` | Times the turn, prints `tok/s`, enforces a session token budget |
| `WordReplaceHandler` | `TurnContext` + `ChunkContext` | Rewrites words on both sides of the conversation (`hello` → `howdy`, `world` → `galaxy`) |
| `ToolConfirmHandler` | `ToolCallContext` | Prompts the user before executing tools; short-circuits on decline |
| `ErrorRetryHandler` | `ErrorContext` | Colorizes errors by type |

```sh
crystal run examples/handlers.cr
```

---

## Provider system

`agent-cr` uses a provider-neutral core with named OpenAI-compatible presets.
The default is the `openai` preset. Presets are data: endpoint, auth header,
path, default model, and capability flags. One generic Chat Completions engine
handles OpenAI, DeepSeek, OpenRouter, Groq, Together, Ollama, vLLM, and any
custom OpenAI-compatible endpoint.

### Provider presets

```crystal
# DeepSeek: endpoint/model/auth come from the preset. The API key is read from
# DEEPSEEK_API_KEY only when the provider is named explicitly.
config = Agent::Config.new(
  provider: "deepseek",
  system_prompt: "You are a coding assistant.",
)

agent = Agent.new(config)
```

Built-in presets: `openai`, `deepseek`, `openrouter`, `groq`, `together`,
`ollama`, `vllm`, `custom`. Explicit `api_endpoint`, `model`, and `api_key`
override preset defaults. `provider: "custom"` requires an endpoint; when
`model` is omitted it falls back to `gpt-4o` with a warning for backward
compatibility. Other presets without a default model require an explicit
`model`.

### Modern request options

Global defaults live in `config.request_options`; per-request overrides are
passed to `#ask`:

```crystal
schema = Agent::JSONConverter.from({
  type: "object",
  properties: {answer: {type: "string"}},
  required: ["answer"],
})

defaults = Agent::RequestOptions.new
defaults.max_completion_tokens = 4096
defaults.reasoning_effort = "medium"
defaults.response_format = Agent::ResponseFormat.json_schema(
  "answer", schema, strict: true
)

config = Agent::Config.new(
  provider: "openai",
  model: "gpt-5",
  request_options: defaults,
)

override = Agent::RequestOptions.new
override.parallel_tool_calls = false
override.tool_choice = Agent::ToolChoice.auto
resp = agent.ask("Return JSON", options: override)
```

`RequestOptions` covers `max_tokens`/`max_completion_tokens`, temperature,
top_p, stop, seed, penalties, reasoning_effort, verbosity, thinking, store,
metadata, service_tier, parallel_tool_calls, tool_choice, response_format,
prompt_cache_key, include, extra_body, extra_headers, and max_retries.
Provider-specific long-tail fields go through `extra_body`.

Capabilities are checked before HTTP: a feature the preset cannot honor
raises `Agent::UnsupportedCapabilityError` (which may fall back to another
provider) instead of being silently dropped.

### Retries and fallback

```crystal
config = Agent::Config.new(
  provider: "openai",
  model: "gpt-5",
  max_retries: 2,                    # default 2; 0 disables retries
  retry_backoff_base: 500.milliseconds,
  retry_backoff_max: 8.seconds,
  max_retry_after: 120.seconds,
  fallbacks: [
    Agent::Config.new(provider: "deepseek", model: "deepseek-flash", max_retries: 0),
  ],
)
```

- Retries: `408`, `409`, `429`, `>=500`, connection errors, and first-byte
  timeouts, with exponential backoff + jitter and `Retry-After` support.
- `x-should-retry: true|false` overrides the status-based decision.
- Fallback: on any non-fatal error before streamed output starts (including
  capability mismatches, 400/401/404), the next provider config is tried.
- Once any content/reasoning/tool-call chunk has been produced, no retry or
  fallback is attempted.
- `Response#attempts` exposes `provider`, `model`, `status_code`,
  `request_id`, `retry_after`, `duration`, `delay_before`, and `error`.

### Responses API

Use `api_style: :responses` to switch the wire format (OpenAI preset):

```crystal
config = Agent::Config.new(
  provider: "openai",
  model: "gpt-5",
  api_style: :responses,
)
```

The Responses provider converts canonical `Message` history into `input`
items (`function_call` / `function_call_output`), uses flat `tools` and
`tool_choice`, maps `text.format`, and parses
`response.output_text.delta`, reasoning deltas,
`response.function_call_arguments.delta/done`, and
`response.completed/failed/incomplete`. It defaults to `store: false`; original
output items are stored on `Message#provider_data` and replayed on later turns
when the provider/model match, preserving reasoning items.

### Switch endpoint for a compatible API

```crystal
# Any OpenAI-compatible endpoint works:
config = Agent::Config.new(
  api_key: "not-needed",
  api_endpoint: "http://localhost:8080/v1",
  model: "local-model",
)
```

### Custom provider

Implement `Agent::Provider::Base` to support a different wire format:

```crystal
class MyProvider < Agent::Provider::Base
  def base_uri : URI
    URI.parse("https://myapi.com/v1")
  end

  def build_request(messages, tools) : NamedTuple(path: String, headers: HTTP::Headers, body: String)
    # Build path, auth headers, and JSON body
    {path: "/chat", headers: HTTP::Headers{"X-API-Key" => "secret"}, body: my_body.to_json}
  end

  def parse_stream(io, response, cancel,
                   first_byte_timeout : Time::Span? = nil,
                   idle_timeout : Time::Span? = nil) : {Message, Usage, String?}
    # Parse response body, push chunks, return final message
  end

  def close : Nil
  end
end

agent = Agent.new(config, provider: MyProvider.new(...))
```

---

## Response handle

| Method / Property | Description |
|---|---|
| `.stream { \|chunk\| }` | Yield each delta as it arrives from the API |
| `.message` | Block until the final `Message` is ready, then return it |
| `.metadata` | Block until `Usage` (token counts) is ready, then return it. With `auto_execute_tools`, the counts of every tool-loop iteration are summed, so this is the whole turn's usage |
| `.join` | Block until both message and metadata are ready |
| `.finished?` | Poll whether the response is complete |
| `.error?` | Whether the response represents a failed request |
| `.error` | The `Agent::Error` if the request failed, or `nil` |
| `.finish_reason` | Why the stream ended (`"stop"`, `"length"`, `"tool_calls"`, etc.) |
| `.cancel` | Request cancellation of the in-flight request |
| `.cancelled?` | Whether cancellation was requested |
| `.attempts` | Diagnostic list of provider attempts (provider, model, status, error, request id, retry-after, duration, delay) |
| `.request_id` | HTTP request id of the successful/final attempt |

### Message fields

```crystal
msg = resp.message
msg.content        # String? — text content
msg.reasoning      # String? — reasoning content (DeepSeek, Qwen, etc.)
msg.role           # Agent::Role — System, User, Assistant, Tool
msg.tool_calls     # Array(ToolCall)? — function calls from the model
msg.tool_call_id   # String? — id for tool result messages
msg.content_parts  # Array(ContentPart)? — multimodal parts (text + images)
msg.has_tool_calls? # Bool — convenience check
```

---

## Configuration

```crystal
Agent::Config.new(
  provider:          String?,              # preset name; default "openai" / inferred from endpoint
  api_key:           String?,              # explicit key; otherwise preset env key when safe
  api_endpoint:      String?,              # preset default or explicit base URL
  model:             String?,              # preset default or explicit model
  system_prompt:     String?,              # optional system message prepended to every request
  max_tokens:        Int32?,               # legacy token cap; mapped per provider
  temperature:       Float64?,             # optional sampling temperature (0.0-2.0)
  read_timeout:      Time::Span | Int32?,  # optional HTTP read timeout
  connect_timeout:   Time::Span | Int32?,  # optional HTTP connect timeout
  max_history:       Int32?,               # optional max conversation turns
  auto_execute_tools: Bool,                # default: true
  extra_headers:     Hash(String, String)?,
  max_tool_iterations: Int32?,             # default: 100
  prompt_cache_key:  String?,
  request_options:   RequestOptions?,      # modern request defaults
  api_style:         Symbol?,              # :chat_completions (default) or :responses
  api_path:          String?,              # override path (Azure-style deployments)
  query_params:      Hash(String, String)?,
  fallbacks:         Array(Config)?,       # cross-provider fallback configs
  retry_policy:      RetryPolicy?,         # full policy injection
  max_retries:       Int32?,               # default: 2
  retry_backoff_base: Time::Span | Int32?, # default: 500ms
  retry_backoff_max:  Time::Span | Int32?, # default: 8s
  max_retry_after:    Time::Span | Int32?, # default: 120s
  strict_stream_end: Bool?,                # preset default; error on truncated output
  *,
  # Per-read SSE timeouts (fail-fast on hung connections):
  first_byte_timeout_min:          Time::Span | Int32 = 60,
  first_byte_timeout_max:          Time::Span | Int32 = 300,
  first_byte_timeout_base:         Time::Span | Int32 = 3,
  first_byte_timeout_ms_per_token: Int32 = 3,
  idle_byte_timeout:               Time::Span | Int32 = 60,
  compute_first_byte_timeout:      Bool = true,
)
```

#### Per-read SSE timeouts (fail-fast on hung streams)

The HTTP client's `read_timeout` is per-read: as long as *each* SSE line
arrives within the idle budget, long-lived streams run unbounded. Two
budgets are enforced independently:

- **First-byte** (`compute_first_byte_timeout`): scales with prompt size so
  short prompts fail fast (60s floor) while huge prompts get a generous
  time-to-first-token budget (300s ceiling). Formula:
  `clamp(base + (prompt_bytes / 4) * ms_per_token, min, max)`.
- **Inter-byte (idle)**: 60s fixed by default — gap allowed between any two
  consecutive lines mid-stream. Any byte arrival (comment lines like
  `: OPENROUTER PROCESSING`, empty lines, the `[DONE]` sentinel) resets it.

When the dynamic first-byte is disabled (`compute_first_byte_timeout: false`),
both the first read and subsequent reads fall back to `idle_byte_timeout`.

```crystal
config = Agent::Config.new(
  api_key: ENV["OPENAI_API_KEY"],
  # Tighter fail-fast: 10s first byte, 5s inter-line gap
  first_byte_timeout_min: 10.seconds,
  first_byte_timeout_max: 60.seconds,
  idle_byte_timeout: 5.seconds,
)
# → a prompt that emits nothing for 10s raises Agent::IdleTimeoutError
#   (first-byte timeouts are retryable per RetryPolicy); a mid-stream 5s
#   stall surfaces the error without retrying after output has started.
```

---

## Error handling

Errors provide a consistent `"Agent error: ..."` prefix on the message content, so you can pattern-match programmatically:

```crystal
resp = agent.ask("Hello")
resp.join

if resp.error?
  puts "Request failed: #{resp.error.message}"
  puts resp.error.class  # Agent::ConnectionError, Agent::ApiError, etc.
else
  puts resp.message.content
end
```

Error types:

| Error | When |
|---|---|
| `Agent::ApiError` | Non-2xx API response; exposes `.status_code`, `.body`, `.request_id`, `.retry_after`, `.api_type`, `.param`, `.code`, `.should_retry` |
| `Agent::BadRequestError` / `AuthenticationError` / `PermissionDeniedError` / `NotFoundError` / `RequestTimeoutError` / `ConflictError` / `UnprocessableEntityError` / `RateLimitError` / `InternalServerError` | Status-specific `ApiError` subclasses |
| `Agent::ConnectionError` | Network / connection failure |
| `Agent::StreamError` / `StreamTruncatedError` | Provider error event or truncated SSE stream |
| `Agent::CancelledError` | Caller called `.cancel` on the response |
| `Agent::IdleTimeoutError` | Provider stream stuck — no bytes within the first-byte or idle per-read timeout (`phase = :first_byte` or `:idle`) |
| `Agent::UnsupportedCapabilityError` | The configured provider/model cannot honor a requested feature; eligible for fallback |
| `Agent::ConfigurationError` | Invalid client-side configuration or reserved `extra_body` key; fatal for the turn |
| `Agent::ToolLoopError` | Tool auto-resolve exceeded `max_tool_iterations` |
| `Agent::SessionLoadError` | Loading a saved session failed due to corrupt or missing fields |
| `Agent::ClosedError` | An operation was attempted on a closed agent |

---

## Best practices

### Timeouts

Set timeouts in production — the defaults for the legacy `read_timeout` /
`connect_timeout` are unbounded (nil). The per-read SSE timeouts `first_byte_timeout_*` /
`idle_byte_timeout` have safe defaults (60s idle / 60s first-byte floor) and take
precedence over `read_timeout` for streaming requests:

```crystal
config = Agent::Config.new(
  api_key: ENV["OPENAI_API_KEY"],
  connect_timeout: 10.seconds,         # connect budget (total)
  # Streaming SSE timeouts (per-read, NOT total-time):
  first_byte_timeout_min: 60.seconds,  # floor on TTFT budget
  first_byte_timeout_max: 300.seconds, # ceiling even for huge prompts
  idle_byte_timeout: 60.seconds,       # gap allowed between two consecutive SSE lines
)
```

If a provider stream stalls past these budgets the agent raises
`Agent::IdleTimeoutError` (with `.phase = :first_byte` or `:idle`) and the
HTTP connection is rebuilt to avoid reusing a socket in an unknown state.
Cancellation wins over timeout when both fire (see `process_request_loop`).

### Cleanup

Close the agent when done to shut down the background fiber and release the HTTP connection pool. **Important:** Dropping the reference without calling `#close` leaks the background fiber — it will block indefinitely waiting for requests on its channel.

```crystal
agent.close
```

### Prompt caching

OpenAI supports an explicit `prompt_cache_key` (gated by the preset's
capability flags). Set one or use `agent.load` to restore a previous session —
both preserve cache affinity. Providers such as DeepSeek use their own
automatic KV cache and do not receive `prompt_cache_key`:

```crystal
# Auto-generated cache key tied to the session
agent = Agent.new(config)

# Restored session keeps the same cache_key:
agent = Agent.new(config)
agent.load(saved_session_string)
```

---

## Examples

### Provider presets and reliability

```sh
# Pick a preset and override modern request options
crystal run examples/providers.cr -- --provider deepseek

# Retries + optional cross-provider fallback
crystal run examples/reliability.cr -- --endpoint "$LLM_ENDPOINT" \
  --model "$LLM_MODEL" --api-key "$LLM_API_KEY"
```

### 🎲 Dungeons & Dragons — Text Adventure

`examples/rpg.cr` is a fully playable D&D-style parody adventure. You pick a hero class, the LLM becomes your Dungeon Master, and game mechanics (HP, damage, ability checks, inventory) are enforced by registered Crystal tools — no cheating allowed, not even for the DM.

```sh
crystal run examples/rpg.cr
```

**How it works:**

- The system prompt instructs the DM to narrate in the spirit of *Le Donjon de Naheulbeuk* and Monty Python — absurdist, self-aware, and allergic to drama.
- Twelve registered tools (`roll_check`, `take_damage`, `heal`, `add_item`, etc.) handle all rule interactions. The DM calls them via function calling; the agent auto-resolves them in the background.
- Sessions auto-save after every turn. You can quit, come back, and resume exactly where you left off — the agent's history and session identity are preserved.
- Reasoning tokens (DeepSeek, Qwen, etc.) are hidden behind a spinner: *"The DM is preparing your adventure..."* while the model thinks, then replaced by the actual narration.
- Tool call internals are kept off-screen. The DM narrates outcomes naturally — you see roll *"🎲 15 — Success!"* as prose.

**Game mechanics? More like game *suggestions*.** The DM has tools, yes. The DM *should* use them. But nobody said the DM was competent. Every `roll_check` is faithfully executed by Crystal, but whether the DM remembers to call `is_alive` after dealing damage is entirely between them and their questionable deity. The wizard has a spellbook; the rogue has lockpicks, and the warrior a _big fat sword_.

```sh
# Optional flags:
crystal run examples/rpg.cr -- --endpoint http://localhost:8080/v1 --model llama3
```

Hero classes include Fighter (solves problems with violence), Wizard (solves problems with different violence), Rogue (solves problems by pretending they aren't there), and Cleric (solves problems by lecturing everyone about it). Sessions are saved to `examples/rpg/`. Try `/hero` to see your sheet, `/reset` when you inevitably die, and `/help` when you forget which button does what.

---

## Contributing

See [AGENTS.md](AGENTS.md) for the architecture overview and development workflow.

### Quick commands

```sh
shards install           # install dependencies
crystal spec             # run tests
crystal tool format      # format code
bin/ameba                # lint
```

---

## License

MIT
