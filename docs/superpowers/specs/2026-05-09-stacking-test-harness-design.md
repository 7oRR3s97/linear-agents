# Stacking Test Harness Design

Status: draft
Date: 2026-05-09
Owner: Ana Paula Grabe

## Goal

Give linear-agents a deterministic way to verify the multi-repo + dependency
stacking pipeline end-to-end, with two layers:

1. **Phase 1.** Expand `stacking_pipeline_test.exs` to cover scenarios the
   current suite misses (post-deploy mediation, branch drift, feedback loop,
   cascade chain, re-dispatch, missing blocker branch, three-blocker
   collapse).
2. **Phase 2.** Add a new live-Linear test that creates a real Linear
   project + issues, provisions local bare/work git repos, mocks the
   agent's commits, scripts "human" reviewer actions through Linear's
   real GraphQL API, and asserts the orchestrator's stacking decisions
   end-to-end.

Both layers run inside `mix test`. The Phase 2 test is gated behind
`SYMPHONY_RUN_LIVE_STACKING_E2E=1` like the existing live e2e.

## Non-goals

- Pushing to real GitHub (`gh repo create`, real PRs, real merges). Local
  bare repos act as `origin`; `Forge.GitHubStub` handles PR APIs.
- Running a real LLM agent. The mocked agent helper produces deterministic
  commits so we can force conflict scenarios without retrying.
- Integration with the docker SSH worker path used by `LiveE2ETest`. Phase 2
  runs in-process against the local filesystem.

## Architecture overview

| Module | Linear API | Git | Forge | Agent | Reviewer |
| --- | --- | --- | --- | --- | --- |
| `stacking_pipeline_test.exs` (existing, expand) | Mocked Issue structs | Local bare+work via `GitFixture` | `GitHubStub` | n/a (plumbing only) | scripted via fixture state |
| `live_stacking_e2e_test.exs` (new, gated) | **Real Linear GraphQL** | Local bare+work via `GitFixture` | `GitHubStub` | **Mocked** by `MockAgent` | **Scripted** via `FakeHuman` |

## Phase 1 — Expanded scenarios in `stacking_pipeline_test.exs`

Each scenario is one new `test "..."` block in the existing module, using
the same `make_source_repo!`, `push_branch`, `issue`, `blocker_issue`,
`snapshot`, `settings_with_paths` helpers.

### 1. Three-blocker integration → single-blocker collapse

A, B, C all `In Review`. `BaseResolver.resolve(X, [A, B, C], cfg)` returns
`{:integration, "symphony/integration/pes-x"}`. `IntegrationBuilder.rebuild`
merges all three. B reaches `Done`. Resolver re-runs and still returns
`:integration` over [A, C]. C reaches `Done`. Resolver returns
`{:single_blocker, "feat/A"}`. Asserts the integration branch is rebuilt with
the reduced contributor set on each transition.

### 2. Post-deploy mediation, clean rebase

A reaches `Done`. X's branch sits on top of an old A SHA. `Reconciler.run`
with `forge_repos:` set drives `Branches.Rebaser.rebase_onto(X.branch,
"main")`. Rebase succeeds, force-push-with-lease fires once, X's PR base
remains pointed at `main` via the stub.

### 3. Post-deploy mediation, rebase conflict

Same setup but X's commits touch the same lines as A's merged commits.
`Rebaser.rebase_onto/2` returns `{:conflict, files}`. Assertions:
- `git rebase --abort` ran (working tree clean).
- No `force_push` recorded against the stub.
- Reconciler emits `{:rebase_run, "PES-X", {:conflict, _}}` event.
- X's branch on the bare repo is unchanged (head SHA matches pre-attempt).

### 4. Branch drift retry

Stub `force_push` to fail once with the lease-rejected signal, succeed on
retry. `Rebaser` calls force-push, sees rejection, retries once, succeeds.
Assert exactly two `force_push` calls recorded.

### 5. Feedback loop trigger

X is `In Review` with a workpad comment at T0. A new non-workpad comment is
posted at T1 > T0. `Feedback.Detector.run([x], [...comments...])` returns
`{:rewind, "PES-X", _}`. Reconciler/feedback wiring (whichever exists) moves
X to the configured `feedback.rework_state` (`Todo`).

