require "digest/sha256"
require "dotenv"
require "file/match"
require "option_parser"
require "process"
require "signal"
require "../src/agent"

Dotenv.load(".env.local") if File.exists?(".env.local")

STDOUT.sync = true
STDERR.sync = true

# A small terminal coding agent built on agent-cr.
#
# It intentionally lives in examples/: the library stays a library, while this
# file shows how to turn it into a practical CLI with file/shell tools,
# approval prompts, streaming output, and a resumable session.

private class LimitedOutput < IO
  getter truncated = false

  def initialize(@limit : Int32)
    @buffer = IO::Memory.new
    @size = 0
  end

  def write(slice : Bytes) : Nil
    remaining = @limit - @size
    return if remaining <= 0

    if slice.size <= remaining
      @buffer.write(slice)
      @size += slice.size
    else
      @buffer.write(slice[0, remaining])
      @size = @limit
      @truncated = true
    end
  end

  def read(slice : Bytes) : Int32
    raise "LimitedOutput is write-only"
  end

  def flush : Nil
  end

  def text : String
    @buffer.to_s
  end
end

private class CodingTools
  MAX_LIST_FILES     =           300
  MAX_SEARCH_RESULTS =           120
  MAX_SEARCH_FILES   =        10_000
  MAX_SEARCH_SIZE    = 1_048_576_i64
  MAX_READ_LINES     =           400
  MAX_TOOL_OUTPUT    =        32_000
  MAX_STDOUT         =        24_000
  MAX_STDERR         =         8_000
  WALK_DEPTH         =             8

  SKIP_DIRS = %w[
    .git .hg .svn node_modules target build dist vendor lib bin
    .cache .next .nuxt .venv venv __pycache__ .idea .vscode
  ]

  def initialize(@workspace : String)
  end

  def register(agent : Agent) : Nil
    agent.register_tool(
      "list_files",
      "List files under the workspace. Paths are relative to the workspace. " \
      "Use pattern as an optional glob, e.g. **/*.cr.",
      parameters: Agent::JSONConverter.from({
        type:       "object",
        properties: {
          path:    {type: "string", description: "Directory relative to the workspace (default: .)"},
          pattern: {type: "string", description: "Optional glob matched against the relative path"},
        },
        required: [] of String,
      })
    ) do |args|
      list_files(args)
    end

    agent.register_tool(
      "read_file",
      "Read a text file from the workspace. Returns line-numbered content. " \
      "Use start_line/max_lines to page through large files.",
      parameters: Agent::JSONConverter.from({
        type:       "object",
        properties: {
          path:       {type: "string", description: "File path relative to the workspace"},
          start_line: {type: "integer", description: "1-based first line (default: 1)"},
          max_lines:  {type: "integer", description: "Maximum lines to return (default: 200, max: 1000)"},
        },
        required: ["path"],
      })
    ) do |args|
      read_file(args)
    end

    agent.register_tool(
      "write_file",
      "Create or replace a file in the workspace. Requires approval.",
      parameters: Agent::JSONConverter.from({
        type:       "object",
        properties: {
          path:    {type: "string", description: "File path relative to the workspace"},
          content: {type: "string", description: "Full file content"},
        },
        required: ["path", "content"],
      })
    ) do |args|
      write_file(args)
    end

    agent.register_tool(
      "edit_file",
      "Replace an exact substring in a file. Requires approval. If old_string " \
      "occurs more than once, provide more context or set replace_all=true.",
      parameters: Agent::JSONConverter.from({
        type:       "object",
        properties: {
          path:        {type: "string", description: "File path relative to the workspace"},
          old_string:  {type: "string", description: "Exact text to replace"},
          new_string:  {type: "string", description: "Replacement text"},
          replace_all: {type: "boolean", description: "Replace every occurrence (default: false)"},
        },
        required: ["path", "old_string", "new_string"],
      })
    ) do |args|
      edit_file(args)
    end

    agent.register_tool(
      "search_files",
      "Search file contents in the workspace using a plain substring. " \
      "Returns path:line: text for up to #{MAX_SEARCH_RESULTS} matches.",
      parameters: Agent::JSONConverter.from({
        type:       "object",
        properties: {
          pattern: {type: "string", description: "Plain text to search for"},
          glob:    {type: "string", description: "Optional glob filter, e.g. **/*.cr"},
        },
        required: ["pattern"],
      })
    ) do |args|
      search_files(args)
    end

    agent.register_tool(
      "run_command",
      "Run a non-interactive shell command in the workspace. Requires approval. " \
      "Stdout/stderr are captured and truncated; stdin is closed. " \
      "timeout_seconds defaults to 60 and is capped at 300.",
      parameters: Agent::JSONConverter.from({
        type:       "object",
        properties: {
          command:         {type: "string", description: "Shell command to run with sh -c"},
          timeout_seconds: {type: "integer", description: "Timeout in seconds (1-300, default 60)"},
        },
        required: ["command"],
      })
    ) do |args|
      run_command(args)
    end
  end

  private def list_files(args : Hash(String, JSON::Any)) : String
    root = resolve_path(optional_string(args, "path") || ".")
    raise ArgumentError.new("not a directory: #{relative_path(root)}") unless File.directory?(root)

    files = [] of String
    walk_files(root, 0, files, MAX_LIST_FILES)

    pattern = optional_string(args, "pattern")
    relative = files.map { |path| relative_path(path) }
    relative = relative.select { |path| File.match?(pattern, path) } if pattern
    relative.sort!

    return "(no files)" if relative.empty?
    result = relative.join('\n')
    result += "\n...[truncated after #{MAX_LIST_FILES} entries]" if files.size >= MAX_LIST_FILES
    truncate_tool_output(result)
  end

  private def read_file(args : Hash(String, JSON::Any)) : String
    path = resolve_path(required_string(args, "path"))
    raise ArgumentError.new("not a file: #{relative_path(path)}") unless File.file?(path)

    start_line = (optional_int(args, "start_line") || 1).clamp(1, Int32::MAX)
    max_lines = (optional_int(args, "max_lines") || 200).clamp(1, 1000)

    lines = [] of String
    line_no = 0
    File.each_line(path) do |line|
      line_no += 1
      next if line_no < start_line
      break if lines.size >= max_lines
      lines << "#{line_no}: #{line}"
    end

    if lines.empty?
      return "(no content at or after line #{start_line}; file has #{line_no} lines)"
    end

    result = lines.join('\n')
    result += "\n...[stopped at #{max_lines} lines]" if lines.size == max_lines
    truncate_tool_output(result)
  end

  private def write_file(args : Hash(String, JSON::Any)) : String
    path = resolve_path(required_string(args, "path"))
    content = required_string(args, "content")
    Dir.mkdir_p(File.dirname(path))
    File.write(path, content)
    "Wrote #{content.bytesize} bytes to #{relative_path(path)}"
  end

  private def edit_file(args : Hash(String, JSON::Any)) : String
    path = resolve_path(required_string(args, "path"))
    old_string = required_string(args, "old_string")
    new_string = required_string(args, "new_string")
    replace_all = optional_bool(args, "replace_all") || false

    raise ArgumentError.new("old_string must not be empty") if old_string.empty?
    raise ArgumentError.new("not a file: #{relative_path(path)}") unless File.file?(path)

    content = File.read(path)
    count = content.scan(Regex.new(Regex.escape(old_string))).size
    raise ArgumentError.new("old_string not found in #{relative_path(path)}") if count == 0
    if count > 1 && !replace_all
      raise ArgumentError.new(
        "old_string occurs #{count} times in #{relative_path(path)}; " \
        "provide more context or set replace_all=true"
      )
    end

    updated = replace_all ? content.gsub(old_string, new_string) : content.sub(old_string, new_string)
    File.write(path, updated)
    "Updated #{relative_path(path)} (#{replace_all ? count : 1} replacement(s))"
  end

  private def search_files(args : Hash(String, JSON::Any)) : String
    pattern = required_string(args, "pattern")
    glob = optional_string(args, "glob")
    raise ArgumentError.new("pattern must not be empty") if pattern.empty?

    files = [] of String
    walk_files(@workspace, 0, files, MAX_SEARCH_FILES)

    matches = [] of String
    files.each do |file|
      break if matches.size >= MAX_SEARCH_RESULTS
      relative = relative_path(file)
      next if glob && !File.match?(glob, relative)

      begin
        next if File.size(file) > MAX_SEARCH_SIZE
        line_no = 0
        File.each_line(file) do |line|
          line_no += 1
          if line.includes?(pattern)
            matches << "#{relative}:#{line_no}: #{truncate_text(line, 200)}"
            break if matches.size >= MAX_SEARCH_RESULTS
          end
        end
      rescue IO::Error
        # skip unreadable/binary files
      end
    end

    return "(no matches)" if matches.empty?
    truncate_tool_output(matches.join('\n'))
  end

  private def run_command(args : Hash(String, JSON::Any)) : String
    command = required_string(args, "command")
    timeout_seconds = (optional_int(args, "timeout_seconds") || 60).clamp(1, 300)
    run_shell(command, timeout_seconds.seconds)
  end

  private def run_shell(command : String, timeout_span : Time::Span) : String
    stdout = LimitedOutput.new(MAX_STDOUT)
    stderr = LimitedOutput.new(MAX_STDERR)
    process = Process.new(
      "sh", ["-c", command],
      chdir: @workspace,
      input: Process::Redirect::Close,
      output: Process::Redirect::Pipe,
      error: Process::Redirect::Pipe,
    )

    out_done = Channel(Nil).new
    err_done = Channel(Nil).new
    wait_done = Channel(Int32).new

    spawn do
      IO.copy(process.output, stdout)
    rescue
    ensure
      out_done.send(nil)
    end
    spawn do
      IO.copy(process.error, stderr)
    rescue
    ensure
      err_done.send(nil)
    end
    spawn do
      wait_done.send(process.wait.exit_code)
    rescue
      wait_done.send(-1)
    end

    timed_out = false
    exit_code = -1
    select
    when code = wait_done.receive
      exit_code = code
    when timeout(timeout_span)
      timed_out = true
      begin
        process.signal(Signal::KILL)
      rescue
      end
      select
      when code = wait_done.receive
        exit_code = code
      when timeout(2.seconds)
      end
    end

    # Drain the readers so the pipes are not closed underneath them.
    select
    when out_done.receive
    when timeout(2.seconds)
    end
    select
    when err_done.receive
    when timeout(2.seconds)
    end
    process.close rescue nil

    status = timed_out ? "timeout after #{timeout_span.total_seconds.round(1)}s" : "exit #{exit_code}"
    parts = ["status: #{status}"]
    out = stdout.text
    err = stderr.text
    parts << "stdout:\n#{out}" unless out.empty?
    parts << "stderr:\n#{err}" unless err.empty?
    parts << "[stdout truncated]" if stdout.truncated
    parts << "[stderr truncated]" if stderr.truncated
    truncate_tool_output(parts.join("\n"))
  end

  private def walk_files(dir : String, depth : Int32, results : Array(String), limit : Int32) : Nil
    return if depth > WALK_DEPTH || results.size >= limit

    Dir.each_child(dir) do |name|
      break if results.size >= limit
      next if SKIP_DIRS.includes?(name)

      path = File.join(dir, name)
      next if File.symlink?(path)

      if File.directory?(path)
        walk_files(path, depth + 1, results, limit)
      elsif File.file?(path)
        results << path
      end
    end
  rescue File::Error
    # unreadable directory
  end

  private def resolve_path(input : String) : String
    raise ArgumentError.new("path must not be empty") if input.empty?
    expanded = File.expand_path(input, @workspace)

    if File.exists?(expanded)
      real = resolve_real_path(expanded)
      ensure_within_workspace!(real)
      real
    else
      ancestor = File.dirname(expanded)
      until File.exists?(ancestor) || ancestor == @workspace
        ancestor = File.dirname(ancestor)
      end
      ensure_within_workspace!(resolve_real_path(ancestor))
      ensure_within_workspace!(expanded)
      expanded
    end
  end

  private def ensure_within_workspace!(path : String) : Nil
    prefix = @workspace.ends_with?(File::SEPARATOR) ? @workspace : @workspace + File::SEPARATOR
    unless path == @workspace || path.starts_with?(prefix)
      raise ArgumentError.new("path escapes workspace: #{path}")
    end
  end

  private def relative_path(path : String) : String
    return "." if path == @workspace
    prefix = @workspace + File::SEPARATOR
    path.starts_with?(prefix) ? path[prefix.size..] : path
  end

  private def required_string(args : Hash(String, JSON::Any), key : String) : String
    value = args[key]?.try(&.as_s?)
    raise ArgumentError.new("missing string argument '#{key}'") if value.nil?
    value
  end

  private def optional_string(args : Hash(String, JSON::Any), key : String) : String?
    args[key]?.try(&.as_s?)
  end

  private def optional_int(args : Hash(String, JSON::Any), key : String) : Int32?
    value = args[key]?.try(&.as_i?)
    value.try(&.to_i)
  rescue OverflowError
    nil
  end

  private def optional_bool(args : Hash(String, JSON::Any), key : String) : Bool?
    args[key]?.try(&.as_bool?)
  end

  private def truncate_tool_output(text : String) : String
    return text if text.size <= MAX_TOOL_OUTPUT
    "#{text[0, MAX_TOOL_OUTPUT]}\n...[tool output truncated]"
  end

  private def truncate_text(text : String, limit : Int32) : String
    return text if text.size <= limit
    "#{text[0, limit]}..."
  end
