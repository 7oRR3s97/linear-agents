# Symphony Multi-Repo Routing and Dependency-Aware PR Stacking

Status: Draft (design complete, pending implementation plan)
Date: 2026-05-03
Owner: Ana Paula Grabe (`enggabrieltorres@gmail.com`)
Target codebase: `elixir/` (existing Symphony reference implementation)

## 1. Problem and goals

Extend Symphony so a single deployment can:

1. Route Linear issues to one of several pre-cloned local repositories based on
   an issue label.
2. Honor Linear `blocked_by` dependency edges as **hard code dependencies**
   when blocker and dependent live in the same repository — the dependent's
   work needs the blocker's commits checked out.
3. Treat dependencies *across* repositories as soft sequencing only — there is
   no git-level link, just a dispatch gate.
4. Open one pull request per task, so that downstream tasks can have their
   PRs open even while their blocker PRs are still open.
5. Operate under Trunk-Based Development. All PRs eventually point to `main`.
6. Never merge anything to `main`. Humans alone merge; Symphony's
   responsibility ends at PR creation, branch maintenance, and PR-base
   retargeting.

The base spec (`SPEC.md`) is unchanged. This design adds modules and
front-matter keys; it does not modify the orchestrator state machine beyond
adding eligibility filters and a new background reconciler.

## 2. State machine and dispatch semantics

### 2.1 States Symphony observes

| State | Active for Symphony? | Purpose |
| --- | --- | --- |
| `Backlog` | No | Ignored. |
| `Todo` | Yes (dispatch source) | Symphony picks up; the agent moves the issue to `In Progress` on first action. |
| `In Progress` | Yes (running) | Agent is editing, committing, pushing the branch. On completion the agent moves the issue to `In Review`. |
| `In Review` | Yes (wait state) | PR is open against the correct base. Downstream dependents become dispatchable. Humans review here. |
| `Done` | Terminal | Human merged. Symphony cleans up. |
| `Cancelled` / `Duplicate` / `Closed` | Terminal | Same cleanup as `Done`; PR (if any) is left untouched. |

`In Review` replaces the existing `Human Review` state name. The existing
`Merging` state is dropped from Symphony's `active_states`; humans own merging
and move issues directly `In Review → Done`.

### 2.2 Dispatch eligibility

Issue X is dispatchable from `Todo` when **all** of the following hold:

1. State is `Todo`.
2. Issue carries the *Agent Autonomy* label value `AFK`. Value `HITL`, or
   missing label, blocks dispatch entirely.
3. For each blocker B of X, classified by repository:
   - **Same repo** (B's repo == X's repo) → **hard dependency**: B must be in
     `In Review` or `Done`. X branches from B's branch (or from a synthetic
     integration branch if multiple same-repo blockers).
   - **Cross repo** (B's repo ≠ X's repo) → **soft dependency**: B must be in
     `In Review` or `Done`. X branches from `main` of its own repo. No
     integration branch.
4. Concurrency slots (global and per-state) are available per Section 8.3 of
   the base spec.

### 2.3 Cascade on blocker rework

When blocker A transitions `In Review → Todo` (rework), dependents are
handled as follows. Hard and soft dependents follow the same rule.

| Dependent's current state | Symphony action |
| --- | --- |
| `Todo` | No-op. Dependent will become dispatchable when A re-reaches `In Review`. |
| `In Progress` | Do not disturb the running agent. Branch reconciler defers any rebase to agent exit. |
| `In Review` | Move the dependent to `Todo` automatically. Post a Linear comment explaining the rewind. On next dispatch, the agent re-runs against the updated blocker. |
| `Done` / merged | Out of scope. Symphony does not touch merged work. |

Reason for rewinding `In Review` dependents uniformly: same-repo case has a
stale base ref; cross-repo case may have stale contract assumptions. Either
way, the open PR no longer reflects valid work.

### 2.4 Dispatch when X depends on a HITL blocker

