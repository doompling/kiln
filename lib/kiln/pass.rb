# frozen_string_literal: true

module Kiln
  # Base class for all passes. Subclass and override system_prompt
  # to define what the pass does.
  #
  # A pass receives the current state of changed files and applies
  # a specific lens: simplification, security, naming, etc.
  # Each invocation is stateless. The pass never sees what prior
  # passes or iterations changed. It always takes a fresh look.
  class Pass
    def name
      raise NotImplementedError
    end

    def purpose
      raise NotImplementedError
    end

    def max_iterations
      3
    end

    # How aggressively the gate should cut off iterations.
    # :aggressive — stop early, only continue for major findings
    # :balanced   — continue for meaningful improvements
    # :thorough   — continue as long as anything substantive remains
    def gate_stance
      :balanced
    end

    # Tools available to this pass. Nil means all tools.
    # Maps to Claude CLI's --tools flag. Ignored by backends
    # that don't support tool restriction.
    def tools
      nil
    end

    def system_prompt
      raise NotImplementedError
    end

    def execute(change_set:, llm:, &on_event)
      notes = llm.run(
        system: system_prompt,
        prompt: build_prompt(change_set),
        directory: change_set.directory,
        tools: tools,
        &on_event
      )

      PassResult.new(notes: notes)
    end

    private

    def build_prompt(change_set)
      <<~PROMPT
        Run `#{change_set.diff_command}` to see the changes under review.

        Every change you make should be motivated by what's in the diff. You can
        touch other code when the diff requires it (extracting a function, adjusting
        callers), but do not fix unrelated issues you happen to notice elsewhere
        in the file.

        When finished, report what you did. For each file you modified or reviewed,
        explain what you changed (or found) and the reasoning behind it.

        If the changes look good as-is, say so and explain why.
      PROMPT
    end
  end
end