end

private class CodingApprovalHandler < Agent::Handler
  READ_ONLY_TOOLS = %w[list_files read_file search_files]
  MUTATING_TOOLS  = %w[write_file edit_file run_command]

  def initialize(@auto_approve : Bool, @read_only : Bool)
  end

  def handle(ctx : Agent::ToolCallContext, next_proc) : Agent::Message
    name = ctx.tool_call.name
    STDERR.puts "  ● #{name}#{argument_summary(ctx)}"
    STDERR.flush

    if @read_only && !READ_ONLY_TOOLS.includes?(name)
      STDERR.puts "  ↳ refused (read-only mode)"
      return refusal(ctx, "Read-only mode is enabled; tool '#{name}' is disabled.")
    end

    approved = @auto_approve || READ_ONLY_TOOLS.includes?(name)
    unless approved
      STDERR.print "  approve? [y/N/a] "
      STDERR.flush
      answer = (gets || "").strip.downcase
      case answer
      when "y", "yes"
        approved = true
      when "a", "all"
        @auto_approve = true
        approved = true
        STDERR.puts "  (auto-approve enabled for this session)"
      end
    end

    unless approved
      STDERR.puts "  ↳ declined"
      return refusal(ctx, "User declined to execute tool '#{name}'.")
    end

    result = next_proc.call(ctx)
    STDERR.puts "  ↳ #{result_summary(result)}"
    STDERR.flush
    result
  rescue ex
    message = Agent::Message.new(
      role: Agent::Role::Tool,
      content: "Error: #{ex.message}",
      tool_call_id: ctx.tool_call.id,
      name: ctx.tool_call.name,
    )
    STDERR.puts "  ↳ error: #{ex.message}"
    message
  end

  private def refusal(ctx : Agent::ToolCallContext, message : String) : Agent::Message
    Agent::Message.new(
      role: Agent::Role::Tool,
      content: message,
      tool_call_id: ctx.tool_call.id,
      name: ctx.tool_call.name,
    )
  end

  private def argument_summary(ctx : Agent::ToolCallContext) : String
    args = begin
      JSON.parse(ctx.tool_call.arguments).as_h?
    rescue JSON::ParseException
      nil
    end
    return "" unless args

    if command = args["command"]?.try(&.as_s?)
      return " #{truncate(command, 100)}"
    end
    if path = args["path"]?.try(&.as_s?)
      return " #{path}"
    end
    if pattern = args["pattern"]?.try(&.as_s?)
      return " #{truncate(pattern, 80)}"
    end
    ""
  end

  private def result_summary(result : Agent::Message) : String
    text = result.content || ""
    line = text.lines.find { |entry| !entry.empty? } || "(no output)"
    truncate(line, 180)
  end

  private def truncate(text : String, limit : Int32) : String
    return text if text.size <= limit
    "#{text[0, limit]}..."
  end
