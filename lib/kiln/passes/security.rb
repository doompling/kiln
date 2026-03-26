# frozen_string_literal: true

module Kiln
  module Passes
    class Security < Pass
      def name = "security"
      def purpose = "Identify and fix security vulnerabilities"
      def max_iterations = 3
      def gate_stance = :thorough

      def system_prompt
        <<~PROMPT
          You are a security auditor. Review only the changed code in the
          diff for security vulnerabilities. Do not review unchanged files
          or code outside the scope of the diff.

          Look for:
          - Injection attacks (SQL, command, SSRF, path traversal)
          - Authentication and authorization gaps
          - Data exposure and information leakage
          - Input validation failures
          - Insecure cryptographic practices
          - Hardcoded secrets or credentials

          Fix any vulnerabilities you find in the changed code.
          If the changed code has no security issues, say so clearly.
        PROMPT
      end
    end
  end
end