A blocker labeled `HITL` is performed by a human, but its state transitions
still drive X's dispatchability. Humans are expected to push the blocker's
branch using Linear's `branchName` so Symphony can find it. If the human
deviates, Symphony reports the missing branch on the dependent's workpad
(treated as `:blocker_branch_missing`) and waits for it to appear.

## 3. PR base strategy

The base of X's pull request is computed from X's blockers at dispatch time
and rebuilt by the background reconciler when the picture changes.

| Open hard-dep blockers of X | Worktree branched from | PR base of X |
| --- | --- | --- |
| 0 | `main` | `main` |
| 1 (A) | A's branch (`branchName`) | A's branch (auto-retargets to `main` when A merges, since `delete head branch on merge` must be enabled) |
| 2 or more | `symphony/integration/<X.id>` | `symphony/integration/<X.id>` (Symphony force-pushes this branch on every blocker change; deletes it and retargets the PR to `main` when blockers all merge) |

Cross-repo blockers do not affect the table — they contribute only to the
dispatch gate (Section 2.2.3).

### 3.1 Integration branches

`symphony/integration/<id>` is **scaffolding only**. It is never merged
anywhere. Symphony force-pushes it; reviewers do not review it; humans do not
merge it. Its lifecycle:

1. Created by `Symphony.Branches.IntegrationBuilder` when X has 2+ open
   hard-dep blockers. Recipe: `main` plus a sequential merge of each blocker's
   branch.
2. Rebuilt every poll tick when any blocker SHA changes.
3. Reduced (rebuilt against the smaller blocker set) when a blocker merges to
   `main`.
4. Deleted when the blocker count drops below 2; PR is retargeted to either
   the single remaining blocker's branch or `main`.
5. Deleted (and PR retargeted to `main`) when X reaches `Done`.

### 3.2 Naming

- Task branches use Linear's `branchName` field by default. Configurable via
  `stacking.branch_template`.
- Integration branches use the namespace `symphony/integration/<id>` where
  `<id>` is `issue.identifier` lowercased. Configurable via
  `stacking.integration_branch_template`.

## 4. Configuration: `WORKFLOW.md` additions

Two new top-level keys, both opt-in. Existing single-repo deployments keep
working unchanged when `stacking.enabled` is absent or `false`.

```yaml
repositories:
  default: web
  by_label:
    "repo:web": web
    "repo:api": api
    "repo:infra": infra
  paths:
    web: ~/code/acme-web
    api: ~/code/acme-api
    infra: ~/code/acme-infra
  remote: origin
  default_base_branch: main

agent_autonomy:
  label_dispatchable: "AFK"
  label_human_only: "HITL"
  default_when_missing: "HITL"

stacking:
  enabled: true
  branch_template: "{{ issue.branchName }}"
  integration_branch_template: "symphony/integration/{{ issue.identifier | downcase }}"
  unblock_states: ["In Review", "Done"]
  rework_state: "Todo"

tracker:
  active_states: ["Todo", "In Progress", "In Review"]
  terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
```

### 4.1 New preflight validation

Extends Section 6.3 of the base spec (`dispatch_preflight`). When
`stacking.enabled` is `true`:

- Every value in `repositories.by_label` and `repositories.default` must be a
  key in `repositories.paths`.
- Every `repositories.paths[handle]` must point to an existing directory that
  is a valid git working tree (or worktree-host).
- `agent_autonomy.label_dispatchable` and `label_human_only` must be present
  and distinct strings.
- `stacking.unblock_states` must be a subset of
  `tracker.active_states ∪ tracker.terminal_states`.
- `gh` CLI must be on `PATH` and authenticated for every distinct origin
  remote across configured paths.

Failures block startup. Per-tick re-validation behavior follows the existing
spec rules.

### 4.2 Backward compatibility

When `stacking.enabled` is absent or `false`:

