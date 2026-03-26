# frozen_string_literal: true

require "json"

module Kiln
  # Terminal output for pipeline progress. Detects TTY vs non-TTY
  # and adapts accordingly: ANSI colors and line overwrites in
  # interactive terminals, plain prefixed lines everywhere else.
  class Display
    # SPINNER_FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
    SPINNER_FRAMES = ["𓃉𓃉𓃉", "𓃉𓃉∘", "𓃉∘°", "∘°∘", "°∘𓃉", "∘𓃉𓃉"].freeze

    COLORS = {
      reset:   "\e[0m",
      bold:    "\e[1m",
      dim:     "\e[2m",
      red:     "\e[31m",
      green:   "\e[32m",
      yellow:  "\e[33m",
      blue:    "\e[34m",
      magenta: "\e[35m",
      cyan:    "\e[36m",
      white:   "\e[37m",
      custom_orange: "\e[38;2;240;106;29m", # #cf6223
    }.freeze

    def initialize(output: $stderr)
      @out = output
      @tty = output.respond_to?(:tty?) && output.tty?
      @spinner_index = 0
      @current_tool = nil
      @iteration_start = nil
      @pass_start = nil
      @heartbeat_thread = nil
      @heartbeat_label = nil
      @heartbeat_mutex = Mutex.new
      @term_width = detect_width
    end

    # --- Pipeline lifecycle ---

    def run_started(run_id, scope)
      if @tty
        puts_line "#{c(:custom_orange)}#{c(:bold)}🔥 Kiln#{c(:reset)}"
        puts_line "#{c(:dim)}Running passes on #{scope} · #{run_id}#{c(:reset)}"
      else
        puts_line "[kiln] Starting run #{run_id} (#{scope})"
      end
    end

    def killing_previous_run(run_id, pid)
      if @tty
        puts_line "  #{c(:yellow)}⚠ killed previous run#{c(:reset)} #{c(:dim)}#{run_id} (pid #{pid})#{c(:reset)}"
      else
        puts_line "[kiln] Killed previous run #{run_id} (pid #{pid})"
      end
    end

    def run_resumed(run_id, completed_count, scope)
      if @tty
        puts_line "#{c(:custom_orange)}#{c(:bold)}🔥 Kiln#{c(:reset)}"
        puts_line "#{c(:dim)}Resuming on #{scope} · #{run_id} (#{completed_count} passes done)#{c(:reset)}"
      else
        puts_line "[kiln] Resuming run #{run_id} (#{scope}, #{completed_count} passes completed)"
      end
    end

    def pass_started(pass, index, total)
      @pass_start = Time.now
      blank_line

      if @tty
        counter = "[#{index + 1}/#{total}]"
        header = "#{pass.name} #{pass.purpose}"
        rule_width = [@term_width - header.length - counter.length - 3, 4].max
        rule = "─" * rule_width

        puts_line "#{c(:blue)}#{c(:bold)}#{pass.name}#{c(:reset)} #{c(:dim)}#{pass.purpose} #{rule} #{counter}#{c(:reset)}"
      else
        puts_line "[kiln] Pass: #{pass.name} — #{pass.purpose} [#{index + 1}/#{total}]"
      end
    end

    def pass_finished(pass, iteration_count)
      elapsed = elapsed_since(@pass_start)

      if @tty
        puts_line "#{c(:green)}  ✓ done#{c(:reset)} #{c(:dim)}#{iteration_count} #{iteration_count == 1 ? 'iteration' : 'iterations'} · #{elapsed}#{c(:reset)}"
      else
        puts_line "[kiln]   Done: #{iteration_count} iterations in #{elapsed}"
      end
    end

    def iteration_started(pass, iteration)
      @iteration_start = Time.now
      @current_tool = nil

      if @tty
        puts_line "  #{c(:dim)}iteration #{iteration + 1}/#{pass.max_iterations}#{c(:reset)}"
      else
        puts_line "[kiln]   Iteration #{iteration + 1}/#{pass.max_iterations}"
      end
    end

    def iteration_finished(modified_paths, notes)
      elapsed = elapsed_since(@iteration_start)
      file_count = modified_paths.length

      if @tty
        clear_progress_line

        if file_count > 0
          files = modified_paths.map { |p| File.basename(p) }.join(", ")
          puts_line "  #{c(:green)}  #{file_count} file#{file_count == 1 ? '' : 's'} modified#{c(:reset)} #{c(:dim)}#{files} · #{elapsed}#{c(:reset)}"
        else
          puts_line "  #{c(:dim)}  #{elapsed}#{c(:reset)}"
        end

        if notes && !notes.strip.empty?
          notes.strip.each_line { |line| puts_line "  #{c(:dim)}  #{line.rstrip}#{c(:reset)}" }
        end
      else
        if file_count > 0
          puts_line "[kiln]   #{file_count} file(s) modified (#{elapsed}): #{modified_paths.join(', ')}"
        else
          puts_line "[kiln]   (#{elapsed})"
        end

        if notes && !notes.strip.empty?
          notes.strip.each_line { |line| puts_line "[kiln]   #{line.rstrip}" }
        end
      end
    end

    # --- Agent streaming events ---

    def agent_event(event)
      return unless event

      case event["type"]
      when "assistant"
        pause_heartbeat { show_assistant_text(event) }
      when "tool_call"
        pause_heartbeat { show_tool_call(event) }
      when "progress"
        pause_heartbeat { show_progress(event) }
      when "system", "rate_limit_event", "user", "result"
        nil
      end
    end

    def agent_started(label = "working")
      @heartbeat_label = label
      stop_heartbeat
      return unless @tty

      @heartbeat_start = Time.now
      @heartbeat_thread = Thread.new do
        loop do
          sleep 0.115
          @heartbeat_mutex.synchronize do
            elapsed = elapsed_since(@heartbeat_start)
            overwrite_line "    #{spinner} #{c(:dim)}#{@heartbeat_label} · #{elapsed}#{c(:reset)}"
          end
        end
      rescue IOError
        nil
      end
    end

    def agent_finished
      stop_heartbeat
      clear_progress_line if @tty
      finish_tool_line if @current_tool
      @current_tool = nil
    end

    # --- Gate ---

    def gate_verdict(verdict, elapsed_seconds = nil)
      time_str = elapsed_seconds ? format_seconds(elapsed_seconds) : nil

      if @tty
        clear_progress_line

        timing = time_str ? " · #{time_str}" : ""
        if verdict.decision == :continue
          puts_line "  #{c(:yellow)}  ↻ iterate#{c(:reset)} #{c(:dim)}#{verdict.reasoning}#{timing}#{c(:reset)}"
        else
          puts_line "  #{c(:green)}  ✓ done#{c(:reset)} #{c(:dim)}#{verdict.reasoning}#{timing}#{c(:reset)}"
        end
      else
        timing = time_str ? " (#{time_str})" : ""
        puts_line "[kiln]   Gate: #{verdict.decision} — #{verdict.reasoning}#{timing}"
      end
    end

    # --- Verification ---

    def verification_started(command)
      if @tty
        overwrite_line "    #{spinner} #{c(:dim)}verify: #{command}#{c(:reset)}"
      else
        puts_line "[kiln]   Verify: #{command}"
      end
    end

    def verification_passed(command)
      if @tty
        clear_progress_line
        puts_line "  #{c(:green)}  ✓ verify#{c(:reset)} #{c(:dim)}#{command}#{c(:reset)}"
      else
        puts_line "[kiln]   Verify: PASSED"
      end
    end

    def verification_failed(command)
      if @tty
        clear_progress_line
        puts_line "  #{c(:red)}  ✗ verify#{c(:reset)} #{c(:dim)}#{command}#{c(:reset)}"
      else
        puts_line "[kiln]   Verify: FAILED"
      end
    end

    def repair_started(attempt, max)
      if @tty
        overwrite_line "    #{spinner} #{c(:yellow)}repair attempt #{attempt}/#{max}#{c(:reset)}"
      else
        puts_line "[kiln]   Repair attempt #{attempt}/#{max}"
      end
    end

    def repair_fixed
      if @tty
        clear_progress_line
        puts_line "  #{c(:green)}  ✓ repair fixed#{c(:reset)}"
      else
        puts_line "[kiln]   Repair: FIXED"
      end
    end

    def repair_still_failing
      if @tty
        clear_progress_line
        puts_line "  #{c(:red)}  ✗ repair still failing#{c(:reset)}"
      else
        puts_line "[kiln]   Repair: still failing"
      end
    end

    # --- Pipeline completion ---

    def no_changes
      if @tty
        puts_line "#{c(:dim)}No changes found, nothing to do.#{c(:reset)}"
      else
        puts_line "[kiln] No changes found, nothing to do."
      end
    end

    def pipeline_finished(log_path)
      blank_line

      if @tty
        puts_line "#{c(:green)}#{c(:bold)}✓ complete#{c(:reset)} #{c(:dim)}#{log_path}#{c(:reset)}"
      else
        puts_line "[kiln] Pipeline complete. Log written to #{log_path}"
      end
    end

    private

    def stop_heartbeat
      if @heartbeat_thread
        @heartbeat_thread.kill
        @heartbeat_thread = nil
      end
    end

    def pause_heartbeat
      @heartbeat_mutex.synchronize { yield }
    end

    def show_progress(event)
      content = event["content"]
      return unless content && !content.empty?

      if @tty
        overwrite_line "    #{spinner} #{c(:dim)}#{truncate(content, @term_width - 10)}#{c(:reset)}"
      else
        puts_line "[kiln]     #{content}"
      end
    end

    def show_assistant_text(event)
      return unless @tty

      content = event.dig("content_block", "text") || event["content"]
      return unless content && !content.empty?

      finish_tool_line if @current_tool
      @current_tool = nil

      content.each_line do |line|
        @out.print "    #{c(:dim)}#{line}#{c(:reset)}"
      end
    end

    def show_tool_call(event)
      case event["subtype"]
      when "started"
        finish_tool_line if @current_tool

        name = event.dig("tool_call", "name") || "tool"
        description = event.dig("tool_call", "description") ||
                      event.dig("tool_call", "shellToolCall", "description")

        @current_tool = { name: name, description: description, started_at: Time.now }

        if @tty
          label = description || name
          overwrite_line "    #{spinner} #{c(:custom_orange)}#{truncate(label, @term_width - 10)}#{c(:reset)}"
        else
          label = description || name
          puts_line "[kiln]     #{label}"
        end
      when "completed"
        if @tty && @current_tool
          elapsed = elapsed_since(@current_tool[:started_at])
          label = @current_tool[:description] || @current_tool[:name]
          overwrite_line "    #{c(:green)}✓#{c(:reset)} #{c(:dim)}#{label} · #{elapsed}#{c(:reset)}\n"
        end
        @current_tool = nil
      end
    end

    def finish_tool_line
      return unless @tty && @current_tool

      elapsed = elapsed_since(@current_tool[:started_at])
      label = @current_tool[:description] || @current_tool[:name]
      overwrite_line "    #{c(:green)}✓#{c(:reset)} #{c(:dim)}#{label} · #{elapsed}#{c(:reset)}\n"
    end

    def spinner
      frame = SPINNER_FRAMES[@spinner_index % SPINNER_FRAMES.length]
      @spinner_index += 1
      "#{c(:custom_orange)}#{frame}#{c(:reset)}"
    end

    def c(name)
      @tty ? COLORS.fetch(name) : ""
    end

    def puts_line(text)
      @out.puts text
    end

    def blank_line
      @out.puts ""
    end

    def overwrite_line(text)
      @out.print "\r\e[2K#{text}"
    end

    def clear_progress_line
      @out.print "\r\e[2K"
    end

    def truncate(text, max_length)
      return text if text.length <= max_length

      text[0, max_length - 1] + "…"
    end

    def elapsed_since(start)
      return "0s" unless start

      format_seconds(Time.now - start)
    end

    def format_seconds(seconds)
      seconds = seconds.to_i
      if seconds < 60
        "#{seconds}s"
      elsif seconds < 3600
        "#{seconds / 60}m#{seconds % 60}s"
      else
        "#{seconds / 3600}h#{(seconds % 3600) / 60}m"
      end
    end

    def detect_width
      if @tty
        require "io/console"
        IO.console&.winsize&.last || 80
      else
        80
      end
    rescue LoadError
      80
    end
  end
end
