# frozen_string_literal: true

require "json"
require "fileutils"
require "digest"
require "open3"

module Kiln
  # Executes a pipeline against a set of changes.
  # Manages the iteration loop, gate evaluation, verification hooks,
  # repair iterations, state persistence, and produces a narrative log.
  class Firing
    GATE_STANCES = {
      aggressive: "Stop early. Only continue if there are clear, significant issues remaining. " \
                  "Minor or cosmetic improvements are not worth another iteration.",
      balanced: "Continue if there are meaningful improvements still available. " \
                "Stop when findings become minor, cosmetic, or repetitive.",
      thorough: "Continue as long as any substantive finding remains. " \
                "This domain has high cost-of-failure, so be thorough.",
    }.freeze

    def initialize(pipeline:, change_set:, llm:, verifications: [], new_run: false, display: Display.new)
      @pipeline = pipeline
      @change_set = change_set
      @llm = llm
      @verifications = verifications
      @new_run = new_run
      @display = display
      @kiln_dir = File.join(change_set.directory, ".kiln")
      @log_entries = []
    end

    def fire
      @state, @run_dir = resolve_run
      install_signal_handlers

      if @change_set.empty?
        @display.no_changes
        save_state(@state.merge(status: "completed"))
        return
      end

      total_passes = @pipeline.passes.length

      @pipeline.passes.each_with_index do |pass, index|
        next if @state[:completed_passes].include?(index)

        @display.pass_started(pass, index, total_passes)

        save_state(@state.merge(current_pass_index: index, status: "in_progress"))
        clear_pass_artifacts(index, pass)

        iteration_count = run_pass(pass, index)
        run_verifications(:pass, pass, index)

        @display.pass_finished(pass, iteration_count)

        @state[:completed_passes] << index
        save_state(@state.merge(status: "in_progress"))
      end

      run_verifications(:pipeline, nil, nil)

      save_state(@state.merge(status: "completed", current_pass_index: nil))
      write_log

      log_relative = @run_dir.sub("#{@change_set.directory}/", "")
      @display.pipeline_finished("#{log_relative}/log.md")
    end

    private

    def run_pass(pass, pass_index)
      iteration = 0
      pass_log = { name: pass.name, purpose: pass.purpose, iterations: [] }

      loop do
        @display.iteration_started(pass, iteration)

        @display.agent_started(pass.name)
        result = pass.execute(change_set: @change_set, llm: @llm) do |event|
          @display.agent_event(event)
        end
        @display.agent_finished

        modified_paths = detect_modified_files
        diffs = compute_diffs(modified_paths)

        @display.iteration_finished(modified_paths, result.notes)

        iteration_log = {
          iteration: iteration,
          notes: result.notes,
          modified_files: modified_paths,
          diffs: diffs,
          verification_results: [],
        }

        save_notes(pass_index, pass, iteration, result.notes)
        save_diffs(pass_index, pass, iteration, diffs)

        verification_results = run_verifications(:iteration, pass, pass_index)
        iteration_log[:verification_results] = verification_results

        break_after_log = iteration >= pass.max_iterations - 1

        unless break_after_log
          gate_start = Time.now
          @display.agent_started("evaluating gate")
          verdict = evaluate_gate(pass, iteration, result.notes, modified_paths, diffs, verification_results)
          @display.agent_finished
          gate_elapsed = Time.now - gate_start
          save_verdict(pass_index, pass, iteration, verdict)

          @display.gate_verdict(verdict, gate_elapsed)

          iteration_log[:verdict] = verdict
        end

        pass_log[:iterations] << iteration_log

        break if break_after_log
        break if verdict.decision == :stop

        iteration += 1
      end

      @log_entries << pass_log
      pass_log[:iterations].length
    end

    # --- Verification & Repair ---

    def run_verifications(hook, pass, pass_index)
      results = []
      verifications = @verifications.select { |v| v.after == hook }
      return results if verifications.empty?

      verifications.each do |verification|
        result = run_single_verification(verification, pass, pass_index)
        results << result
      end

      results
    end

    def run_single_verification(verification, pass, pass_index)
      @display.verification_started(verification.command)

      output, status = run_command(verification.command)
      result = { command: verification.command, passed: status.success?, output: output, repairs: [] }

      if status.success?
        @display.verification_passed(verification.command)
        return result
      end

      @display.verification_failed(verification.command)

      if verification.max_repair_attempts > 0 && pass
        verification.max_repair_attempts.times do |attempt|
          @display.repair_started(attempt + 1, verification.max_repair_attempts)

          repair_notes = run_repair(pass, verification.command, output)
          output, status = run_command(verification.command)

          repair_entry = { attempt: attempt + 1, notes: repair_notes, passed: status.success?, output: output }
          result[:repairs] << repair_entry

          if status.success?
            @display.repair_fixed
            result[:passed] = true
            break
          else
            @display.repair_still_failing
          end
        end
      end

      result
    end

    def run_repair(pass, command, failure_output)
      repair_prompt = <<~PROMPT
        Run `#{@change_set.diff_command}` to see the recent changes.

        The following verification failed:
        `#{command}`

        Output:
        #{failure_output}

        Fix the code to make this verification pass. Stay true to your
        mandate but prioritize resolving the failures.

        When finished, report what you fixed and why.
      PROMPT

      @display.agent_started("repairing")
      result = @llm.run(
        system: pass.system_prompt,
        prompt: repair_prompt,
        directory: @change_set.directory,
        tools: pass.tools
      ) { |event| @display.agent_event(event) }
      @display.agent_finished
      result
    end

    def run_command(command)
      stdout, stderr, status = Open3.capture3(command, chdir: @change_set.directory)
      combined = stdout + stderr
      [combined, status]
    end

    # --- Change detection via git ---

    def detect_modified_files
      raw = `git -C #{@change_set.directory} diff --name-only 2>/dev/null`.strip
      return [] if raw.empty?

      raw.lines.map(&:strip).reject(&:empty?)
    end

    def compute_diffs(modified_paths)
      modified_paths.each_with_object({}) do |path, diffs|
        diffs[path] = `git -C #{@change_set.directory} diff -- #{path} 2>/dev/null`.strip
      end
    end

    def format_diffs(diffs)
      return "(no file changes)" if diffs.empty?

      diffs.map { |path, d| "### #{path}\n```\n#{d}\n```" }.join("\n\n")
    end

    # --- Gate evaluation ---

    def evaluate_gate(pass, iteration, notes, modified_paths, diffs, verification_results)
      diff_text = format_diffs(diffs)
      verification_text = format_verification_results(verification_results)

      prompt = <<~PROMPT
        You are evaluating whether an AI code pass should continue iterating.

        Pass: #{pass.name} (#{pass.purpose})
        Iteration: #{iteration + 1} of #{pass.max_iterations} max

        If no files were changed but the agent explains the code needs no modifications,
        that is a valid outcome. Only iterate if the agent missed something obvious.

        ## Agent's report (what it claims it did and why)
        #{notes}

        ## Files actually modified this iteration
        #{modified_paths.empty? ? "(none)" : modified_paths.join(", ")}

        ## Actual diffs for modified files
        #{diff_text}

        #{verification_text}

        Decide: should this pass run another iteration, or has it done enough?

        Respond with ONLY a JSON object:
        {"decision": "continue" or "stop", "reasoning": "one sentence explanation"}
      PROMPT

      raw = @llm.run(
        system: "You evaluate AI code passes. #{GATE_STANCES.fetch(pass.gate_stance)} " \
                "Respond with only the requested JSON.",
        prompt: prompt,
        directory: @change_set.directory,
        tools: [],
        stream: false
      )

      parse_verdict(raw)
    end

    def format_verification_results(results)
      return "" if results.empty?

      lines = ["## Verification results"]
      results.each do |r|
        status = r[:passed] ? "PASSED" : "FAILED"
        lines << "`#{r[:command]}`: #{status}"

        if r[:repairs].any?
          lines << "Repair attempts: #{r[:repairs].length}"
          r[:repairs].each do |repair|
            lines << "  Attempt #{repair[:attempt]}: #{repair[:passed] ? 'fixed' : 'still failing'}"
          end
        end
      end

      lines.join("\n")
    end

    def parse_verdict(raw)
      json = raw[/\{.*\}/m]
      parsed = JSON.parse(json)
      PassVerdict.new(
        decision: parsed["decision"].to_sym,
        reasoning: parsed["reasoning"]
      )
    rescue JSON::ParserError, NoMethodError
      PassVerdict.new(decision: :stop, reasoning: "Failed to parse gate response, stopping.")
    end

    # --- Pipeline log ---

    def write_log
      log_path = File.join(@run_dir, "log.md")
      File.write(log_path, build_log_content)
    end

    def build_log_content
      lines = ["# Kiln Run — #{Time.now.strftime('%Y-%m-%d %H:%M')}\n"]

      @log_entries.each do |pass_log|
        iteration_count = pass_log[:iterations].length
        lines << "## Pass: #{pass_log[:name]} (#{iteration_count} #{iteration_count == 1 ? 'iteration' : 'iterations'})\n"
        lines << "#{pass_log[:purpose]}\n"

        pass_log[:iterations].each do |iter|
          lines << "### Iteration #{iter[:iteration] + 1}\n"

          if iter[:modified_files].empty?
            lines << "**Files changed:** (none)\n"
          else
            lines << "**Files changed:** #{iter[:modified_files].join(', ')}\n"
          end

          lines << "**Agent notes:**\n#{iter[:notes]}\n" if iter[:notes] && !iter[:notes].empty?

          iter[:verification_results].each do |vr|
            status = vr[:passed] ? "PASSED" : "FAILED"
            lines << "**Verification:** `#{vr[:command]}` — #{status}\n"

            vr[:repairs].each do |repair|
              result_text = repair[:passed] ? "FIXED" : "still failing"
              lines << "**Repair attempt #{repair[:attempt]}:** #{result_text}\n"
              lines << "#{repair[:notes]}\n" if repair[:notes] && !repair[:notes].empty?
            end
          end

          if iter[:verdict]
            lines << "**Gate:** #{iter[:verdict].decision} — #{iter[:verdict].reasoning}\n"
          end
        end
      end

      lines.join("\n")
    end

    # --- Run management ---

    def runs_dir
      File.join(@kiln_dir, "runs")
    end

    def resolve_run
      fingerprint = pipeline_fingerprint
      claim_active_runs
      latest = @new_run ? nil : find_resumable_run(fingerprint)

      if latest
        state = JSON.parse(File.read(File.join(latest, "state.json")), symbolize_names: true)
        state[:pid] = Process.pid
        @display.run_resumed(File.basename(latest), state[:completed_passes].length, @change_set.scope_label)
        [state, latest]
      else
        run_id = Time.now.strftime("%Y%m%d_%H%M%S")
        run_dir = File.join(runs_dir, run_id)
        FileUtils.mkdir_p(run_dir)
        @display.run_started(run_id, @change_set.scope_label)
        state = {
          completed_passes: [],
          current_pass_index: nil,
          status: "starting",
          pid: Process.pid,
          pipeline_fingerprint: fingerprint,
        }
        [state, run_dir]
      end
    end

    # Kill any active Kiln processes from previous runs so we
    # can safely take over. Marks their runs as abandoned.
    def claim_active_runs
      return unless Dir.exist?(runs_dir)

      Dir.glob(File.join(runs_dir, "*")).each do |dir|
        state_path = File.join(dir, "state.json")
        next unless File.exist?(state_path)

        state = JSON.parse(File.read(state_path), symbolize_names: true)
        next if state[:status] == "completed"
        next if state[:status] == "abandoned"

        old_pid = state[:pid]
        if old_pid && old_pid != Process.pid && process_alive?(old_pid)
          @display.killing_previous_run(File.basename(dir), old_pid)
          Process.kill("TERM", old_pid)
          sleep 0.1
          Process.kill("KILL", old_pid) if process_alive?(old_pid)
        end

        state[:status] = "abandoned"
        File.write(state_path, JSON.pretty_generate(state))
      end
    end

    def find_resumable_run(fingerprint)
      return nil unless Dir.exist?(runs_dir)

      Dir.glob(File.join(runs_dir, "*")).sort.reverse_each do |dir|
        state_path = File.join(dir, "state.json")
        next unless File.exist?(state_path)

        state = JSON.parse(File.read(state_path), symbolize_names: true)
        next unless state[:status] == "interrupted"
        next if state[:pipeline_fingerprint] != fingerprint

        return dir
      end

      nil
    end

    def pipeline_fingerprint
      data = @pipeline.passes.map do |p|
        {
          name: p.name,
          system_prompt: p.system_prompt,
          max_iterations: p.max_iterations,
          gate_stance: p.gate_stance,
        }
      end
      Digest::SHA256.hexdigest(JSON.generate(data))
    end

    def install_signal_handlers
      %w[INT TERM].each do |signal|
        Signal.trap(signal) do
          mark_interrupted
          exit 1
        end
      end
    end

    def mark_interrupted
      return unless @run_dir && File.exist?(state_file)

      raw = File.read(state_file)
      state = JSON.parse(raw, symbolize_names: true)
      state[:status] = "interrupted"
      state[:pid] = nil
      File.write(state_file, JSON.pretty_generate(state))
    rescue StandardError
      nil
    end

    def process_alive?(pid)
      return false unless pid

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    # --- State persistence ---

    def state_file
      File.join(@run_dir, "state.json")
    end

    def save_state(state)
      FileUtils.mkdir_p(@run_dir)
      File.write(state_file, JSON.pretty_generate(state))
    end

    def pass_dir(pass_index, pass)
      File.join(@run_dir, "passes", format("%02d_%s", pass_index, pass.name))
    end

    def clear_pass_artifacts(pass_index, pass)
      dir = pass_dir(pass_index, pass)
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(dir)
    end

    def save_notes(pass_index, pass, iteration, notes)
      dir = pass_dir(pass_index, pass)
      File.write(File.join(dir, "iteration_#{iteration}_notes.md"), notes || "")
    end

    def save_diffs(pass_index, pass, iteration, diffs)
      return if diffs.empty?

      dir = pass_dir(pass_index, pass)
      File.write(File.join(dir, "iteration_#{iteration}_diff.md"), format_diffs(diffs))
    end

    def save_verdict(pass_index, pass, iteration, verdict)
      dir = pass_dir(pass_index, pass)
      content = "# #{verdict.decision}\n\n#{verdict.reasoning}"
      File.write(File.join(dir, "iteration_#{iteration}_verdict.md"), content)
    end
  end
end
