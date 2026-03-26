# frozen_string_literal: true

module Kiln
  # The assembled work to be fired. Holds the pipeline configuration,
  # the diff scope, the agent backend, and verification hooks.
  # Pass it to Kiln.fire.
  class Piece
    attr_reader :pipeline, :change_set, :llm, :verifications
    attr_accessor :new_run

    def initialize(backend: :claude, model: nil, diff_source: :staged, directory: Dir.pwd, extra_flags: [])
      @passes = []
      @verifications = []
      @change_set = ChangeSet.new(directory: directory, diff_source: diff_source)
      @llm = LLM.new(backend: backend, model: model, extra_flags: extra_flags)
    end

    def add_pass(pass)
      @passes << pass
      @pipeline = Pipeline.new(*@passes)
      self
    end

    # Register a verification command to run at a specific hook point.
    #   after: :iteration — runs after each pass iteration
    #   after: :pass      — runs after each pass completes
    #   after: :pipeline  — runs after the entire pipeline completes
    # When max_repair_attempts > 0, the pass agent is re-invoked with
    # the failure output to fix the issues before continuing.
    def verify(command, after:, max_repair_attempts: 0)
      @verifications << Verification.new(
        command: command,
        after: after,
        max_repair_attempts: max_repair_attempts
      )
      self
    end

    def verifications_for(hook)
      @verifications.select { |v| v.after == hook }
    end
  end
end