end

private def coding_system_prompt(workspace : String) : String
  [
    "You are a terminal coding agent working inside this workspace:",
    workspace,
    "",
    "Use the provided tools to inspect and modify the repository:",
    "- list_files, read_file, and search_files are read-only.",
    "- write_file, edit_file, and run_command require user approval.",
    "- Always use paths relative to the workspace. Never attempt to access",
    "  files outside it.",
    "- Read the relevant code before editing. Keep changes focused and minimal.",
    "- Prefer edit_file over rewriting a whole file.",
    "- Run non-interactive commands only. Tests and builds are encouraged.",
    "- Never invent file contents or command output. If a tool fails, inspect",
    "  the error and adjust.",
    "- When the task is complete, summarize what changed and what you verified.",
  ].join('\n')
end

private def read_input(prompt : String) : String?
  STDOUT.print prompt
  STDOUT.flush
  input = gets
  return if input.nil?
  input.chomp
end

private def print_help : Nil
  puts "Commands:"
  puts "  /help      show this help"
  puts "  /reset     clear conversation history"
  puts "  /save      save the current session"
  puts "  /session   show the session file and history size"
  puts "  /exit      quit"
  puts
  puts "Tool approval:"
  puts "  y / yes    approve this call"
  puts "  n / enter  decline this call"
  puts "  a / all    approve this call and all future calls this session"