- `Symphony.Workspace` falls back to its existing `mkdir`-based path.
- `Symphony.Branches.Reconciler` is not started.
- `Symphony.Deps.DispatchGuard` is bypassed; the existing blocker rule from
  Section 8.2 of the base spec applies.
- `repositories` and `agent_autonomy` keys may still be set without effect, so
  teams can prepare config before flipping the switch.

## 5. Modules

### 5.1 New modules

| Module | Responsibility | Public surface (illustrative) |
| --- | --- | --- |
| `Symphony.Repos` | Pure registry. Resolves `(issue) → {repo_handle, local_path, remote, default_base}`. Reads `repositories` front matter. | `for_issue(issue)`, `path(handle)` |
| `Symphony.Repos.Worktree` | Git worktree CRUD against a source clone. | `add(repo, issue_id, base_ref)`, `remove(repo, issue_id)`, `list(repo)` |
| `Symphony.Repos.Lockbox` | One GenServer per source repo. Serializes all `git` operations against that source clone. | `with_lock(repo, fn)` |
| `Symphony.Deps.DispatchGuard` | Eligibility filter that extends the orchestrator's candidate selection (Section 8.2). | `evaluate(issue, snapshot) → :ok | {:skip, reason}` |
| `Symphony.Branches.BaseResolver` | Pure logic. Computes the base ref for the worktree and the PR base from issue + blocker snapshot. | `resolve(issue, blockers) → {:main, "main"} | {:single_blocker, ref} | {:integration, name}` |
| `Symphony.Branches.IntegrationBuilder` | Force-pushes synthetic integration branches. | `rebuild(issue, blocker_branches) → {:ok, sha} | {:conflict, files}` |
| `Symphony.Branches.Reconciler` | Background poll-tick task. Detects blocker SHA and state changes; calls `IntegrationBuilder` and `PR.Router`. | `run(snapshot)` |
| `Symphony.Forge.GitHub` | Minimal `gh` CLI wrapper. | `pr_state(repo, branch)`, `retarget_pr(repo, pr, base)`, `pr_for_branch(repo, branch)` |
| `Symphony.PR.Router` | Composes `BaseResolver` + `Forge.GitHub`. | `ensure_pr_base_correct(issue)` |

### 5.2 Existing modules touched

| Module | Change |
| --- | --- |
| `lib/symphony_elixir/workspace.ex` | Stacking-aware path delegates to `Repos.Worktree`. Plain-`mkdir` path preserved for `stacking.enabled=false`. |
| `lib/symphony_elixir/prompt_builder.ex` | New template variables: `{{ repo }}`, `{{ base_branch }}`, `{{ pr_base_branch }}`, `{{ blocker_branches }}`, `{{ integration_conflict }}`. |
| `lib/symphony_elixir/orchestrator.ex` | Candidate selection invokes `DispatchGuard`. Per-tick reconciliation invokes `Branches.Reconciler` after the existing reconciliation pass. |
| `lib/symphony_elixir/linear/*.ex` | Issue normalization (`linear/issue.ex`, `linear/adapter.ex`) includes `branchName`. Blocker fetches include their state so dispatch decisions don't require a second roundtrip. |
| `lib/symphony_elixir/specs_check.ex` | Adds the preflight checks listed in Section 4.1. |

### 5.3 Concurrency model

- One `Symphony.Repos.Lockbox` GenServer per source repo path.
- All operations against the source clone or its `.git` (fetch, worktree
  add/remove, integration branch build, push) flow through the Lockbox for
  that repo.
- Worktrees are independent file systems once created. Agents work in their
  worktrees in parallel without going through the Lockbox.
- Branch reconciler only mutates a task's branch when the task is **not**
  `In Progress`. Running tasks have their rebase deferred to agent exit.
- Force-push is always `--force-with-lease`, never plain `--force`.

## 6. Lifecycle

End-to-end timeline for one task X with one same-repo blocker A.

