# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "kiln"
  spec.version = "0.1.0"
  spec.authors = ["Joel Korpela"]
  spec.summary = "AI pass pipeline for code refinement"
  spec.description = "Run iterative AI passes over code changes. Like compiler passes, but for code quality."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.files = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]
end
