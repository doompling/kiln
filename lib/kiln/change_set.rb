# frozen_string_literal: true

module Kiln
  # The diff and changed files under review.
  # Scopes the pipeline to exactly the code that changed.
  #
  # diff_source options:
  #   :staged     — staged changes (git diff --cached)
  #   :unstaged   — unstaged working tree changes (git diff)
  #   :uncommitted — all uncommitted changes, staged + unstaged (git diff HEAD)
  #   :last_commit — the most recent commit only (git diff HEAD~1 HEAD)
  #   :branch      — everything on this branch vs main, including uncommitted (git diff main)
  #   "main..HEAD" — any valid git range as a string
  class ChangeSet
    attr_reader :directory

    def initialize(directory: Dir.pwd, diff_source: :staged)
      @directory = File.expand_path(directory)
      @diff_source = diff_source
    end

    def diff_command
      "git diff #{diff_ref}"
    end

    def changed_file_paths
      @changed_file_paths ||= begin
        raw = `git -C #{@directory} diff #{diff_ref} --name-only`.strip
        raw.empty? ? [] : raw.lines.map(&:strip).reject(&:empty?)
      end
    end

    def empty?
      changed_file_paths.empty?
    end

    def changed_files
      changed_file_paths.each_with_object({}) do |path, hash|
        full = File.join(@directory, path)
        hash[path] = File.read(full) if File.exist?(full)
      end
    end

    def scope_label
      case @diff_source
      when :staged      then "staged changes"
      when :unstaged    then "unstaged changes"
      when :uncommitted then "all uncommitted changes"
      when :last_commit then "last commit"
      when :branch      then "branch vs #{default_branch}"
      when String       then @diff_source
      end
    end

    private

    def default_branch
      @default_branch ||= `git -C #{@directory} symbolic-ref refs/remotes/origin/HEAD 2>/dev/null`.strip.split("/").last || "main"
    end

    def diff_ref
      case @diff_source
      when :staged      then "--cached"
      when :unstaged    then ""
      when :uncommitted then "HEAD"
      when :last_commit then "HEAD~1 HEAD"
      when :branch      then default_branch
      when String       then @diff_source
      end
    end
  end
end
