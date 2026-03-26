# Kiln

Iterative AI passes over your code changes.

```
         ┌─ Piece ─────────────────────────────────────────────┐
         │  backend: :claude                                   │
         │  diff_source: :staged                               │
         │                                                     │
         │  ┌─ Pass: simplify ─────────────────────────────┐   │
         │  │                                              │   │
         │  │  Iteration 1 ──▶ Agent edits code            │   │
         │  │       │                                      │   │
         │  │       ▼                                      │   │
         │  │  ┌─ Verify ──▶ PASS ─────────────────────┐   │   │
         │  │  └─ Verify ──▶ FAIL ──▶ Repair (≤N) ─────┘   │   │
         │  │       │                                      │   │
         │  │       ▼                                      │   │
         │  │     Gate ──▶ "meaningful changes" ──▶ again  │   │
         │  │       │                                      │   │
         │  │  Iteration 2 ──▶ Agent takes fresh look      │   │
         │  │       │                                      │   │
         │  │       ▼                                      │   │
         │  │     Gate ──▶ "diminishing returns" ──▶ stop  │   │
         │  │                                              │   │
         │  └──────────────────────────────────────────────┘   │
         │                       │                             │
         │                  ┌─ Verify (:pass) ─┐               │
         │                  └──────────────────┘               │
         │                       │                             │
         │                       ▼                             │
         │  ┌─ Pass: security ─────────────────────────────┐   │
         │  │                                              │   │
         │  │  Iteration 1 ──▶ Agent reviews changed code  │   │
         │  │       │                                      │   │
         │  │       ▼                                      │   │
         │  │     Gate ──▶ "covered thoroughly" ──▶ stop   │   │
         │  │                                              │   │
         │  └──────────────────────────────────────────────┘   │
         │                                                     │
         │                  ┌─ Verify (:pipeline) ─┐           │
         │                  └──────────────────────┘           │
         └─────────────────────────────────────────────────────┘
                              │
                     Kiln.fire(piece)
                              │
                              ▼
              .kiln/runs/<run>/ (notes, verdicts, log)
```

Each pass is an autonomous agent with a single mandate. It sees the code as it stands now, with no awareness of what prior passes or iterations changed. A gate compares the agent's claimed changes against the actual diff and decides whether another iteration would be productive.

## Requirements