### 6. Cascade chain (A → B → C)

All three `In Review`. A rewinds to `Todo`. Tick 1: `Reconciler.run` emits
`{:cascade_pending, "id-B", "id-A"}`. Apply cascade → B rewinds. Tick 2:
emits `{:cascade_pending, "id-C", "id-B"}`. Apply cascade → C rewinds.
Confirms cascades propagate one tick at a time.

### 7. Re-dispatch after rewind preserves `branch_name`

X went `In Review` → `Todo` via cascade or feedback. On next dispatch:
- `BaseResolver.resolve(x, ...)` returns the same base ref logic.
- `Worktree.add(repo, "PES-X", base, "feat/x", ...)` is called with the
  identical branch name (no `-2` suffix or rename).

### 8. Blocker branch missing on remote

A is `In Review`, but `snapshot.branch_exists?` returns false for `feat/A`.
`DispatchGuard.evaluate(x, snapshot, cfg)` returns
`{:skip, :blocker_branch_missing}`. No `BaseResolver` call needs to happen.

## Phase 2 — `live_stacking_e2e_test.exs`

### Lifecycle

```
setup
  ├─ resolve real Linear team (env: SYMPHONY_LIVE_LINEAR_TEAM_KEY, default SYME2E)
  ├─ create real Linear project "Symphony Stacking E2E <run_id>"
  ├─ create real Linear issues A, B, X, Y (all AFK, all repo:src)
  │     X.blockedBy = [A, B]      ← used by scenario E (integration)
  │     Y.blockedBy = [A]          ← used by scenarios A–C (cascade)
  ├─ make local bare + work repo under tmp_dir
  ├─ write WORKFLOW.md pointing repositories.paths.src at the work clone
  ├─ install Forge.GitHubStub
  └─ open manifest at <tmp_dir>/LIVE_STACKING_E2E_MANIFEST.json

test sequence (single test, shared state)
  ├─ scenario A: stacked dispatch
  ├─ scenario B: retarget on merge
  ├─ scenario C: cascade rewind
  ├─ scenario D: feedback loop
  └─ scenario E: conflict integration

teardown (after block, runs on success and failure)
  ├─ append final manifest entries
  ├─ complete_project on real Linear (existing helper)
  ├─ uninstall GitHubStub
  ├─ restart orchestrator if it was stopped
  └─ tmp_dir auto-cleaned by ExUnit @tag :tmp_dir; manifest path is logged
```

### `MockAgent.dispatch/3`

Replaces `AgentRunner.run/3` for the duration of the live test. Signature:

```elixir
@spec dispatch(issue :: Issue.t(),
               base_ref :: String.t(),
               repo :: %{path: String.t(), bare_path: String.t()}) ::
        {:ok, %{branch: String.t(), head_sha: String.t(), pr_number: pos_integer()}}
```

Behavior:
1. `git -C repo.path checkout <base_ref>`.
2. `git -C repo.path checkout -b <issue.branch_name>`.
3. Write a deterministic file `<issue.identifier>.txt` with body
   `agent=#{issue.identifier};base=#{base_ref}\n`. For the conflict scenario,
   the helper accepts an `opts[:conflict_with]` so two issues can write
   conflicting content to the same file (`shared.txt`).
4. `git add` + commit (`Test User <test@example.com>`).
5. `git push origin <issue.branch_name>`.
6. Allocate a PR number, call
   `GitHubStub.set_pr({"acme/src", branch}, %{number: n, base: base_ref,
   head: branch, state: "OPEN", merged: false})`.
7. Post a workpad comment to Linear (`## Agent Workpad\n…`) via real
   `Linear.Client.graphql/2`.
8. Move issue to `In Review` via Linear `issueUpdate`.
9. Append all of the above to the manifest.

### `FakeHuman` helpers

All operate against the real Linear API.

- `FakeHuman.merge!(issue, repo)` — moves issue to a Linear `completed`-type
  state. Marks the GitHubStub PR for that branch `merged: true,
  state: "MERGED"`. Deletes `<issue.branch_name>` from the bare repo so
  `delete_branch_on_merge: true` is simulated.
