# frozen_string_literal: true

module Kiln
  # A focused, read-only analysis component.
  # Used within a pass to examine code from a specific angle
  # (e.g., injection attacks, auth patterns, data exposure).
  #
  # Research never modifies code. Multiple researches can run
  # in parallel within a single pass, and their results are
  # aggregated before an implementor applies changes.
  class Research
    READ_ONLY_TOOLS = %w[Read Glob Grep Bash(git:*)].freeze

    def name
      raise NotImplementedError
    end

    def focus
      raise NotImplementedError
    end

    def system_prompt
      raise NotImplementedError
    end

    def call(change_set:, llm:)
      content = llm.run(
        system: system_prompt,
        prompt: "Run `#{change_set.diff_command}` to see the changes. #{focus}",
        directory: change_set.directory,
        tools: READ_ONLY_TOOLS
      )

      ResearchResult.new(research_name: name, content: content)
    end
  end
end
