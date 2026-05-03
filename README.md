# linear-agents

Multi-repo, dependency-aware Linear agent orchestrator. A fork of [Symphony's
reference Elixir implementation](https://github.com/openai/symphony/tree/main/elixir),
extended to:

- Route Linear issues to one of several pre-cloned local repositories based on
  a `repo:*` label.
- Stack pull requests when issues have hard code dependencies (same repo) so
  downstream tasks can have their PRs open even while blockers are still open.
- Treat cross-repo dependencies as soft sequencing only.
- Honor an `Agent Autonomy` label (`AFK` / `HITL`) to gate which issues
  agents may pick up.
- Operate under Trunk-Based Development. All PRs eventually point to `main`.
  The orchestrator never merges anything to `main`; humans alone merge.

## Status

Architecture spec lives at
[`docs/superpowers/specs/2026-05-03-multi-repo-deps-design.md`](docs/superpowers/specs/2026-05-03-multi-repo-deps-design.md).
Operator setup walkthrough at
[`docs/operators/multi-repo-stacking.md`](docs/operators/multi-repo-stacking.md).

The agent runtime is **Claude Code**, driven via the `claude` CLI in
`stream-json` mode (no API key — uses the operator's Claude subscription).

## How it works (post-upgrade)

1. Polls Linear for candidate issues filtered by `Agent Autonomy = AFK`.
2. Routes each issue to a configured repository via its `repo:*` label.
3. Computes the right base ref for each issue from its `blockedBy` graph:
   - 0 hard-dep blockers → base is `main`.
   - 1 hard-dep blocker → base is the blocker's branch (PR auto-retargets to
     `main` when the blocker merges).
   - 2+ hard-dep blockers → base is a synthetic `symphony/integration/<id>`
     branch that the orchestrator force-pushes whenever blockers change.
4. Creates a `git worktree` against the configured local clone for each issue.
5. Launches Claude Code in the worktree (`stream-json` mode, autonomous
   permissions) with a rendered prompt that includes base-branch metadata.
6. The agent edits, commits, pushes, opens a PR, and moves the issue to
   `In Review`. Humans merge.

If a human moves an `In Review` issue back to `Todo`, the orchestrator cascades
the rewind to dependents per the design doc.

## Setup

1. Install [mise](https://mise.jdx.dev/) and run `mise install` from this
   directory to provision Elixir/OTP.
2. Install deps: `mix deps.get`.
3. Set `LINEAR_API_KEY` (Linear → Settings → Security & access → Personal API
   keys).
4. `gh` CLI installed and authenticated (`gh auth login`).
5. `claude` CLI installed and authenticated (`claude login`).
6. Customize `WORKFLOW.md` per the [operator guide](docs/operators/multi-repo-stacking.md).
7. Run with `iex -S mix` or `mix run --no-halt`.

For deeper troubleshooting + log keys + manual recovery, see the
[operator guide](docs/operators/multi-repo-stacking.md).

## License

Apache 2.0, inherited from upstream Symphony.
