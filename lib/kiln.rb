# frozen_string_literal: true

require_relative "kiln/change_set"
require_relative "kiln/display"
require_relative "kiln/llm"
require_relative "kiln/pass"
require_relative "kiln/pipeline"
require_relative "kiln/research"
require_relative "kiln/firing"
require_relative "kiln/piece"
require_relative "kiln/passes/simplify"
require_relative "kiln/passes/security"

module Kiln
  PassResult     = Struct.new(:notes, keyword_init: true)
  ResearchResult = Struct.new(:research_name, :content, keyword_init: true)
  PassVerdict    = Struct.new(:decision, :reasoning, keyword_init: true)
  Verification   = Struct.new(:command, :after, :max_repair_attempts, keyword_init: true)

  def self.fire(piece)
    Firing.new(
      pipeline: piece.pipeline,
      change_set: piece.change_set,
      llm: piece.llm,
      verifications: piece.verifications,
      new_run: piece.new_run
    ).fire
  end
end
