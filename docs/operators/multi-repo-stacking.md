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
- [Post-deploy mediation (auto-rebase downstream PRs)](#post-deploy-mediation-auto-rebase-downstream-prs)
- [Feedback loop (auto-rework on Linear comments)](#feedback-loop-auto-rework-on-linear-comments)
- [Optional: Langfuse tracing](#optional-langfuse-tracing)

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

## Post-deploy mediation (auto-rebase downstream PRs)

When a hard-dep blocker merges to `main`, its dependents' branches still
carry the now-merged commits. The orchestrator actively rebases each
dependent's branch onto the new `main` and force-pushes — so dependent
PRs converge to clean diffs without needing the agent to re-dispatch.

### The flow

```
A merges → A's Linear issue → Done
            ↓
   Reconciler tick (next 5s)
            ↓
   For each dependent X where X's same-repo blockers are all Done
   AND X is not currently In Progress:
            ↓
        Branches.Rebaser.rebase_onto(X.branch, main)
            ↓
        - clean rebase  →  force-push-with-lease  →  X's PR diff cleans up
        - already-up-to-date  →  no-op
        - conflict  →  emit :rebase_run conflict event; X is left untouched
                       on origin (safe), dependent's PR carries the
                       merged commits until the next agent dispatch
                       resolves the conflict
            ↓
   Cascading: X's branch SHA changes → that's a fresh blocker SHA event
   for X's downstream dependents on the next tick. Each rebase ripples
   through the chain one tick at a time.
```

### Conditions that defer the rebase

The orchestrator does **not** rebase when:

- The dependent is currently `In Progress` — would yank state from
  under the running agent. Defer until the agent exits; the next tick
  picks it up.
- The dependent has no `branch_name` — there's nothing to rebase yet.
- The dependent has any same-repo blocker still active (not Done).
  Single-blocker rebase fires only when *all* hard-dep blockers have
  merged. Multi-blocker scenarios continue to use `IntegrationBuilder`
  rebuilds (a different code path).

### When the rebase conflicts

Conflicts surface as `{:rebase_run, "PES-X", {:conflict, files}}` on
the reconciler's event stream and are visible in the orchestrator's
logs. The dependent's branch on origin is **not modified** when a
rebase conflicts — `git rebase --abort` runs first, no force-push
fires.

The dependent stays in `In Review`. To recover: a reviewer can leave a
Linear comment ("merge conflict on rebase, please refresh the
branch") which the [feedback loop](#feedback-loop-auto-rework-on-linear-comments)
catches on the next tick, moving the dependent to `Todo` so the agent
can resolve the conflict and force-push from a clean rebase.

## Feedback loop (auto-rework on Linear comments)

By default a human reviewer either approves a PR (and merges) or rejects
it by manually moving the Linear issue back to `Todo`. With the feedback
loop turned on, the second step is automatic: leave a comment on the
Linear issue and the orchestrator notices on the next poll tick.

### How it works

For every issue currently in `In Review`, the orchestrator:

1. Loads the issue's comments (already part of the existing Linear poll —
   no extra roundtrip).
2. Finds the workpad comment (one whose body starts with the configured
   `feedback.workpad_marker`, default `## Agent Workpad`).
3. Compares each non-workpad comment's `created_at` against the
   workpad's `updated_at`.
4. If at least one comment is newer, moves the issue to
   `feedback.rework_state` (default `Todo`) via the Linear API.

The agent's prompt's "Step 4: Rework handling" reads the comments under
the workpad's timestamp on the next dispatch, addresses each, force-pushes
the existing branch, and advances the workpad — which clears the
"unread feedback" condition until the next reviewer comment arrives.

### Configuration

Default in this repo's `WORKFLOW.md`:

```yaml
feedback:
  enabled: true
  rework_state: "Todo"
  workpad_marker: "## Agent Workpad"
```

To disable, set `feedback.enabled: false`. With it off, manual state
moves remain the only rework trigger.

### Reviewer flow

```
1. Reviewer opens the Linear issue (PR is in `In Review`).
2. Reviewer adds a comment: "the regex on line 42 doesn't handle empty
   inputs — please fix and add a test."
3. Within `polling.interval_ms` (5s by default) the orchestrator picks
   it up, moves the issue to `Todo`, and logs the rewind.
4. Next dispatch tick, the agent picks up the issue, reads the new
   comment, makes the fix on the existing branch, force-pushes, updates
   the workpad, returns the issue to `In Review`.
5. Reviewer is notified by GitHub of the new push and reviews again.
```

### Scaling note

The detector reads every issue's comments inline with the existing
candidate fetch — no per-issue polling. Cost stays the same as the
baseline poll loop. The rewind itself is one Linear `issueUpdate` per
rewound issue, which fires at most once per fresh feedback signature.

## Optional: Langfuse tracing

Symphony ships **without observability by default**. The orchestrator
picks up issues, dispatches Claude Code, and lands PRs whether tracing
is configured or not.

If you want a turn-by-turn trace of every agent run — assistant
responses, every tool call, token costs, latency, searchable history —
follow the dedicated runbook at
[`langfuse/README.md`](../../langfuse/README.md). It walks through
self-hosting Langfuse via Docker and installing the Stop hook that ships
data per turn.

Symphony's `agent/claude_code/runner.ex` forwards `TRACE_TO_LANGFUSE`,
`LANGFUSE_BASE_URL`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, and
`CC_LANGFUSE_DEBUG` from the orchestrator's environment to every
dispatched `claude` subprocess — so once the stack is up and the env
vars are exported, every agent run shows up in Langfuse without
per-issue configuration. To turn tracing back off, just unset
`TRACE_TO_LANGFUSE`.
