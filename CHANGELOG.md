# Changelog

## [0.3.0] - 2026-11-12

### Added

- Named provider presets: `openai`, `deepseek`, `openrouter`, `groq`,
  `together`, `ollama`, `vllm`, and `custom`, with endpoint inference,
  capability flags, per-model overrides, and env-key resolution that never
  leaks `OPENAI_API_KEY` to a custom host.
- `Agent::RequestOptions` with modern Chat Completions parameters:
  `max_completion_tokens`, `response_format`, `tool_choice`,
  `parallel_tool_calls`, `reasoning_effort`, `verbosity`, `thinking`,
  `service_tier`, `store`, `metadata`, `seed`, `stop`, penalties,
  `prompt_cache_key`, `include`, `extra_body`, `extra_headers`, and
  per-request `max_retries`. Global defaults live in
  `Config#request_options`; `#ask` accepts per-request overrides.
- OpenAI Responses API provider (`api_style: :responses`) with SSE event
  parsing, `function_call` / `function_call_output` conversion, usage mapping,
  and `Message#provider_data` replay for reasoning/tool items.
- Reliability layer: exponential backoff, jitter, `Retry-After` /
  `Retry-After-Ms` parsing, `x-should-retry`, status-specific `ApiError`
  subclasses, error-body/request-id parsing, and cross-provider fallback.
- `Response#attempts`, `#request_id`, `#output_started?`, and
  `#partial_message` diagnostics.
- DeepSeek support: `deepseek-flash` default, `thinking` controls,
  `reasoning_content` round-trip in tool conversations, `max_tokens` mapping,
  and Chat `json_schema` rejection.
- `examples/coding_cli.cr`: a minimal terminal coding agent with file/shell
  tools, approval prompts, streaming, workspace confinement, and resumable
  sessions; `shards build agent-cli --release` and
  `scripts/build_macos.sh` produce a packaged macOS binary.
- Tests for presets, request bodies, error parsing, retries, fallback,
  cancellation during backoff, history rollback, and the Responses API.
- `LICENSE` file (MIT).

### Changed

- `Agent::Config` is the single user-facing config; `Provider::OpenAI::Config`
  is now an alias.
- Provider requests are built through a capability-aware `RequestBody` and
  auth/path/query handling, including `api_path` and `query_params` overrides.
- `Message#to_request_body` can round-trip `reasoning_content`; `Tool` supports
  `strict` and Chat/Responses serializers.
- Default retries are 2; set `max_retries: 0` to disable. Retries/fallback
  stop permanently once any output chunk has been produced.

### Fixed

- Tool-argument failures now run through the handler chain like normal tool
  executions: calls whose arguments are invalid JSON or fail parameter-schema
  validation dispatch a `ToolCallContext` to registered handlers (the chain
  leaf returns the pre-built error message). Previously these two paths built
  the error message directly, bypassing `ChainHandler#decorate`, so
  handler-based tracing never observed the failed call.
- History rollback on a failed later tool-loop iteration now truncates to the
  start-of-request snapshot instead of popping the newest tool/assistant
  messages.
- Cancellation during retry backoff no longer appends a synthetic
  `"Agent error"` assistant message to history.
- Error messages no longer double-prefix `"Agent error:"` for
  `IdleTimeoutError`/`ToolLoopError`.
- Build-time errors (unsupported options or raising handlers) are converted
  into response errors instead of killing the agent fiber.
- SSE parsing now consumes the chunked-body terminator after `[DONE]`,
  preventing keep-alive corruption on the next request.

## [0.2.0] - 2026-10-19

### Fixed

- Tool-argument validation no longer skips the type check for JSON `null`.
  A `null` argument against a property that declares a `type` (e.g.
  `{"type": "array"}`) is now rejected with
  `Field '<name>' expected type '<type>', got 'null'`, giving the model a
  structured signal to self-correct. `null` still passes for properties that
  declare no `type` and for arguments absent from `properties`.
- `validate_tool_args` no longer raises (and kills the agent fiber) on schemas
  that declare `type` as an array of alternatives, e.g. `"type": ["string",
  "null"]`.

### Added

- Tool-argument validation honours `items` on array properties: elements of
  the wrong type are rejected with `Field '<name>' expected array items of
  type '<type>', got '<actual>' at index <i>`.

## [0.1.1] - 2026-09-30

First stable release. This patch release hardens the tool auto-resolve loop
and the background agent fiber, and replaces string-prefix error detection
with structured exception types.

### Fixed

- **Critical: Duplicate tool results in auto-resolve loop** (#1). Tool-result
  messages were being appended to history twice, causing malformed API requests.
- **Critical: Raising tool callbacks kill the agent fiber** (#2). A tool callback
  that raised an exception would silently terminate the background fiber,
  blocking all future `#ask` calls. Callback errors are now captured and returned
  as tool-result messages.
- **Critical: `#reset` races with in-flight requests** (#3). `#reset` now routes
  through the request channel, serializing with any pending request and waiting
  for it to complete before clearing history.
- String-prefix error detection replaced with structured error types (#4/#5).
  Added `Agent::Error`, `Agent::ConnectionError`, `Agent::ApiError`,
  `Agent::ToolError` exception classes and `Response#error?` / `Response#error`.
- SSE parser now handles `data:` (without trailing space) per the SSE spec (#24).
- `ToolCallDelta.id` and `name` use assignment (`=`) instead of `+=` (#17).
- `max_history` trimming now correctly counts user/assistant roles, avoiding
  orphaned tool messages in agentic flows (#7).

### Changed

- Removed misleading `tags: "remote"` from all spec tests (#35). Tests use a
  local mock server and don't require a remote API.

### Added

- Tests for the auto-resolve tool loop, raising callbacks, `register_tool`
  without auto_execute, `max_history` trimming, and structured error responses
  (#32, #33, #34).
- `CHANGELOG.md` (#39).
- Updated `shard.yml` author (#38).

## [0.1.0] - Initial release