- `FakeHuman.request_changes!(issue, body)` — posts a Linear comment with
  `created_at > workpad.updated_at`. The body is whatever the test passes;
  the timestamp constraint is what triggers feedback detection.
- `FakeHuman.rewind!(issue)` — moves issue back to the configured
  `stacking.rework_state` (`Todo`).

### Scenarios in order

**A. Stacked dispatch.** One `Reconciler.run` tick over [A, B, X, Y].
Decision: A and B are dispatchable (no blockers); X and Y skip with
`{:skip, :blocker_active}`. Test calls `MockAgent.dispatch(A, "main",
repo)` → A goes `In Review`. (B stays in `Todo` for now; it's used in
scenario E.) Second tick: Y is eligible (only blocker is A);
`BaseResolver.resolve(Y, [A], cfg)` returns `{:single_blocker,
"feat/A"}`. `MockAgent.dispatch(Y, "feat/A", repo)`. Assert stub PR for Y
has `base: "feat/A"`. X is *not* dispatched yet because B is still
unfinished.

**B. Retarget on merge.** `FakeHuman.merge!(A, repo)`. Run reconciler with
`forge_repos: %{"src" => "acme/src"}`. Stub records one `retarget_pr` call
for Y's PR targeting `main`. (X has no PR yet at this point.)

**C. Cascade rewind.** `FakeHuman.rewind!(A)` (move A from `Done` back to
`Todo`). Run reconciler. Cascade emits `{:cascade_pending, Y, A}`. Apply
cascade — Y is moved back to `Todo` on real Linear. Verify by re-fetching
Y from Linear and asserting `state.type` is `unstarted`. (X is still in
`Todo` from scenario A so it's not affected.)

**D. Feedback loop.** Restore A to `In Review` and `FakeHuman.merge!(A)`
again so the dependency chain is clear. Re-dispatch Y with
`MockAgent.dispatch(Y, "main", repo)` so Y is `In Review` with a fresh
workpad. `FakeHuman.request_changes!(Y, "fix the regex on line 42")`.
Run feedback detector. Assert Y moved to `Todo` on real Linear.

**E. Conflict integration.** B was created in setup but never dispatched.
Re-dispatch A so it's `In Review` again with conflicting content:
`MockAgent.dispatch(A, "main", repo, file: "shared.txt", content:
"from A\n")`. Dispatch B against `main` with conflicting content on the
same file: `MockAgent.dispatch(B, "main", repo, file: "shared.txt",
content: "from B\n")`. Both reach `In Review`.
`BaseResolver.resolve(X, [A, B], cfg)` returns `{:integration,
"symphony/integration/syme2e-...x"}`. `IntegrationBuilder.rebuild` returns
`{:conflict, ["shared.txt"]}`. `ConflictFallback.mark_conflict` returns
`:new`. `ConflictFallback.prepare_worktree` produces a worktree with an
in-tree merge; `git status --porcelain` in that worktree includes
`shared.txt`. Test does NOT resolve the conflict — the real agent would
do that. Assertion is on the fallback path running and surfacing the
conflict file, not on the resolution.

### Manifest format

`LIVE_STACKING_E2E_MANIFEST.json` is appended in JSON-Lines. Each line is
one record so the file remains valid mid-test even if the run aborts.

```jsonl
{"event":"setup","linear":{"team_id":"…","project_id":"…","project_url":"…"},"repo":{"bare_path":"…","work_path":"…"},"ts":"2026-05-09T17:23:01Z"}
{"event":"issue_created","issue":{"id":"…","identifier":"SYME2E-101","url":"…","blocked_by":[]},"ts":"…"}
{"event":"issue_created","issue":{"id":"…","identifier":"SYME2E-102","url":"…","blocked_by":["SYME2E-101"]},"ts":"…"}
{"event":"agent_dispatch","issue":"SYME2E-101","branch":"feat/syme2e-101","base":"main","head_sha":"abc123","pr_number":100,"ts":"…"}
{"event":"human_merge","issue":"SYME2E-101","ts":"…"}
{"event":"reconciler_tick","decisions":[…],"ts":"…"}
{"event":"teardown","status":"ok","ts":"…"}
```

The manifest path is logged on test exit (success or failure), so the
operator can `cat` it to deduce every artifact created.

### Test gating

```elixir
@moduletag :live_stacking_e2e
@moduletag timeout: 300_000

@skip_reason if(System.get_env("SYMPHONY_RUN_LIVE_STACKING_E2E") != "1",
                do: "set SYMPHONY_RUN_LIVE_STACKING_E2E=1 to enable live Linear + local-Git stacking e2e")

@tag skip: @skip_reason
test "live stacking pipeline against real Linear and local Git", %{tmp_dir: tmp} do
  …
end
```

The test is also excluded from the default `mix test` run via
`mix.exs`'s existing `:exclude` list (already excludes `:live_e2e`; we add
`:live_stacking_e2e`).