end

private def save_session(agent : Agent, path : String) : Nil
  Dir.mkdir_p(File.dirname(path))
  temp = "#{path}.tmp"
  File.write(temp, agent.dump)
  File.rename(temp, path)
rescue ex
  STDERR.puts "  warning: could not save session: #{ex.message}"
end

private def default_session_path(workspace : String) : String
  key = Digest::SHA256.hexdigest(workspace)[0, 12]
  home = ENV["HOME"]? || Dir.current
  File.join(home, ".agent-cr", "#{key}.json")
end

private def resolve_real_path(path : String) : String
  {% if compare_versions(Crystal::VERSION, "1.22.3") >= 0 %}
    File.realpath(path)
  {% else %}
    File.real_path(path)
  {% end %}
end

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

workspace_arg = nil
session_arg = nil
provider_arg = nil
endpoint_arg = nil
model_arg = nil
api_key_arg = nil
api_style_arg = nil
max_history_arg = nil
max_tool_iterations_arg = nil
auto_approve = false
read_only = false
show_reasoning = false

parser = OptionParser.new
parser.banner = "Usage: agent-cli [options]"
parser.on("--workspace DIR", "Workspace root (default: current directory)") { |v| workspace_arg = v }
parser.on("--session FILE", "Session file (default: ~/.agent-cr/<workspace-hash>.json)") { |v| session_arg = v }
parser.on("--provider NAME", "Preset: openai, deepseek, openrouter, groq, together, ollama, vllm, custom") { |v| provider_arg = v }
parser.on("--model NAME", "Model name (preset default if omitted)") { |v| model_arg = v }
parser.on("--api-endpoint URL", "OpenAI-compatible base URL") { |v| endpoint_arg = v }
parser.on("--api-key KEY", "API key (prefer LLM_API_KEY / provider env var)") { |v| api_key_arg = v }
parser.on("--api-style STYLE", "chat (default) or responses") { |v| api_style_arg = v }
parser.on("--max-history N", "Maximum conversation turns (default: 40)") { |v| max_history_arg = v.to_i? }
parser.on("--max-tool-iterations N", "Tool loop safety limit (default: 50)") { |v| max_tool_iterations_arg = v.to_i? }
parser.on("-y", "--auto-approve", "Skip tool approval prompts") { auto_approve = true }
parser.on("--read-only", "Disable write_file, edit_file, and run_command") { read_only = true }
parser.on("--show-reasoning", "Print reasoning deltas") { show_reasoning = true }
parser.on("--version", "Print version") { puts "agent-cli #{Agent::VERSION}"; exit 0 }
parser.on("-h", "--help", "Show this help") { puts parser; exit 0 }
parser.invalid_option do |flag|
  STDERR.puts "Unknown option: #{flag}"
  STDERR.puts parser
  exit 1
