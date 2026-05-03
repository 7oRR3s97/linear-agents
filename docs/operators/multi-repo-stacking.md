# Operator Guide: Multi-repo + Stacked-PR Workflow

This guide walks through running linear-agents with multi-repo routing and
dependency-aware PR stacking enabled. For the architecture, read
[`docs/superpowers/specs/2026-05-03-multi-repo-deps-design.md`](../superpowers/specs/2026-05-03-multi-repo-deps-design.md).

## Table of Contents

- [Pre-requisites](#pre-requisites)
- [WORKFLOW.md configuration](#workflowmd-configuration)
- [GitHub setup](#github-setup)
- [Linear setup](#linear-setup)
- [Verifying with `mix symphony.diagnose`](#verifying-with-mix-symphonydiagnose)
- [Operator log keys](#operator-log-keys)
- [Troubleshooting](#troubleshooting)
- [Manual recovery](#manual-recovery)

## Pre-requisites

| Requirement | Why |
| --- | --- |
| `gh` CLI on PATH, authenticated | PR retargeting + integration-branch deletion. |
| `claude` CLI on PATH (Claude subscription, `claude login`) | Agent runtime when `agent.runtime: claude_code`. |
| Pre-cloned repositories on the operator's machine | Each issue gets a `git worktree` against the source clone — no clone-per-issue. |
| Linear API key in `LINEAR_API_KEY` | Tracker auth. |

If anything is missing, `Symphony.Config.validate!/0` fails startup with a
clear error (e.g., `:stacking_gh_cli_missing`,
`:claude_code_cli_missing`).

## WORKFLOW.md configuration

The complete YAML front matter for a multi-repo stacking deployment:

```yaml
tracker:
  kind: linear
  project_slug: "linear-agent-…"   # your Linear project slug
  active_states: [Todo, "In Progress", "In Review"]
  terminal_states: [Done, Canceled, Duplicate]

polling:
  interval_ms: 5000

workspace:
  root: ~/code/linear-agents-workspaces

agent:
  max_concurrent_agents: 5
  max_turns: 20
  runtime: claude_code               # use Claude Code as the agent

claude_code:
  command: claude
  permission_mode: bypassPermissions
  turn_timeout_ms: 3600000
  read_timeout_ms: 5000
  stall_timeout_ms: 300000
  extra_args: []

repositories:
  default: web                       # which handle if no repo:* label matches
  by_label:
    "repo:web": web
    "repo:api": api
    "repo:infra": infra
  paths:
    web:   ~/code/acme-web           # absolute or ~ paths
    api:   ~/code/acme-api
    infra: ~/code/acme-infra
  remote: origin
  default_base_branch: main

agent_autonomy:
  label_dispatchable: "AFK"          # value that allows agent dispatch
  label_human_only: "HITL"           # value that blocks dispatch
  default_when_missing: "HITL"       # safe default for unlabeled issues

stacking:
  enabled: true                      # turns the new pipeline on
  branch_template: "{{ issue.branchName }}"
  integration_branch_template: "symphony/integration/{{ issue.identifier | downcase }}"
  unblock_states: ["In Review", "Done"]
  rework_state: "Todo"

hooks:
  before_remove: |
    mise exec -- mix workspace.before_remove
```

### Field reference

| Block.field | Purpose |
| --- | --- |
| `repositories.default` | Handle to use when no `repo:*` label matches. |
| `repositories.by_label` | Map of `repo:*` Linear labels to handles. |
| `repositories.paths` | Local filesystem path per handle. Path must exist as a git working tree. |
| `repositories.remote` | Remote name used by `git fetch`/`push` (default `origin`). |
| `repositories.default_base_branch` | Base ref when no blockers contribute (default `main`). |
| `agent_autonomy.label_dispatchable` | Value that lets the agent dispatch the issue. Case-insensitive. |
| `agent_autonomy.label_human_only` | Value that blocks dispatch entirely. Case-insensitive. |
| `agent_autonomy.default_when_missing` | What to assume when neither label is present. `HITL` is the safe default. |
| `stacking.unblock_states` | Linear states that count as "blocker has cleared." Must be a subset of tracker states. |
| `stacking.rework_state` | State to move dependents to when their blocker rewinds (default `Todo`). |
| `stacking.integration_branch_template` | Liquid template for the synthetic merge branch when 2+ same-repo blockers are open. |

## GitHub setup

For each repository configured in `repositories.paths`:

1. **Enable "Automatically delete head branches" (`delete_branch_on_merge: true`).**
   This is what makes single-blocker stacked PRs auto-retarget to `main`
   when the blocker merges. Repository → Settings → General → Pull
   Requests.
2. **Authenticate the `gh` CLI** as the operator running linear-agents:
   `gh auth login`. The CLI must be able to push to the repo and edit PRs.
3. Add a `linear-agent` PR label (or whatever you use as your tag).
   Symphony stamps every PR it opens with this label.

## Linear setup

1. **Create a label group `Agent Autonomy`** with two values: `AFK`
   (agents may pick up) and `HITL` (humans only). Apply one of them to
   every issue you want the orchestrator to consider.
2. **Create a label group `Repository`** with one value per configured
   handle, prefixed `repo:`. For example: `repo:web`, `repo:api`,
   `repo:infra`. Issues without a `repo:*` label fall through to
   `repositories.default`.
3. **Use Linear's `branchName` field as-is** — the orchestrator picks it
   up automatically. Don't override it locally before pushing; if you do,
   stacking falls apart for downstream tasks because they look up the
   blocker's branch by `branchName`.
4. **Create the issue states required by `tracker.active_states` and
   `stacking.unblock_states`.** The defaults above are `Todo`,
   `In Progress`, `In Review`, plus terminal `Done`. If your team uses
   different state names, set them in `WORKFLOW.md` to match.

## Verifying with `mix symphony.diagnose`

Read-only diagnostic for a single issue. Run from the directory that holds
your `WORKFLOW.md`:

```sh
mix symphony.diagnose PES-118
```

It prints:

- The resolved repo handle and local path.
- Each blocker, with its state, branch, and same/cross-repo classification.
- What `DispatchGuard` would say (`:ok` or `{:skip, reason}`).
- What `BaseResolver` would compute (`{:main, ...}`, `{:single_blocker,
  ...}`, or `{:integration, ...}`).
- The current PR state on the configured forge (`gh pr list`).

Use this whenever an issue isn't dispatching as you'd expect.

## Operator log keys

These structured-log keys appear on every stacking-related log line, so
you can grep / filter on them:

| Key | Meaning |
| --- | --- |
| `repo_handle` | Resolved repo for the issue (e.g., `web`). |
| `dep_mode` | `hard` (same-repo blocker) or `soft` (cross-repo). |
| `pr_base` | The intended PR base ref. |
| `integration_branch` | Name of the synthetic branch when 2+ hard-dep blockers are open. |
| `blocker_branches` | Comma-separated list of contributing blocker branches. |

## Troubleshooting

### `:repo_routing_failed`

The issue has no `repo:*` label and no `repositories.default` is set, or
the matched handle isn't in `repositories.paths`. Fix the issue's label,
or add the missing handle to `paths`.

### `:repo_routing_ambiguous`

The issue has more than one `repo:*` label that maps to a known handle.
Linear → remove the extra label.

### `:hitl`

The issue is labeled `HITL` (or has no autonomy label and `default_when_missing`
is `HITL`). The agent will not dispatch. To proceed: re-label as `AFK`.

### `:blocker_branch_missing`

A hard-dep blocker is in `In Review` (or another unblock state) but its
branch hasn't been pushed to `origin` yet, *or* the branch was force-pushed
under a different name than Linear's `branchName` field. Check the
blocker's PR — it must use `branchName` as its head ref.

### `:integration_conflict`

`IntegrationBuilder` couldn't merge two blocker branches cleanly. Symphony
falls back: it creates a worktree from `main`, merges the blockers in the
working tree, and lets the agent resolve the conflict. The PR for that
attempt targets `main` directly. After all blockers merge to `main`, the
diff cleans itself up.

If the conflict signature stays the same across multiple attempts, that's
a real coordination problem — split scope between the blockers, or
sequence them so they don't touch the same files.

### `:branch_drift`

`git push --force-with-lease` was rejected because the remote moved.
Symphony retries once. If that also fails, the issue surfaces here.
Typically caused by a human pushing to the same branch concurrently —
coordinate, then `mix symphony.diagnose` to confirm Symphony picks up the
new state.

## Manual recovery

### Stuck integration branch

If `symphony/integration/<id>` is in a bad state and you want Symphony to
rebuild from scratch:

```sh
git push --delete origin symphony/integration/<id>
```

Symphony's next reconciliation tick will rebuild it from current blocker
SHAs.

### Reset a worktree

If a per-issue worktree gets wedged:

```sh
# from the source clone
git worktree remove --force <workspace.root>/<repo_handle>/<issue_id>
```

Symphony creates a fresh worktree on the next dispatch.

### Force a rebuild

`mix symphony.diagnose <id>` shows the current state. Combine with
deleting the integration branch (above) to force a clean rebuild on the
next tick.