```
[ poll tick N ]
  ├─ existing reconciliation (Section 8.5 of base spec)
  ├─ Symphony.Branches.Reconciler.run/1
  │     └─ for each running / Code-Review task:
  │          - blocker SHA + state diff
  │          - IntegrationBuilder.rebuild if SHA changed
  │          - PR.Router.ensure_pr_base_correct if blocker terminal-state changed
  ├─ Symphony.Deps.DispatchGuard filters Linear candidates
  └─ dispatch eligible tasks  → PreparingWorkspace below
```

Per-attempt phases:

| Phase | Owner | Action |
| --- | --- | --- |
| 1. PreparingWorkspace | Symphony | `Repos.for_issue/1` → handle + path. `BaseResolver.resolve/2` → `{:single_blocker, A.branchName}`. Acquire `Repos.Lockbox(X.repo)`. |
| 2. SourceFetch | Symphony | `git -C <source> fetch <remote>`. Confirm `A.branchName` exists. |
| 3. WorktreeAdd | Symphony | `git worktree add <ws>/<X.id> A.branchName` then `git checkout -b X.branchName`. Release Lockbox. |
| 4. BuildingPrompt | Symphony | Render template with `{{ repo }}`, `{{ base_branch }}=A.branchName`, `{{ pr_base_branch }}=A.branchName`, `{{ blocker_branches }}=[A.branchName]`. |
| 5. LaunchingAgent | Symphony | Codex app-server with `cwd=<ws>/<X.id>`. |
| 6. StreamingTurn | Agent | Edits, commits, `git push origin X.branchName`. Opens PR with `gh pr create --base A.branchName --head X.branchName`. Moves issue to `In Review`. |
| 7. AgentExits | Orchestrator | Run completes. Workspace preserved per existing rule. |

### 6.1 Multi-blocker delta

- Phase 1: `BaseResolver.resolve/2` returns `{:integration, "symphony/integration/<X.id>"}`.
- Phase 2 also calls `IntegrationBuilder.rebuild(X, [A.branchName, B.branchName])`. On `{:conflict, files}` the dispatch is aborted for this tick and the conflict-fallback flow (Section 7) is followed on the next attempt.
- Phase 3: worktree branched from `symphony/integration/<X.id>`.
- Phase 6: agent opens PR with `--base symphony/integration/<X.id>`.

### 6.2 Cross-repo soft-dep delta

- Phase 1: `BaseResolver.resolve/2` returns `{:main, "main"}` (cross-repo path skips stacking).
- Phase 2: standard fetch on X's source clone only.
- Phase 3: worktree branched from `main`.
- Phase 6: agent opens PR with `--base main`.
- The reconciler does not maintain any integration branch for X.

### 6.3 Reconciler operations per tick

For each task in `In Progress` or `In Review`:

1. Refresh blocker SHAs (cheap fetch within the relevant Lockbox).
2. Refresh blocker states from Linear (extends the existing reconciliation).
3. If a blocker SHA changed and X is hard-dep: rebuild integration branch
   (multi) or schedule rebase of X's branch (single). Agent-exit applies the
   rebase if the task is currently `In Progress`.
4. If a blocker reached `Done` (merged): retarget the PR base. Single-blocker
   → `main`. Multi-blocker → drop that blocker from the integration recipe
   and rebuild; retarget to `main` when the integration branch becomes
   redundant.
5. If a blocker rewound `In Review → Todo`: apply Section 2.3 cascade rule.

### 6.4 End-of-life

When X reaches `Done`:

- `Repos.Worktree.remove(repo, X.id)`.
- Delete `symphony/integration/<X.id>` from origin if it exists.
- Recompute integration recipes for X's dependents on the next tick (X drops
  out as a blocker because it is now in `main`).

## 7. Error handling

### 7.1 Configuration / startup errors

| Failure | Policy |
| --- | --- |
| `repositories.paths[X]` missing on disk | Startup validation fails. |
| Path exists but is not a git repo | Same. |
| `repositories.by_label` references handle missing from `paths` | Same. |
| `stacking.enabled=true` without `repositories` block | Same. |
| `gh` CLI not installed or not authenticated | Same. |

