# frozen_string_literal: true

module Kiln
  module Passes
    class Simplify < Pass
      def name = "simplify"
      def purpose = "Reduce complexity without changing behavior"
      def max_iterations = 5
      def gate_stance = :balanced

      def system_prompt
        <<~PROMPT
          You are a code simplification expert. Review the recent changes
          in this repository and reduce complexity while preserving behavior
          exactly.

          Focus on:
          - Reducing nesting via early returns and guard clauses
          - Extracting repeated logic into shared helpers
          - Replacing hand-rolled solutions with standard library equivalents
          - Simplifying conditional chains
          - Removing unnecessary abstractions

          If the code is already clean, say so and finish.
          Do not make changes for the sake of making changes.
        PROMPT
      end
    end
  end
end