end
parser.missing_option do |flag|
  STDERR.puts "Missing value for #{flag}"
  exit 1
end
parser.parse

workspace = File.expand_path(workspace_arg || ENV["AGENT_WORKSPACE"]? || Dir.current)
unless Dir.exists?(workspace)
  STDERR.puts "Workspace does not exist: #{workspace}"
  exit 1
end
workspace = resolve_real_path(workspace)

provider = provider_arg || ENV["LLM_PROVIDER"]?
endpoint = endpoint_arg || ENV["LLM_ENDPOINT"]?
model = model_arg || ENV["LLM_MODEL"]?
api_key = api_key_arg || ENV["LLM_API_KEY"]?
provider = "openai" if provider.nil? && endpoint.nil?

api_style = case (api_style_arg || ENV["AGENT_API_STYLE"]? || "chat").downcase
            when "chat", "chat_completions", "chat-completions"
              :chat_completions
            when "responses", "response"
              :responses
            else
              STDERR.puts "Invalid --api-style: #{api_style_arg} (use chat or responses)"
              exit 1
            end

max_history = max_history_arg ||
              ENV["AGENT_MAX_HISTORY"]?.try(&.to_i?) ||
              40
max_tool_iterations = max_tool_iterations_arg ||
                      ENV["AGENT_MAX_TOOL_ITERATIONS"]?.try(&.to_i?) ||
                      50