### 7.2 Per-issue dispatch errors

| Failure | Policy |
| --- | --- |
| No `repo:*` label and no `repositories.default` | Skip dispatch, log `repo_routing_failed`, no retry until label fixed. |
| Multiple `repo:*` labels | Skip dispatch, log `repo_routing_ambiguous`. |
| Missing `Agent Autonomy` label | Skip dispatch silently (treated as `HITL`). Counter on dashboard. |
| `HITL` label | Skip dispatch silently. |
| Blocker not in unblock state | Skip dispatch (rechecked next tick). |
| Blocker branch missing on origin (hard dep) | Skip dispatch and log `blocker_branch_missing` on the task workpad. After 5 consecutive ticks, surface in the dashboard. |

### 7.3 Git operation errors

All git failures occur inside a Lockbox.

| Failure | Policy |
| --- | --- |
| `git fetch` fails | Exponential backoff per Section 8.4 of base spec. Dispatches against that repo skipped this tick. |
| `git worktree add` fails | Fail current attempt, log `worktree_create_failed`, retry per Section 8.4. |
| Integration branch merge conflict | Mark X with `:integration_conflict`. Linear workpad records conflicting files + blocker SHAs. Next dispatch follows the **conflict fallback** path: worktree created from `main`, blocker branches merged into the worktree directly so the agent sees the conflict in working tree, prompt receives `{{ integration_conflict }}` populated, agent resolves and commits. PR base is `main` for that attempt; diff is intentionally noisy. Normal flow resumes once blockers merge to `main`. |
| Force-pushed blocker → rebase conflict on running X | Do not disturb the agent. Rebase target is computed but applied at agent exit. If rebase still conflicts: mark `:rebase_conflict` and re-dispatch through the conflict fallback. |
| `git push --force-with-lease` rejected | Refetch and retry once. Second failure: log `:branch_drift` and surface on dashboard. |

### 7.4 GitHub forge errors

| Failure | Policy |
| --- | --- |
| `gh pr edit --base` fails | Log, retry next tick. PR remains at previous base; not a correctness bug. |
| GitHub rate limit | Internal limiter backs off; reconciler skips that repo for the tick. |
| PR for X's branch does not yet exist (agent has not pushed) | Skip retarget. Reconciler is idempotent per tick. |

### 7.5 Cascade edge cases

| Situation | Behavior |
| --- | --- |
| Blocker A `In Review → Todo` while X is `In Progress` | Don't disturb X. Reconciler updates integration / rebase target on agent exit. |
| Blocker A `In Review → Todo` while X is `In Review` | Move X to `Todo`. Linear comment explains the rewind. |
| Blocker A `In Review → Done` while X is `In Progress` | Reconciler retargets X's PR base to `main` (single) or rebuilds reduced integration branch (multi). Agent unaffected. |
| Blocker A is `Cancelled` / `Closed` while X waits | X stays `Todo`. Operator must edit the Linear dependency or move A to `Done`. |
| Blocker A's branch deleted from origin manually | Treated as `:blocker_branch_missing`. |
| X labeled `HITL` with hard-dep blockers | Symphony does not dispatch X. Reconciler does not act on X (no agent ever ran). PR creation is the human's job. |

### 7.6 Observability additions

New structured log keys: `repo_handle`, `dep_mode` (`hard|soft`), `pr_base`,
`integration_branch`, `blocker_branches`. Existing log discipline (Section
13.1 of base spec) otherwise unchanged.

## 8. Testing strategy

### 8.1 Layer 1 — pure-logic unit tests

Target modules with no side effects:

- `Symphony.Repos` — label resolution, ambiguity, missing default, path
  normalization.
- `Symphony.Branches.BaseResolver` — every blocker count × dep-mode
  combination yields the right `{:main, ..} | {:single_blocker, ..} |
  {:integration, ..}`.
