# frozen_string_literal: true

module Kiln
  # Ordered sequence of passes to execute.
  class Pipeline
    attr_reader :passes

    def initialize(*passes)
      @passes = passes.flatten
    end

    def prepend(pass)
      self.class.new(pass, *@passes)
    end

    def append(pass)
      self.class.new(*@passes, pass)
    end

    def without(pass_name)
      self.class.new(*@passes.reject { |p| p.name == pass_name })
    end
  end
end
