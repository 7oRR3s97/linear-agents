# Contributing to linear-agents

Thanks for taking a look. linear-agents is an early-stage fork of
[Symphony](https://github.com/openai/symphony)'s reference Elixir
implementation, extended for multi-repo routing and dependency-aware
PR stacking, and for using Claude Code as the agent runtime. It works
end-to-end today but the surface area is still moving fast — expect
churn.

## What's stable, what's not

| Area | Status |
| --- | --- |
| Single-repo dispatch (legacy upstream Symphony path) | Stable. Inherited from upstream tests. |
| Multi-repo routing config + `Symphony.Repos` registry | Stable, covered by tests. |
| `BaseResolver`, `DispatchGuard`, `PR.Router`, `IntegrationBuilder`, `Reconciler` | Stable as modules; **wiring into the orchestrator's tick loop is still partial** — the dispatch snapshot's `blockers_by_id` is not yet populated end-to-end. See the open-issue list. |
| Worktree-based workspace (`Repos.Worktree`) | Stable as a module; **not yet the default workspace path**. Legacy `mkdir + after_create clone` still runs. |
| Claude Code runtime (`Agent.ClaudeCode`) | Working in production locally. Uses `claude --print` (synchronous, blocks until the agent's final response). Streaming is a follow-up. |
| Cascade rewinds (`Deps.Cascade`) | Module-level tests pass; full Linear MCP-driven cascade flow not yet integration-tested live. |
| Langfuse tracing | Optional. Verified end-to-end against a localhost stack on Colima. |
| Cross-repo soft deps | Module-level tests pass. Live multi-repo dispatch hasn't been smoke-tested. |

## Filing issues

Bugs, feature requests, or "is this how you'd model X?" questions all
welcome via GitHub Issues. Useful info to include:

- The relevant Linear-issue ID *if and only if* it lives in a public
  Linear project — most don't, so describe the scenario instead.
- Output of `mix symphony.diagnose <id>` if the bug is dispatch-related.
- The exact `WORKFLOW.md` configuration (redact secrets) and the
  contents of `~/.claude/state/langfuse_hook.log` if observability is
  involved.

## Pull requests

The repo eats its own dogfood — most PRs are opened by the orchestrator
running against itself. Contributions from outside that loop are still
welcome:

1. Fork + branch off `main`. Branch naming: `<your-handle>/<short-slug>`
   is fine; the orchestrator uses `enggabrieltorres/pes-NNN-…` but that
   prefix is just Linear's `branchName` field — feel free to ignore.
2. Run the full suite locally: `mix deps.get && mix test`. The tree
   should be green (modulo two pre-existing flakes in `core_test.exs`
   and `workspace_and_config_test.exs`). Use any Elixir version
   manager — Erlang/OTP 28 + Elixir 1.19.x is the supported pair.
3. New Elixir code needs `@spec` typespecs (see `mix specs.check`).
4. Open the PR against `main`. Squash-and-merge is the default.

## Repository layout

```
lib/symphony_elixir/        Symphony orchestrator + Symphony fork
lib/symphony_elixir/repos/  Multi-repo routing, worktree, lockbox
lib/symphony_elixir/branches/  BaseResolver, IntegrationBuilder, Reconciler
lib/symphony_elixir/deps/   DispatchGuard, Cascade
lib/symphony_elixir/pr/     PR.Router (forge-side base management)
lib/symphony_elixir/agent/  Claude Code runtime adapter
lib/symphony_elixir/forge/  GitHub behaviour + gh CLI client
docs/superpowers/specs/     Architecture spec
docs/operators/             Operator runbooks
langfuse/                   Optional self-hosted Langfuse stack
third_party/                Vendored upstream code with attributions
```

## License

By contributing you agree your contribution is licensed under the
project's [Apache 2.0 license](LICENSE). See [NOTICE](NOTICE) for
upstream attributions.