- Ruby >= 3.3
- Git
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) or [Cursor Agent CLI](https://docs.cursor.com/agent)

No gem dependencies.

## Quick Start

```ruby
require "kiln"

piece = Kiln::Piece.new(
  backend: :claude,
  model: "sonnet",
  diff_source: :last_commit
)

piece.add_pass(Kiln::Passes::Simplify.new)
piece.add_pass(Kiln::Passes::Security.new)
piece.verify("bundle exec rspec", after: :pass, max_repair_attempts: 2)

Kiln.fire(piece)
```

Save as a Ruby file and run it from your project directory.

## How It Works

`Kiln.fire` checks the diff scope for changes. If there's nothing to review, it exits. Otherwise it runs each pass in order.

### Each pass iteration

1. An agent is launched with the pass's system prompt and told to run `git diff` to see the changes. The agent has full file access for context but is instructed to focus on the changed code.
2. The agent makes changes, then reports what it did and why per file.
3. Kiln asks git what files changed and computes diffs.
4. If `:iteration` verification commands are configured, Kiln runs them. On failure with repair enabled, the agent is re-invoked with the failure output to fix the issues.
5. A gate receives the agent's report and the actual diffs. It compares them and decides whether to iterate again or move on.
6. The next iteration starts fresh: same prompt, current code state, no memory of prior iterations.

### Fresh eyes

Every iteration is stateless. The agent never receives notes from prior iterations or other passes. It sees the code as it stands now. This prevents fixation on prior approaches and lets each iteration catch things the last one introduced.

### Pipeline flow

Passes run in order and can iterate multiple times, controlled by `max_iterations` and the gate. After a pass completes, `:pass` verification hooks run. After all passes finish, `:pipeline` hooks run. State and a log are saved to `.kiln/runs/` per run.

## Concepts

### Pass

A focused agent with a single mandate. Subclass `Kiln::Pass` and override `system_prompt`.

```ruby
class EnforceTeamPatterns < Kiln::Pass
  def name = "team-patterns"
  def purpose = "Enforce our team's architectural patterns"
  def gate_stance = :aggressive

  def system_prompt
    <<~PROMPT
      We use the repository pattern for all database access.
      We use service objects for business logic, never in controllers.
      We use form objects for input validation.
      Review the changed code and refactor anything that violates these patterns.
    PROMPT
  end
end
```

#### Pass options

| Method | Default | Description |
|---|---|---|
| `name` | required | Identifier for this pass |
| `purpose` | required | One-line description shown in output |
| `max_iterations` | `3` | Hard cap on iterations |
| `gate_stance` | `:balanced` | `:aggressive`, `:balanced`, or `:thorough` |
| `tools` | `nil` (all) | Array of CLI tools the agent can use |
| `system_prompt` | required | The agent's mandate |

### Research

A read-only analysis component within a pass. Multiple researches run in parallel and their results are aggregated before changes are applied.

```ruby
class InjectionResearch < Kiln::Research
  def name = "injection"
  def focus = "Look for SQL injection, command injection, SSRF, and path traversal."

  def system_prompt
    <<~PROMPT
      You are a security researcher specializing in injection attacks.
      Analyze the code for injection vulnerabilities.
      Report findings with file, line, severity, and recommended fix.
    PROMPT
  end
end
```

Use researches inside a pass by overriding `execute`:

```ruby
class DeepSecurity < Kiln::Pass
  def name = "deep-security"
  def purpose = "Multi-angle security analysis"

  def execute(change_set:, llm:)
    findings = researches.map { |r|
      Thread.new { r.call(change_set: change_set, llm: llm) }
    }.map(&:value)

    analysis = aggregate(findings, llm)
    Kiln::PassResult.new(notes: analysis)
  end

  private

  def researches
    [InjectionResearch.new, AuthResearch.new, DataExposureResearch.new]
  end

  def aggregate(findings, llm)
    combined = findings.map { |f| "## #{f.research_name}\n#{f.content}" }.join("\n\n")
    llm.run(
      system: "Synthesize these findings. Deduplicate, prioritize by severity.",
      prompt: combined,
      directory: ".",
      tools: [],
      stream: false
    )
  end
end
```

### Piece

Assembles the backend, diff scope, passes, and verification hooks.

```ruby
piece = Kiln::Piece.new(
  backend: :claude,           # :claude or :agent (Cursor Agent CLI)
  model: "sonnet",            # model name passed to the CLI
  diff_source: :staged,       # :staged, :unstaged, :uncommitted, :last_commit, :branch, or a git range like "main..HEAD"
  directory: "/path/to/repo"  # defaults to current directory
)

piece.add_pass(Kiln::Passes::Simplify.new)
piece.add_pass(EnforceTeamPatterns.new)
piece.add_pass(Kiln::Passes::Security.new)

piece.verify("bundle exec rspec", after: :iteration, max_repair_attempts: 2)
piece.verify("bundle exec rubocop", after: :pass)
piece.verify("bundle exec rspec", after: :pipeline)

Kiln.fire(piece)
```

`add_pass` and `verify` return self, so calls can be chained.

The Claude CLI supports tool restriction via `--tools`, so `Pass#tools` and `Research::READ_ONLY_TOOLS` are enforced. The Cursor Agent CLI does not support this; tool restrictions are best-effort via prompt instructions.

### Verification

Verification commands are run by Kiln at configurable hook points.

```ruby
piece.verify("make test", after: :iteration, max_repair_attempts: 3)
piece.verify("cargo clippy", after: :pass)
piece.verify("./scripts/integration.sh", after: :pipeline)
```

#### Hook points

| Hook | When it runs |
|---|---|
| `:iteration` | After each pass iteration, before the gate evaluates |
| `:pass` | After a pass completes all iterations |
| `:pipeline` | After the entire pipeline finishes |

#### Repair loop

When a verification fails and `max_repair_attempts` is set, Kiln re-invokes the pass agent with the failure output. The agent keeps its system prompt and is directed to fix the failures. This repeats until the verification passes or attempts are exhausted.

The gate receives verification outcomes alongside notes and diffs, so persistent failures factor into its decision.

### Gate

The gate evaluates each iteration. It receives the agent's notes and the actual file diffs, and compares claimed changes against real ones. If the agent says the code is clean and made no changes, that's a valid outcome. If the agent claims improvements but the diff doesn't reflect them, the gate catches it.

Three stances control how aggressively iterations are cut off:

- **`:aggressive`** stops early, only continuing for significant remaining issues.
- **`:balanced`** continues for meaningful improvements, stops when findings become minor.
- **`:thorough`** continues as long as any substantive finding remains.

## State and Resumption

Each run gets a timestamped directory under `.kiln/runs/`:

```
.kiln/
└── runs/
    ├── 20260326_141500/
    │   ├── state.json
    │   ├── log.md                        ← narrative of this run
    │   └── passes/
    │       ├── 00_simplify/
    │       │   ├── iteration_0_notes.md
    │       │   ├── iteration_0_diff.md
    │       │   └── iteration_0_verdict.md
    │       └── 01_security/
    │           ├── iteration_0_notes.md
    │           └── iteration_0_verdict.md
    └── 20260326_143200/
        └── ...
```

`log.md` records what each pass changed, why, what the gate decided, and verification outcomes.

If a run is interrupted, the next invocation resumes it automatically (matched by pipeline fingerprint). If the pipeline configuration changed, a new run starts. Pass `--new` or set `piece.new_run = true` to force a fresh run regardless.

## Built-in Passes

- `Kiln::Passes::Simplify` reduces complexity via guard clauses, helper extraction, and standard library usage.
- `Kiln::Passes::Security` reviews changed code for injection, auth gaps, data exposure, and other vulnerabilities.