### Linear API operations used

The test reuses `Linear.Client.graphql/2` and the GraphQL fragments already
present in `LiveE2ETest` for team/state/project handling. New fragments
needed:

- `issueUpdate` to set `blockedById` relationships at creation time (via
  `issueRelationCreate` mutation).
- `commentCreate` for workpad and feedback comments.
- `issueUpdate` for state transitions (already covered).

### Cleanup invariants

- Linear project is moved to a `completed`-type status in the `after`
  block. Issues stay attached but are no longer in candidate fetches
  because their project is completed.
- The bare and work repos live under `tmp_dir`, which ExUnit removes
  automatically.
- The manifest path is *not* removed; it's printed on test exit and lives
  in `tmp_dir`. If the operator wants it, they copy it before exiting.
- `Process.whereis(SymphonyElixir.Orchestrator)` is restarted via
  `Supervisor.restart_child` if the test stopped it (mirrors existing
  `LiveE2ETest` behavior).

## File layout

```
test/support/
  mock_agent.exs            # MockAgent.dispatch/3
  fake_human.exs            # FakeHuman.merge!, .rewind!, .request_changes!
  manifest.exs              # Manifest.append/2, Manifest.path/0
test/symphony_elixir/
  stacking_pipeline_test.exs   # +8 new scenarios (Phase 1)
  live_stacking_e2e_test.exs   # new module (Phase 2)
docs/operators/
  testing-stacking-locally.md  # short runbook
```

`mix.exs` updates: add `:live_stacking_e2e` to the test exclusion list so
default `mix test` skips it. `test/test_helper.exs` may need
`ExUnit.configure(exclude: [:live_e2e, :live_stacking_e2e])` mirroring
the existing pattern.

## Operator runbook (`docs/operators/testing-stacking-locally.md`)

Short doc covering:

1. How to run the expanded plumbing tests: `mix test
   test/symphony_elixir/stacking_pipeline_test.exs`.
2. How to run the live e2e:
   - Required env: `LINEAR_API_KEY`, `SYMPHONY_RUN_LIVE_STACKING_E2E=1`,
     optional `SYMPHONY_LIVE_LINEAR_TEAM_KEY`.
   - Where the manifest lands and how to read it.
   - How to clean up if the test crashes mid-run (manual project complete
     via Linear UI; tmp dirs auto-clean).
3. How to extend `MockAgent` for new scenarios.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Real Linear creates clutter on the workspace | Test always completes the project in `after`; manifest tracks every ID for manual cleanup. |
| Linear rate limits during repeated runs | Tests are gated; default CI never runs them. Local-only by design. |
| `GitHubStub` drift from real `gh` behavior | Existing stub already used by `stacking_pipeline_test.exs`; expanding it stays aligned with that test. |
| MockAgent doesn't catch real agent regressions | Phase 1 plumbing tests don't depend on the agent; Phase 2 is explicitly an orchestrator test, not an agent test. The existing `LiveE2ETest` keeps covering agent runtime. |
| Conflict scenario depends on `ConflictFallback.prepare_worktree` semantics | Test asserts on `git status --porcelain` rather than internal state; matches the assertion pattern already in `stacking_pipeline_test.exs`. |

## Open questions

None outstanding at design time. Implementation may surface follow-ups
(e.g., whether `Reconciler.run` needs a new `forge_repos` opt for stubbed
runs or already supports it — needs confirmation in the plan).