auto_approve ||= ENV["AGENT_AUTO_APPROVE"]? == "1" || ENV["AGENT_AUTO_APPROVE"]? == "true"
read_only ||= ENV["AGENT_READ_ONLY"]? == "1" || ENV["AGENT_READ_ONLY"]? == "true"
show_reasoning ||= ENV["AGENT_SHOW_REASONING"]? == "1" || ENV["AGENT_SHOW_REASONING"]? == "true"

session_path = File.expand_path(
  session_arg || ENV["AGENT_SESSION"]? || default_session_path(workspace)
)

config = begin
  Agent::Config.new(
    provider: provider,
    api_endpoint: endpoint,
    model: model,
    api_key: api_key,
    api_style: api_style,
    system_prompt: coding_system_prompt(workspace),
    max_history: max_history,
    max_tool_iterations: max_tool_iterations,
    prompt_cache_key: provider == "openai" ? "agent-cli:#{Digest::SHA256.hexdigest(workspace)[0, 16]}" : nil,
  )
rescue ex : Agent::Error
  STDERR.puts "Configuration error: #{ex.message}"
  exit 1
end

agent = Agent.new(config)
tools = CodingTools.new(workspace)
tools.register(agent)
agent.use(CodingApprovalHandler.new(auto_approve, read_only))

if File.exists?(session_path)
  begin
    agent.load(File.read(session_path))
    STDERR.puts "resumed session: #{session_path} (#{agent.history.size} messages)"
  rescue ex
    STDERR.puts "warning: could not load session: #{ex.message}; starting fresh"
  end
end

puts "agent-cli #{Agent::VERSION}"
puts "  workspace: #{workspace}"
puts "  provider:  #{config.provider_name} / #{config.model}"
puts "  endpoint:  #{config.api_endpoint}"
puts "  session:   #{session_path}"
puts "  approval:  #{read_only ? "read-only" : auto_approve ? "auto-approve" : "ask"}"
puts "  /help for commands, /exit to quit"
puts

begin
  loop do
    input = read_input("> ")
    break if input.nil?
    input = input.strip
    next if input.empty?

    case input
    when "/exit", "/quit"
      break
    when "/help"
      print_help
    when "/reset"
      agent.reset
      save_session(agent, session_path)
      puts "  (history cleared and session saved)"
    when "/save"
      save_session(agent, session_path)
      puts "  (session saved)"
    when "/session"
      puts "  #{session_path} (#{agent.history.size} messages)"
    else
      begin
        response = agent.ask(input)
        response.stream do |chunk|
          case chunk.kind
          when Agent::Response::ChunkKind::Content
            STDOUT.print chunk.text
          when Agent::Response::ChunkKind::Reasoning
            STDOUT.print "\e[90m#{chunk.text}\e[0m" if show_reasoning
          else
            # Tool call chunks are rendered by CodingApprovalHandler.
          end
        end
        STDOUT.puts

        if error = response.error
          STDERR.puts "  error: #{error.class}: #{error.message}"
        else
          message = response.message
          tool_calls = message.tool_calls
          if tool_calls && !tool_calls.empty?
            STDERR.puts "  warning: unresolved tool call(s): " \
                        "#{tool_calls.map(&.name).join(", ")}"
          else
            save_session(agent, session_path)
          end

          meta = response.metadata
          if (prompt = meta.prompt_tokens) && (completion = meta.completion_tokens)
            puts "  ── tokens: #{prompt}↑ #{completion}↓"
          end
        end
      rescue ex
        STDERR.puts "  error: #{ex.message}"
      end
    end
  end
ensure
  agent.close
end