- `Symphony.Deps.DispatchGuard` — eligibility matrix: AFK/HITL × blocker
  states × repo classification × concurrency. Property-based tests via
  StreamData are appropriate.
- New prompt-template-variable assembly in `prompt_builder.ex`.

### 8.2 Layer 2 — git ops against temp source clones

Helper `Symphony.GitFixture` creates throwaway bare and working repos under
`tmp_dir` per test.

- `Repos.Worktree`: add, remove, list, cleanup. Collision when issue ID is
  reused. Behavior when source clone is dirty.
- `IntegrationBuilder`: clean merge happy path, sequential merge with three
  blockers, conflict surfacing, force-push idempotency.
- `Reconciler`: blocker SHA changes → integration rebuild called; blocker
  `In Review → Todo` → cascade applied; blocker disappears →
  `blocker_branch_missing` flagged.
- `Repos.Lockbox`: concurrent ops serialize; one fetch in flight at a time per
  repo; crashing op does not deadlock the lockbox.

### 8.3 Layer 3 — GitHub forge tests

`Symphony.Forge.GitHub` is the only module that shells out. All consumers
depend on its module behaviour. Tests use:

- A Mox-style mock implementing the GitHub behaviour for `Reconciler` and
  `PR.Router` tests.
- A small set of integration tests that actually invoke `gh` against a
  sacrificial repo, gated behind `@tag :live_github` and only run in CI on
  demand.

### 8.4 Layer 4 — orchestrator integration

Existing fixtures with mocked Linear + mocked Codex extended with:

- Multi-repo dispatch — two repos, label routing, both succeed concurrently.
- Hard-dep stacking — A reaches `In Review` → X dispatches → X's PR base is
  A's branch.
- Multi-blocker integration — A and B both `In Review` → integration branch
  built → X dispatches against it.
- Cascade rework — X in `In Review` rewinds to `Todo` when blocker A goes
  `In Review → Todo`.
- Cross-repo soft dep — X dispatches when blocker A reaches `In Review`,
  branches from `main`, no integration branch.
- HITL gate — issue labeled `HITL` is never dispatched.

### 8.5 Operator tooling

`mix symphony.diagnose <issue_id>` prints what `BaseResolver` and
`DispatchGuard` would produce for the given issue right now. Cheap to add and
a major debugging accelerator.

### 8.6 Out of scope for module-level tests

- Codex protocol shape — owned by `agent_runner.ex` and Codex-side schema
  (Section 10 of base spec).
- Linear GraphQL schema drift — existing tracker tests cover this; new
  fields (`branchName`, blocker state traversal) are added to the existing
  round-trip tests.

## 9. Open items deferred to v2

- Webhook-driven reconciliation (Q9 option B). Polling at 5s is acceptable
  for v1.
- Agent-driven integration conflict resolution (Q10 option A) for the
  *integration branch build* step, beyond the worktree-fallback path
  documented in Section 7.3.
- Per-issue label override of the auto-detected dep mode (e.g., a `softdep`
  label that downgrades a same-repo dependency).
- GitLab / Bitbucket forge support; v1 is GitHub-only.
- A retry-budget for `:integration_conflict` before escalating to a human
  review state.

## 10. Glossary

- **Hard dep**: blocker and dependent share a repository; dependent's code
  needs blocker's commits checked out.
- **Soft dep**: blocker and dependent live in different repositories;
  dependent only needs the blocker's contract or sequencing.
- **Integration branch**: synthetic branch owned by Symphony, built by merging
  multiple blocker branches on top of `main`. Used as the PR base when a
  dependent has 2+ open hard-dep blockers. Force-pushed by Symphony, never
  merged anywhere.
- **AFK / HITL**: Linear label values for the *Agent Autonomy* dimension.
  `AFK` permits agent dispatch; `HITL` forces a human owner.
- **Lockbox**: per-source-repo GenServer that serializes git operations to
  prevent index corruption and racing fetches/pushes.
