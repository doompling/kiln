# frozen_string_literal: true

require "open3"
require "json"
require "pty"
require "tempfile"

module Kiln
  # Launches CLI agents and captures their responses.
  # Supports Claude Code CLI and Cursor Agent CLI as backends.
  #
  # Streaming uses PTY to avoid pipe buffering — the CLI sees a
  # terminal and flushes output immediately, giving true real-time
  # event streaming. stdout/stderr merge into one stream; lines that
  # parse as JSON are structured events, everything else is progress.
  #
  # Claude CLI supports granular tool restriction via --tools.
  # Agent CLI does not, so tool restrictions are best-effort via prompt instructions.
  class LLM
    BACKENDS = {
      claude: {
        command: "claude",
        system_prompt_flag: "--system-prompt",
        auto_approve_flag: "--dangerously-skip-permissions",
        stream_flags: ["--output-format", "stream-json", "--verbose"],
        tool_restriction: :supported,
      },
      agent: {
        command: "agent",
        system_prompt_flag: nil,
        auto_approve_flag: "--force",
        stream_flags: ["--output-format", "stream-json"],
        tool_restriction: :unsupported,
        extra_flags: ["--trust"],
      },
    }.freeze

    def initialize(backend: :claude, model: nil, extra_flags: [])
      @config = BACKENDS.fetch(backend) { raise ArgumentError, "Unknown backend: #{backend}" }
      @model = model
      @extra_flags = extra_flags
    end

    # Runs the agent with the given prompt. When streaming, yields each
    # parsed event to the block so the caller can pipe it to Display.
    def run(system:, prompt:, directory:, tools: nil, stream: true, &on_event)
      full_prompt = build_full_prompt(system, prompt)
      cmd = build_command(system: system, tools: tools, stream: stream)

      if stream
        run_streaming(cmd, full_prompt, directory, &on_event)
      else
        run_simple(cmd, full_prompt, directory)
      end
    end

    private

    def build_command(system:, tools:, stream:)
      cmd = [@config[:command], "-p"]
      cmd += ["--model", @model] if @model
      cmd += [@config[:auto_approve_flag]]
      cmd += @config.fetch(:extra_flags, [])
      cmd += @config[:stream_flags] if stream
      cmd += tool_flags(tools)
      cmd += system_prompt_flags(system)
      cmd += @extra_flags
      cmd.compact
    end

    # Claude CLI has --system-prompt. Agent CLI doesn't, so
    # system instructions get prepended into the user prompt.
    def system_prompt_flags(system)
      return [] unless system
      return [] unless @config[:system_prompt_flag]

      [@config[:system_prompt_flag], system]
    end

    def build_full_prompt(system, prompt)
      if system && @config[:system_prompt_flag].nil?
        "## System Instructions\n#{system}\n\n## Task\n#{prompt}"
      else
        prompt
      end
    end

    def tool_flags(tools)
      return [] unless tools

      if @config[:tool_restriction] == :supported
        ["--tools", tools.join(",")]
      else
        []
      end
    end

    def run_streaming(cmd, prompt, directory, &on_event)
      final_result = nil

      prompt_file = Tempfile.new("kiln-prompt")
      prompt_file.write(prompt)
      prompt_file.close

      shell_cmd = build_shell_command(cmd, prompt_file.path, directory)

      PTY.spawn(shell_cmd) do |reader, writer, pid|
        writer.close

        reader.each_line do |raw_line|
          line = raw_line.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").rstrip
          next if line.empty?

          event = parse_event(line)
          if event
            on_event&.call(event)
            final_result = event["result"] if event["type"] == "result"
          else
            on_event&.call({ "type" => "progress", "content" => line })
          end
        end

        Process.wait(pid)
        status = $?
        raise "Agent failed (exit #{status.exitstatus})" unless status.success?
      end

      final_result
    ensure
      prompt_file&.unlink
    end

    def build_shell_command(cmd, prompt_path, directory)
      escaped_args = cmd.map { |arg| "'#{arg.gsub("'", "'\\''")}'" }.join(" ")
      "cd '#{directory.gsub("'", "'\\''")}' && #{escaped_args} < '#{prompt_path}'"
    end

    def run_simple(cmd, prompt, directory)
      stdout, stderr, status = Open3.capture3(*cmd, stdin_data: prompt, chdir: directory)
      raise "Agent failed: #{stderr}" unless status.success?

      stdout.strip
    end

    def parse_event(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
  end
end
