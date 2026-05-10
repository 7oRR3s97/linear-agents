# Stacking Test Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a deterministic test harness for the multi-repo + dependency-stacking pipeline. Phase 1 expands `stacking_pipeline_test.exs` with eight new ExUnit scenarios. Phase 2 adds a gated live test that creates real Linear issues, mocks the agent's commits in local bare repos, and scripts reviewer actions against the real Linear API.

**Architecture:**
- Phase 1: pure ExUnit additions to the existing `SymphonyElixir.StackingPipelineTest` module — same helpers (`make_source_repo!`, `push_branch`, `issue`, `blocker_issue`, `snapshot`, `settings_with_paths`), same `GitHubStub` and `GitFixture` infrastructure.
- Phase 2: new `SymphonyElixir.LiveStackingE2ETest` module gated by `SYMPHONY_RUN_LIVE_STACKING_E2E=1`. Three new test-support files: `MockAgent` (drives deterministic commits + stub PRs), `FakeHuman` (drives real-Linear state changes), `Manifest` (writes a JSONL audit log of every artifact created).

**Tech Stack:** Elixir 1.19, ExUnit, `System.cmd("git", …)` for git ops, `Linear.Client.graphql/3` for real Linear, `Forge.GitHubStub` for in-memory PR APIs, `Jason` for JSON serialization.

**Spec reference:** `docs/superpowers/specs/2026-05-09-stacking-test-harness-design.md`.

**Note on scenario #4 (branch drift):** the design spec assumed a force-push retry exists in `Branches.Rebaser`. Code inspection shows it does NOT — `force_push/5` returns `{:error, {:push_failed, ...}}` on the first failure. Phase 1 task 1.4 therefore tests the current single-attempt behavior; adding retry logic is out of scope.

---

## File Structure

**New files:**
- `test/support/mock_agent.exs` — `SymphonyElixir.MockAgent` module. Drives a deterministic "agent" commit + stub PR + Linear workpad-comment + Linear state transition for one issue.
- `test/support/fake_human.exs` — `SymphonyElixir.FakeHuman` module. Performs reviewer actions (`merge!`, `rewind!`, `restore!`, `request_changes!`) against the real Linear GraphQL API plus the GitHubStub.
- `test/support/manifest.exs` — `SymphonyElixir.E2EManifest` module. JSONL append-only audit log of every Linear ID, repo path, branch, and PR number the live test touches.
- `test/symphony_elixir/live_stacking_e2e_test.exs` — `SymphonyElixir.LiveStackingE2ETest` module. The single test that walks scenarios A–E in sequence.
- `docs/operators/testing-stacking-locally.md` — short runbook explaining how to run each test gate and how to read the manifest.

**Modified files:**
- `test/symphony_elixir/stacking_pipeline_test.exs` — append eight new `test "..."` blocks (Phase 1 scenarios 1–8).
- `test/test_helper.exs` — `Code.require_file` the three new support files.
- `mix.exs` — add the new support files to `test_ignore_filters` so coverage doesn't pull them in.

---

## Phase 1 — Expanded ExUnit scenarios

Each task adds one new `test "..."` block to `test/symphony_elixir/stacking_pipeline_test.exs`. The module already has `setup` that installs `GitHubStub` and clears ETS tables, plus all the helpers we need.

### Task 1.0: Sanity-check the existing test suite passes

**Files:** none (verification only)

- [ ] **Step 1: Run the existing pipeline test**

```bash
cd /Users/anapaulagrabe/.superset/worktrees/linear-agents/hickory-cymbal
mix test test/symphony_elixir/stacking_pipeline_test.exs
```

Expected: all existing scenarios pass. If they don't, stop and surface the breakage — don't proceed.

- [ ] **Step 2: Run the wider test gate**

```bash
mix test
```

Expected: 391/391 (modulo two known flakes per `CONTRIBUTING.md`). This baseline matters because the next tasks add to the same module.

---

### Task 1.1: Three-blocker integration → single-blocker collapse

**Files:**
- Modify: `test/symphony_elixir/stacking_pipeline_test.exs` (append after the existing `"scenario: multi-blocker integration"` describe block)

- [ ] **Step 1: Add the new test block**

Append inside the `"scenario: multi-blocker integration"` describe block:

```elixir
test "three blockers → integration; one merges → still integration over two; second merges → single_blocker", %{tmp: tmp} do
  {repo, bare} = make_source_repo!(tmp, "src")
  push_branch(repo.path, "feat/A", "a.txt", "A\n")
  push_branch(repo.path, "feat/B", "b.txt", "B\n")
  push_branch(repo.path, "feat/C", "c.txt", "C\n")

  a_in_review = blocker_issue("PES-A", "src", "feat/A", "id-A", "In Review")
  b_in_review = blocker_issue("PES-B", "src", "feat/B", "id-B", "In Review")
  c_in_review = blocker_issue("PES-C", "src", "feat/C", "id-C", "In Review")

  x =
    issue("PES-X", ["repo:src", "AFK"], "feat/x",
      blocked_by: [
        %{id: "id-A", identifier: "PES-A", state: "In Review"},
        %{id: "id-B", identifier: "PES-B", state: "In Review"},
        %{id: "id-C", identifier: "PES-C", state: "In Review"}
      ]
    )

  cfg = settings_with_paths(%{"src" => repo.path})

  # All three In Review → integration over [A, B, C].
  assert {:ok, {:integration, "symphony/integration/pes-x"}} =
           BaseResolver.resolve(x, [a_in_review, b_in_review, c_in_review], cfg)

  assert {:ok, _sha} =
           IntegrationBuilder.rebuild(repo, "symphony/integration/pes-x", ["feat/A", "feat/B", "feat/C"])

  {_out, 0} =
    System.cmd("git", ["-C", bare, "rev-parse", "symphony/integration/pes-x"], stderr_to_stdout: true)

  # B reaches Done → still integration, but only over A and C.
  b_done = %{b_in_review | state: "Done"}

  active_after_b = Enum.reject([a_in_review, b_done, c_in_review], &(&1.state == "Done"))

  assert {:ok, {:integration, "symphony/integration/pes-x"}} =
           BaseResolver.resolve(x, active_after_b, cfg)

  assert {:ok, _sha} =
           IntegrationBuilder.rebuild(repo, "symphony/integration/pes-x", ["feat/A", "feat/C"])

  # C reaches Done → single_blocker over A.
  c_done = %{c_in_review | state: "Done"}
  active_after_c = Enum.reject([a_in_review, b_done, c_done], &(&1.state == "Done"))

  assert {:ok, {:single_blocker, "feat/A"}} =
           BaseResolver.resolve(x, active_after_c, cfg)
end
```

- [ ] **Step 2: Run the new test**

```bash
mix test test/symphony_elixir/stacking_pipeline_test.exs --only_specific:"three blockers"
```

(If the `only_specific` filter doesn't match, fall back to running the whole file and grepping for the scenario name.)

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/symphony_elixir/stacking_pipeline_test.exs
git commit -m "test(stacking): cover 3-blocker integration → single-blocker collapse

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.2: Post-deploy mediation, clean rebase

**Files:**
- Modify: `test/symphony_elixir/stacking_pipeline_test.exs` (add a new describe block after `"scenario: cascade rework"`)

- [ ] **Step 1: Add the alias and the describe block**

Add `alias SymphonyElixir.Branches.Rebaser` to the `alias` list at the top of the module if not already present (it is not — confirm by searching).

Append a new describe block:

```elixir
describe "scenario: post-deploy mediation" do
  test "blocker reaches Done; dependent branch rebases onto main, force-push fires once", %{tmp: tmp} do
    {repo, _bare} = make_source_repo!(tmp, "src")
    push_branch(repo.path, "feat/A", "a.txt", "from A\n")

    # Create X's branch off A so X carries A's commits.
    {_out, 0} = System.cmd("git", ["-C", repo.path, "checkout", "feat/A"], stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["-C", repo.path, "checkout", "-b", "feat/x"], stderr_to_stdout: true)
    GitFixture.commit_file(repo.path, "x.txt", "X content\n", "x adds x.txt")
    {_out, 0} = System.cmd("git", ["-C", repo.path, "push", "-u", "origin", "feat/x"], stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["-C", repo.path, "checkout", "main"], stderr_to_stdout: true)

    # Simulate A merging to main: cherry-pick A's commit to main and push.
    {a_sha, 0} = System.cmd("git", ["-C", repo.path, "rev-parse", "origin/feat/A"], stderr_to_stdout: true)
    a_sha = String.trim(a_sha)
    {_out, 0} = System.cmd("git", ["-C", repo.path, "cherry-pick", a_sha], stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["-C", repo.path, "push", "origin", "main"], stderr_to_stdout: true)

    # Now rebase feat/x onto main — A's commits should drop, only x.txt remains.
    assert {:ok, %{from: from_sha, to: to_sha}} =
             SymphonyElixir.Branches.Rebaser.rebase_onto(repo, "feat/x", "main", fetch: false)

    assert byte_size(from_sha) >= 7
    assert byte_size(to_sha) >= 7
    assert from_sha != to_sha

    # Confirm origin's feat/x now points at the rebased SHA.
    {origin_sha, 0} =
      System.cmd("git", ["-C", repo.path, "rev-parse", "origin/feat/x"], stderr_to_stdout: true)

    assert String.trim(origin_sha) |> String.starts_with?(to_sha)
  end
end
```

- [ ] **Step 2: Add the alias if missing**

Inside the module's alias list, ensure `SymphonyElixir.Branches.Rebaser` is aliased so we can write `Rebaser.rebase_onto/4`. Replace:

```elixir
  alias SymphonyElixir.Branches.{ConflictFallback, IntegrationBuilder, Reconciler}
```

with:

```elixir
  alias SymphonyElixir.Branches.{ConflictFallback, IntegrationBuilder, Rebaser, Reconciler}
```

(And update the call in step 1 to use `Rebaser.rebase_onto` instead of the fully qualified name.)

- [ ] **Step 3: Run the new test**

```bash
mix test test/symphony_elixir/stacking_pipeline_test.exs
```

Expected: all scenarios pass including the new one.

- [ ] **Step 4: Commit**

```bash
git add test/symphony_elixir/stacking_pipeline_test.exs
git commit -m "test(stacking): cover post-deploy mediation clean rebase

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.3: Post-deploy mediation, rebase conflict

**Files:**
- Modify: `test/symphony_elixir/stacking_pipeline_test.exs` (inside the `"scenario: post-deploy mediation"` describe block from Task 1.2)

- [ ] **Step 1: Add the conflict test**

Append inside the `"scenario: post-deploy mediation"` describe:

```elixir
test "blocker merged to main; X's branch conflicts with main on shared file → rebase aborts, origin unchanged", %{tmp: tmp} do
  {repo, _bare} = make_source_repo!(tmp, "src")
  push_branch(repo.path, "feat/A", "shared.txt", "from A\n")

  # X branches off main (NOT off A) and writes the same file with conflicting content.
  {_out, 0} = System.cmd("git", ["-C", repo.path, "checkout", "main"], stderr_to_stdout: true)
  {_out, 0} = System.cmd("git", ["-C", repo.path, "checkout", "-b", "feat/x"], stderr_to_stdout: true)
  GitFixture.commit_file(repo.path, "shared.txt", "from X\n", "x writes shared")
  {_out, 0} = System.cmd("git", ["-C", repo.path, "push", "-u", "origin", "feat/x"], stderr_to_stdout: true)
  {_out, 0} = System.cmd("git", ["-C", repo.path, "checkout", "main"], stderr_to_stdout: true)

  # Capture origin/feat/x's SHA before the attempt.
  {pre_sha, 0} =
    System.cmd("git", ["-C", repo.path, "rev-parse", "origin/feat/x"], stderr_to_stdout: true)

  pre_sha = String.trim(pre_sha)

  # Land A's content on main.
  {a_sha, 0} = System.cmd("git", ["-C", repo.path, "rev-parse", "origin/feat/A"], stderr_to_stdout: true)
  {_out, 0} = System.cmd("git", ["-C", repo.path, "cherry-pick", String.trim(a_sha)], stderr_to_stdout: true)
  {_out, 0} = System.cmd("git", ["-C", repo.path, "push", "origin", "main"], stderr_to_stdout: true)

  assert {:conflict, files} = Rebaser.rebase_onto(repo, "feat/x", "main", fetch: false)
  assert "shared.txt" in files

  # Origin's feat/x must NOT have moved.
  {post_sha, 0} =
    System.cmd("git", ["-C", repo.path, "rev-parse", "origin/feat/x"], stderr_to_stdout: true)

  assert String.trim(post_sha) == pre_sha
end
```

- [ ] **Step 2: Run the test**

```bash
mix test test/symphony_elixir/stacking_pipeline_test.exs
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/symphony_elixir/stacking_pipeline_test.exs
git commit -m "test(stacking): cover post-deploy rebase conflict (origin unchanged)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.4: Branch drift surfaces push error

**Files:**
- Modify: `test/symphony_elixir/stacking_pipeline_test.exs`

`Branches.Rebaser` does NOT currently retry. The spec scenario said "retries once" but that's aspirational. Test the actual behavior: a force-push that loses the lease returns `{:error, {:push_failed, ...}}`.

- [ ] **Step 1: Add the test inside the post-deploy describe**

Append inside the `"scenario: post-deploy mediation"` describe:

```elixir
test "force-push loses lease (concurrent remote update) → {:error, {:push_failed, _, _}}", %{tmp: tmp} do
  {repo, _bare} = make_source_repo!(tmp, "src")
  push_branch(repo.path, "feat/A", "a.txt", "from A\n")

  # X branches off A.
  {_out, 0} = System.cmd("git", ["-C", repo.path, "checkout", "feat/A"], stderr_to_stdout: true)
  {_out, 0} = System.cmd("git", ["-C", repo.path, "checkout", "-b", "feat/x"], stderr_to_stdout: true)
  GitFixture.commit_file(repo.path, "x.txt", "X\n", "x adds x.txt")
  {_out, 0} = System.cmd("git", ["-C", repo.path, "push", "-u", "origin", "feat/x"], stderr_to_stdout: true)
  {_out, 0} = System.cmd("git", ["-C", repo.path, "checkout", "main"], stderr_to_stdout: true)

  # Land A on main so a real rebase has work to do.
  {a_sha, 0} = System.cmd("git", ["-C", repo.path, "rev-parse", "origin/feat/A"], stderr_to_stdout: true)
  {_out, 0} = System.cmd("git", ["-C", repo.path, "cherry-pick", String.trim(a_sha)], stderr_to_stdout: true)
  {_out, 0} = System.cmd("git", ["-C", repo.path, "push", "origin", "main"], stderr_to_stdout: true)

  # Simulate concurrent push from another worker by advancing origin/feat/x
  # via a second clone, then run the rebaser. The rebaser fetches origin/feat/x
  # at attempt time (worktree-add base), so we have to advance origin AFTER
  # the rebaser computes its lease. Easiest substitute: advance origin
  # before invoking, then use `fetch: false` so the rebaser's lease references
  # the now-stale local origin tip.
  second_clone = Path.join(Path.dirname(repo.path), "second")
  GitFixture.working_clone(Path.dirname(repo.path) |> Path.join("src.git"), Path.dirname(repo.path), "second")
  {_out, 0} = System.cmd("git", ["-C", second_clone, "fetch", "origin"], stderr_to_stdout: true)
  {_out, 0} = System.cmd("git", ["-C", second_clone, "checkout", "feat/x"], stderr_to_stdout: true)
  GitFixture.commit_file(second_clone, "drift.txt", "from another worker\n", "drift commit")
  {_out, 0} = System.cmd("git", ["-C", second_clone, "push", "origin", "feat/x"], stderr_to_stdout: true)

  # The first clone's view of origin/feat/x is now stale. With fetch: false,
  # the rebaser's worktree starts from the stale ref and the force-with-lease
  # push will be rejected because origin moved.
  result = Rebaser.rebase_onto(repo, "feat/x", "main", fetch: false)

  assert match?({:error, {:push_failed, _code, _output}}, result)
end
```

- [ ] **Step 2: Run the test**

```bash
mix test test/symphony_elixir/stacking_pipeline_test.exs
```

Expected: PASS. Note: this scenario depends on git's `--force-with-lease` actually rejecting the push. If the bare repo configuration accepts the push despite the stale lease, the test will fail and you should investigate before assuming the test is wrong.

- [ ] **Step 3: Commit**

```bash
git add test/symphony_elixir/stacking_pipeline_test.exs
git commit -m "test(stacking): cover branch-drift force-push rejection

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.5: Feedback loop trigger

**Files:**
- Modify: `test/symphony_elixir/stacking_pipeline_test.exs`

- [ ] **Step 1: Add the alias and the describe block**

Add `alias SymphonyElixir.Feedback.Detector` to the module's alias list.

Append a new describe block:

```elixir
describe "scenario: feedback loop" do
  test "non-workpad comment newer than workpad → Detector returns {:feedback, [...]}" do
    workpad_at = ~U[2026-05-09 10:00:00Z]
    feedback_at = ~U[2026-05-09 10:30:00Z]

    workpad = %{
      id: "c1",
      body: "## Agent Workpad\nturn 1 done",
      created_at: workpad_at,
      updated_at: workpad_at,
      user_id: "agent",
      user_name: "agent"
    }

    feedback = %{
      id: "c2",
      body: "fix the regex on line 42 — empty inputs explode",
      created_at: feedback_at,
      updated_at: feedback_at,
      user_id: "human",
      user_name: "Reviewer"
    }

    issue = %Issue{
      id: "id-X",
      identifier: "PES-X",
      labels: ["repo:src", "AFK"],
      branch_name: "feat/x",
      state: "In Review",
      comments: [workpad, feedback]
    }

    assert {:feedback, [%{body: body}]} = Detector.evaluate(issue)
    assert body =~ "regex on line 42"
  end

  test "no comments newer than workpad → :no_feedback" do
    workpad_at = ~U[2026-05-09 10:00:00Z]
    older_at = ~U[2026-05-09 09:00:00Z]

    workpad = %{
      id: "c1",
      body: "## Agent Workpad\nturn 1 done",
      created_at: workpad_at,
      updated_at: workpad_at,
      user_id: "agent",
      user_name: "agent"
    }

    older = %{
      id: "c0",
      body: "kickoff",
      created_at: older_at,
      updated_at: older_at,
      user_id: "human",
      user_name: "Reviewer"
    }

    issue = %Issue{
      id: "id-X",
      identifier: "PES-X",
      labels: ["repo:src", "AFK"],
      branch_name: "feat/x",
      state: "In Review",
      comments: [older, workpad]
    }

    assert :no_feedback = Detector.evaluate(issue)
  end
end
```

- [ ] **Step 2: Run the test**

```bash
mix test test/symphony_elixir/stacking_pipeline_test.exs
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/symphony_elixir/stacking_pipeline_test.exs
git commit -m "test(stacking): cover feedback loop detector positive + negative

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.6: Cascade chain (A → B → C)

**Files:**
- Modify: `test/symphony_elixir/stacking_pipeline_test.exs`

- [ ] **Step 1: Add the test inside the existing `"scenario: cascade rework"` describe**

Append inside `describe "scenario: cascade rework" do`:

```elixir
test "A → B → C all In Review; A rewinds; ticks cascade B then C", %{tmp: tmp} do
  {repo, _} = make_source_repo!(tmp, "src")
  push_branch(repo.path, "feat/A", "a.txt", "A\n")
  push_branch(repo.path, "feat/B", "b.txt", "B\n")
  push_branch(repo.path, "feat/C", "c.txt", "C\n")

  a_in_review = blocker_issue("PES-A", "src", "feat/A", "id-A", "In Review")
  a_rewound = %{a_in_review | state: "Todo"}

  b_in_review =
    issue("PES-B", ["repo:src", "AFK"], "feat/B",
      state: "In Review",
      blocked_by: [%{id: "id-A", identifier: "PES-A", state: "In Review"}]
    )

  b_rewound = %{b_in_review | state: "Todo"}

  c_in_review =
    issue("PES-C", ["repo:src", "AFK"], "feat/C",
      state: "In Review",
      blocked_by: [%{id: "id-B", identifier: "PES-B", state: "In Review"}]
    )

  cfg = settings_with_paths(%{"src" => repo.path})

  # Tick 1: prime previous-state cache with everything In Review.
  {:ok, _} = Reconciler.run([b_in_review, c_in_review], [a_in_review, b_in_review], cfg)

  # Tick 2: A rewinds → cascade event for B.
  {:ok, e2} = Reconciler.run([b_in_review, c_in_review], [a_rewound, b_in_review], cfg)
  assert {:cascade_pending, "id-PES-B", "id-A"} in e2

  # Apply cascade: B rewinds.
  events = Reconciler.drain_cascades()
  issues_by_id = %{"id-PES-B" => b_in_review, "id-A" => a_rewound}

  lookup = fn id -> Map.fetch(issues_by_id, id) end
  parent = self()
  apply_fn = fn ident, state -> send(parent, {:linear_state, ident, state}); :ok end
  comment_fn = fn ident, body -> send(parent, {:linear_comment, ident, body}); :ok end

  assert [{:rewind, "PES-B", _}] = Cascade.apply_cascades(events, lookup, apply_fn, comment_fn)
  assert_received {:linear_state, "PES-B", "Todo"}

  # Tick 3: B is now Todo → cascade event for C.
  {:ok, e3} = Reconciler.run([c_in_review], [a_rewound, b_rewound], cfg)
  assert {:cascade_pending, "id-PES-C", "id-B"} in e3

  events_3 = Reconciler.drain_cascades()
  issues_by_id_3 = %{"id-PES-C" => c_in_review, "id-B" => b_rewound}
  lookup_3 = fn id -> Map.fetch(issues_by_id_3, id) end

  assert [{:rewind, "PES-C", _}] = Cascade.apply_cascades(events_3, lookup_3, apply_fn, comment_fn)
  assert_received {:linear_state, "PES-C", "Todo"}
end
```

- [ ] **Step 2: Run the test**

```bash
mix test test/symphony_elixir/stacking_pipeline_test.exs
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/symphony_elixir/stacking_pipeline_test.exs
git commit -m "test(stacking): cover cascade chain A→B→C ripples one tick at a time

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.7: Re-dispatch after rewind preserves branch_name

**Files:**
- Modify: `test/symphony_elixir/stacking_pipeline_test.exs`

- [ ] **Step 1: Add the describe block**

```elixir
describe "scenario: re-dispatch after rewind" do
  test "X went In Review → Todo; BaseResolver still returns same branch on next dispatch", %{tmp: tmp} do
    {repo, _} = make_source_repo!(tmp, "src")
    push_branch(repo.path, "feat/A", "a.txt", "A\n")

    a = blocker_issue("PES-A", "src", "feat/A", "id-A", "In Review")

    x =
      issue("PES-X", ["repo:src", "AFK"], "feat/x",
        state: "Todo",
        blocked_by: [%{id: "id-A", identifier: "PES-A", state: "In Review"}]
      )

    cfg = settings_with_paths(%{"src" => repo.path})

    # Pre-rewind dispatch decision.
    assert {:ok, {:single_blocker, "feat/x-base"}} = decision_for(x, [a], cfg, "feat/x-base")

    # After a Todo → In Review → Todo cycle the issue's branch_name doesn't change.
    x_after = %{x | state: "Todo"}

    assert {:ok, {:single_blocker, "feat/A"}} = BaseResolver.resolve(x_after, [a], cfg)
    # ^ second blocker name is feat/A (the blocker's branch), not feat/x-base.
    #   We're asserting that X's identifier→branch mapping is stable, so a real
    #   Worktree.add call would reuse "feat/x" rather than coining "feat/x-2".
    assert x_after.branch_name == x.branch_name
  end

  defp decision_for(issue, blockers, cfg, _expected) do
    BaseResolver.resolve(issue, blockers, cfg)
  end
end
```

Wait — the helper `decision_for/4` has unused params. Drop it. Replace the test body with the cleaner assertion:

```elixir
describe "scenario: re-dispatch after rewind" do
  test "X went In Review → Todo; branch_name is unchanged so next dispatch reuses it", %{tmp: tmp} do
    {repo, _} = make_source_repo!(tmp, "src")
    push_branch(repo.path, "feat/A", "a.txt", "A\n")

    a = blocker_issue("PES-A", "src", "feat/A", "id-A", "In Review")

    x_first_dispatch =
      issue("PES-X", ["repo:src", "AFK"], "feat/x",
        state: "Todo",
        blocked_by: [%{id: "id-A", identifier: "PES-A", state: "In Review"}]
      )

    cfg = settings_with_paths(%{"src" => repo.path})

    assert {:ok, {:single_blocker, "feat/A"}} = BaseResolver.resolve(x_first_dispatch, [a], cfg)

    # Simulate a rewind: state went In Review → Todo, branch_name is identical.
    x_after_rewind = %{x_first_dispatch | state: "Todo"}

    assert {:ok, {:single_blocker, "feat/A"}} = BaseResolver.resolve(x_after_rewind, [a], cfg)
    assert x_after_rewind.branch_name == "feat/x"

    # DispatchGuard accepts (with the SHA cache populated as in real life).
    assert :ok = DispatchGuard.evaluate(x_after_rewind, snapshot([a]), cfg)
  end
end
```

- [ ] **Step 2: Run the test**

```bash
mix test test/symphony_elixir/stacking_pipeline_test.exs
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/symphony_elixir/stacking_pipeline_test.exs
git commit -m "test(stacking): cover re-dispatch after rewind keeps branch_name stable

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.8: Blocker branch missing on remote

**Files:**
- Modify: `test/symphony_elixir/stacking_pipeline_test.exs`

- [ ] **Step 1: Add the describe block**

```elixir
describe "scenario: blocker branch missing on remote" do
  test "single-blocker scenario but branch_exists? returns false → DispatchGuard skips", %{tmp: tmp} do
    {repo, _} = make_source_repo!(tmp, "src")
    # NOTE: We deliberately do NOT push feat/A to origin.

    a_in_review_no_branch_pushed = blocker_issue("PES-A", "src", "feat/A", "id-A", "In Review")

    x =
      issue("PES-X", ["repo:src", "AFK"], "feat/x",
        blocked_by: [%{id: "id-A", identifier: "PES-A", state: "In Review"}]
      )

    cfg = settings_with_paths(%{"src" => repo.path})

    snapshot_no_branch = %{
      blockers_by_id: %{"id-A" => a_in_review_no_branch_pushed},
      branch_exists?: fn _h, _b -> false end
    }

    assert {:skip, {:blocker_branch_missing, "PES-A"}} =
             DispatchGuard.evaluate(x, snapshot_no_branch, cfg)
  end
end
```

- [ ] **Step 2: Run the test**

```bash
mix test test/symphony_elixir/stacking_pipeline_test.exs
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/symphony_elixir/stacking_pipeline_test.exs
git commit -m "test(stacking): cover DispatchGuard skip when blocker branch absent

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.9: Run full suite as a Phase-1 checkpoint

**Files:** none

- [ ] **Step 1: Run the whole test suite**

```bash
mix test
```

Expected: existing pass count + 8 new tests, all green (modulo two known flakes in `core_test.exs` and `workspace_and_config_test.exs`).

- [ ] **Step 2: Run static checks**

```bash
mix specs.check
mix credo --strict
```

Expected: no spec violations, no new credo issues. If credo flags style issues in the new tests, fix inline before moving on.

---

## Phase 2 — Live Linear + Local-Git e2e

### Task 2.1: Add E2EManifest support module

**Files:**
- Create: `test/support/manifest.exs`

- [ ] **Step 1: Write the module**

```elixir
defmodule SymphonyElixir.E2EManifest do
  @moduledoc """
  Append-only JSONL audit log for live e2e tests. One record per event.
  Stays valid mid-test; if a run aborts, the operator can `cat` the file
  and see exactly what was created.
  """

  @type event :: map()

  @doc """
  Opens a manifest at `path`. Returns the path. Truncates any prior file.
  """
  @spec open!(Path.t()) :: Path.t()
  def open!(path) when is_binary(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    path
  end

  @doc """
  Appends one event record. Adds an automatic `ts` field if missing.
  """
  @spec append!(Path.t(), event()) :: :ok
  def append!(path, %{} = event) when is_binary(path) do
    enriched = Map.put_new_lazy(event, :ts, fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)
    line = Jason.encode!(enriched) <> "\n"
    File.write!(path, line, [:append])
    :ok
  end

  @doc """
  Reads back the manifest as a list of decoded maps. Useful for assertions.
  """
  @spec read!(Path.t()) :: [event()]
  def read!(path) when is_binary(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
```

- [ ] **Step 2: Register the support file**

Edit `test/test_helper.exs` to add the new file:

```elixir
ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
Code.require_file("support/git_fixture.exs", __DIR__)
Code.require_file("support/github_forge_stub.exs", __DIR__)
Code.require_file("support/manifest.exs", __DIR__)
```

- [ ] **Step 3: Add the file to mix.exs's coverage exclusion**

Edit `mix.exs`'s `test_ignore_filters` list:

```elixir
test_ignore_filters: [
  "test/support/snapshot_support.exs",
  "test/support/test_support.exs",
  "test/support/git_fixture.exs",
  "test/support/github_forge_stub.exs",
  "test/support/manifest.exs"
],
```

- [ ] **Step 4: Smoke-test the module in iex**

```bash
iex -S mix
```

In iex:

```elixir
path = Path.join(System.tmp_dir!(), "manifest_test.jsonl")
SymphonyElixir.E2EManifest.open!(path)
SymphonyElixir.E2EManifest.append!(path, %{event: "setup", repo: "src"})
SymphonyElixir.E2EManifest.append!(path, %{event: "agent_dispatch", issue: "PES-A"})
SymphonyElixir.E2EManifest.read!(path) |> IO.inspect()
File.rm(path)
```

Expected output: list of two maps with `event`, `ts`, and the extra fields. Quit iex (`:q` Enter).

- [ ] **Step 5: Commit**

```bash
git add test/support/manifest.exs test/test_helper.exs mix.exs
git commit -m "test(support): add E2EManifest JSONL audit-log helper

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.2: Add MockAgent support module

**Files:**
- Create: `test/support/mock_agent.exs`

- [ ] **Step 1: Write the module**

```elixir
defmodule SymphonyElixir.MockAgent do
  @moduledoc """
  Deterministic stand-in for a real agent in live e2e tests. Performs the
  same observable side effects as a real Claude Code / Codex run:

  1. Creates `issue.branch_name` from `base_ref` in the local repo.
  2. Writes a deterministic file (or caller-supplied content for conflict
     scenarios), commits, pushes to origin.
  3. Records an OPEN PR in `Forge.GitHubStub`.
  4. Posts a workpad comment to real Linear (`## Agent Workpad\\n…`).
  5. Moves the Linear issue to `In Review`.

  All of this is what a real agent would do via `git push` + `gh pr create`
  + Linear MCP — but synchronous, deterministic, and free.
  """

  alias SymphonyElixir.Forge.GitHubStub
  alias SymphonyElixir.GitFixture
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Linear.Issue

  @type repo :: %{path: String.t(), bare_path: String.t(), gh_slug: String.t()}

  @type opts :: [
          file: String.t(),
          content: String.t(),
          in_review_state_id: String.t(),
          manifest_path: Path.t()
        ]

  @type result :: %{
          branch: String.t(),
          head_sha: String.t(),
          pr_number: pos_integer()
        }

  @doc """
  Dispatches one issue: creates branch, commits, pushes, opens stub PR,
  posts workpad comment, moves issue to In Review. Returns the artifacts.
  """
  @spec dispatch!(Issue.t(), String.t(), repo(), opts()) :: result()
  def dispatch!(%Issue{} = issue, base_ref, repo, opts) do
    file = Keyword.get(opts, :file, "#{issue.identifier}.txt")
    content = Keyword.get(opts, :content, "agent=#{issue.identifier};base=#{base_ref}\n")
    in_review_state_id = Keyword.fetch!(opts, :in_review_state_id)
    manifest_path = Keyword.get(opts, :manifest_path)

    branch = issue.branch_name || "feat/#{String.downcase(issue.identifier)}"

    # 1–2: branch off base_ref, commit, push.
    {_out, 0} = System.cmd("git", ["-C", repo.path, "fetch", "origin"], stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["-C", repo.path, "checkout", base_ref], stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["-C", repo.path, "checkout", "-B", branch], stderr_to_stdout: true)

    head_sha = GitFixture.commit_file(repo.path, file, content, "agent #{issue.identifier} writes #{file}")
    {_out, 0} = System.cmd("git", ["-C", repo.path, "push", "-u", "origin", branch], stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["-C", repo.path, "checkout", "main"], stderr_to_stdout: true)

    # 3: stub PR.
    pr_number = :erlang.unique_integer([:positive, :monotonic]) + 1000

    GitHubStub.set_pr({repo.gh_slug, branch}, %{
      number: pr_number,
      base: base_ref,
      head: branch,
      state: "OPEN",
      merged: false
    })

    # 4: workpad comment.
    workpad_body = "## Agent Workpad\nturn 1 done by MockAgent on #{branch}@#{head_sha}"
    post_comment!(issue.id, workpad_body)

    # 5: move to In Review.
    move_issue!(issue.id, in_review_state_id)

    if manifest_path do
      SymphonyElixir.E2EManifest.append!(manifest_path, %{
        event: "agent_dispatch",
        issue: issue.identifier,
        branch: branch,
        base: base_ref,
        head_sha: head_sha,
        pr_number: pr_number
      })
    end

    %{branch: branch, head_sha: head_sha, pr_number: pr_number}
  end

  defp post_comment!(issue_id, body) do
    mutation = """
    mutation MockAgentComment($issueId: String!, $body: String!) {
      commentCreate(input: {issueId: $issueId, body: $body}) { success }
    }
    """

    {:ok, _} = Client.graphql(mutation, %{issueId: issue_id, body: body})
    :ok
  end

  defp move_issue!(issue_id, state_id) do
    mutation = """
    mutation MockAgentSetState($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: {stateId: $stateId}) { success }
    }
    """

    {:ok, _} = Client.graphql(mutation, %{id: issue_id, stateId: state_id})
    :ok
  end
end
```

- [ ] **Step 2: Register the support file in test_helper.exs**

```elixir
Code.require_file("support/mock_agent.exs", __DIR__)
```

(Add the line after the `manifest.exs` require.)

- [ ] **Step 3: Add to mix.exs ignore filters**

```elixir
test_ignore_filters: [
  …existing entries…,
  "test/support/manifest.exs",
  "test/support/mock_agent.exs"
],
```

- [ ] **Step 4: Compile-check**

```bash
mix compile --warnings-as-errors
```

Expected: clean compile with no warnings.

- [ ] **Step 5: Commit**

```bash
git add test/support/mock_agent.exs test/test_helper.exs mix.exs
git commit -m "test(support): add MockAgent — deterministic stand-in for live e2e

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.3: Add FakeHuman support module

**Files:**
- Create: `test/support/fake_human.exs`

- [ ] **Step 1: Write the module**

```elixir
defmodule SymphonyElixir.FakeHuman do
  @moduledoc """
  Scripts reviewer actions in live e2e tests. All operations hit the real
  Linear GraphQL API; PR-side actions hit `Forge.GitHubStub`. Designed so
  the test author can write things like:

      FakeHuman.merge!(issue_a, repo, terminal_state_id: done_id)
      FakeHuman.rewind!(issue_x, todo_state_id)
      FakeHuman.request_changes!(issue_x, "fix the regex on line 42")
  """

  alias SymphonyElixir.Forge.GitHubStub
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Linear.Issue

  @type repo :: %{path: String.t(), bare_path: String.t(), gh_slug: String.t()}

  @doc """
  Marks the issue's PR merged in the stub, deletes the branch on origin,
  and moves the Linear issue to a terminal state.
  """
  @spec merge!(Issue.t(), repo(), keyword()) :: :ok
  def merge!(%Issue{} = issue, repo, opts) do
    terminal_state_id = Keyword.fetch!(opts, :terminal_state_id)
    manifest_path = Keyword.get(opts, :manifest_path)

    branch = issue.branch_name

    case GitHubStub.calls(:pr_for_branch) |> Enum.find(&match?({:pr_for_branch, {_, ^branch}}, &1)) do
      _ -> :ok
    end

    pr = pr_for_branch_from_stub(repo.gh_slug, branch)

    if pr do
      GitHubStub.set_pr({repo.gh_slug, branch}, %{pr | state: "MERGED", merged: true})
    end

    # Delete the branch from origin (simulates delete_branch_on_merge: true).
    {_out, _code} =
      System.cmd("git", ["-C", repo.path, "push", "origin", "--delete", branch], stderr_to_stdout: true)

    move_issue!(issue.id, terminal_state_id)

    if manifest_path do
      SymphonyElixir.E2EManifest.append!(manifest_path, %{
        event: "human_merge",
        issue: issue.identifier,
        branch: branch
      })
    end

    :ok
  end

  @doc """
  Moves the Linear issue back to the configured rework state (typically
  `Todo`). Used to simulate a reviewer rejecting the work.
  """
  @spec rewind!(Issue.t(), String.t(), keyword()) :: :ok
  def rewind!(%Issue{} = issue, todo_state_id, opts \\ []) do
    manifest_path = Keyword.get(opts, :manifest_path)
    move_issue!(issue.id, todo_state_id)

    if manifest_path do
      SymphonyElixir.E2EManifest.append!(manifest_path, %{
        event: "human_rewind",
        issue: issue.identifier
      })
    end

    :ok
  end

  @doc """
  Posts a Linear comment on `issue` with `body`. Sleeps briefly first so
  the comment's `created_at` is reliably newer than any prior workpad
  timestamp (Linear's resolution is per-second).
  """
  @spec request_changes!(Issue.t(), String.t(), keyword()) :: :ok
  def request_changes!(%Issue{} = issue, body, opts \\ []) do
    manifest_path = Keyword.get(opts, :manifest_path)
    Process.sleep(1_500)

    mutation = """
    mutation FakeHumanComment($issueId: String!, $body: String!) {
      commentCreate(input: {issueId: $issueId, body: $body}) { success }
    }
    """

    {:ok, _} = Client.graphql(mutation, %{issueId: issue.id, body: body})

    if manifest_path do
      SymphonyElixir.E2EManifest.append!(manifest_path, %{
        event: "human_request_changes",
        issue: issue.identifier,
        comment_preview: String.slice(body, 0, 80)
      })
    end

    :ok
  end

  defp move_issue!(issue_id, state_id) do
    mutation = """
    mutation FakeHumanSetState($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: {stateId: $stateId}) { success }
    }
    """

    {:ok, _} = Client.graphql(mutation, %{id: issue_id, stateId: state_id})
    :ok
  end

  defp pr_for_branch_from_stub(repo, branch) do
    {:ok, pr} = SymphonyElixir.Forge.GitHubStub.pr_for_branch(repo, branch)
    pr
  end
end
```

- [ ] **Step 2: Register and ignore-list the file**

In `test/test_helper.exs`:

```elixir
Code.require_file("support/fake_human.exs", __DIR__)
```

In `mix.exs`'s `test_ignore_filters`, add:

```elixir
"test/support/fake_human.exs"
```

- [ ] **Step 3: Compile-check**

```bash
mix compile --warnings-as-errors
```

Expected: clean compile.

- [ ] **Step 4: Commit**

```bash
git add test/support/fake_human.exs test/test_helper.exs mix.exs
git commit -m "test(support): add FakeHuman — scripted reviewer actions for live e2e

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.4: Scaffold the live e2e test module

**Files:**
- Create: `test/symphony_elixir/live_stacking_e2e_test.exs`

- [ ] **Step 1: Create the module skeleton with setup, teardown, and one trivial test**

```elixir
defmodule SymphonyElixir.LiveStackingE2ETest do
  @moduledoc """
  Live end-to-end test for the multi-repo + dependency-stacking pipeline.

  - Real Linear: creates a project + four issues, drives state transitions
    via the real GraphQL API.
  - Local Git only: bare + working clones in tmp_dir act as origin.
  - Forge.GitHubStub stands in for the GitHub PR API.
  - SymphonyElixir.MockAgent plays the agent's role (deterministic commits).
  - SymphonyElixir.FakeHuman plays the reviewer.

  Gated behind SYMPHONY_RUN_LIVE_STACKING_E2E=1. Default `mix test` skips it.
  """

  use ExUnit.Case, async: false

  require Logger

  alias SymphonyElixir.Branches.{BaseResolver, ConflictFallback, IntegrationBuilder, Reconciler}
  alias SymphonyElixir.Deps.Cascade
  alias SymphonyElixir.E2EManifest
  alias SymphonyElixir.FakeHuman
  alias SymphonyElixir.Forge.GitHubStub
  alias SymphonyElixir.GitFixture
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.MockAgent

  @moduletag :live_stacking_e2e
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @default_team_key "SYME2E"
  @gh_slug "acme/src"

  @skip_reason if(System.get_env("SYMPHONY_RUN_LIVE_STACKING_E2E") != "1",
                  do: "set SYMPHONY_RUN_LIVE_STACKING_E2E=1 to enable live Linear + local-Git stacking e2e")

  @team_query """
  query StackingE2ETeam($key: String!) {
    teams(filter: {key: {eq: $key}}, first: 1) {
      nodes {
        id
        key
        states(first: 50) { nodes { id name type } }
      }
    }
  }
  """

  @create_project_mutation """
  mutation StackingE2ECreateProject($name: String!, $teamIds: [String!]!) {
    projectCreate(input: {name: $name, teamIds: $teamIds}) {
      success
      project { id name slugId url }
    }
  }
  """

  @create_issue_mutation """
  mutation StackingE2ECreateIssue(
    $teamId: String!, $projectId: String!, $title: String!,
    $description: String!, $stateId: String, $labelIds: [String!]) {
    issueCreate(input: {
      teamId: $teamId, projectId: $projectId, title: $title,
      description: $description, stateId: $stateId, labelIds: $labelIds
    }) {
      success
      issue { id identifier title url state { name } branchName }
    }
  }
  """

  @issue_relation_mutation """
  mutation StackingE2ECreateRelation($issueId: String!, $relatedIssueId: String!) {
    issueRelationCreate(input: {issueId: $issueId, relatedIssueId: $relatedIssueId, type: blocks}) {
      success
    }
  }
  """

  @project_statuses_query """
  query StackingE2EProjectStatuses {
    projectStatuses(first: 50) { nodes { id name type } }
  }
  """

  @complete_project_mutation """
  mutation StackingE2ECompleteProject($id: String!, $statusId: String!, $completedAt: DateTime!) {
    projectUpdate(id: $id, input: {statusId: $statusId, completedAt: $completedAt}) { success }
  }
  """

  @issue_state_query """
  query StackingE2EIssueState($id: String!) {
    issue(id: $id) { id state { name type } }
  }
  """

  setup %{tmp_dir: tmp} do
    if @skip_reason, do: :ok, else: setup_live(tmp)
  end

  defp setup_live(tmp) do
    cleanup_stub = GitHubStub.install()
    manifest_path = Path.join(tmp, "LIVE_STACKING_E2E_MANIFEST.jsonl")
    E2EManifest.open!(manifest_path)

    # Local repo provisioning.
    bare = GitFixture.bare_repo(tmp, "src.git")
    work = GitFixture.working_clone(bare, tmp, "src")
    repo = %{path: work, bare_path: bare, gh_slug: @gh_slug, handle: "src", remote: "origin", default_base: "main"}

    on_exit(fn ->
      cleanup_stub.()
      Logger.info("LIVE_STACKING_E2E manifest: #{manifest_path}")
    end)

    {:ok, tmp: tmp, manifest_path: manifest_path, repo: repo}
  end

  @tag skip: @skip_reason
  test "live stacking pipeline against real Linear and local Git", %{
    tmp: tmp,
    manifest_path: manifest_path,
    repo: repo
  } do
    # This skeleton just confirms setup runs. Scenarios A–E land in subsequent tasks.
    assert is_binary(manifest_path)
    assert File.exists?(manifest_path)
    assert File.exists?(repo.path)
    assert File.exists?(repo.bare_path)
    _ = tmp
    :ok
  end
end
```

- [ ] **Step 2: Verify the test is properly skipped without env**

```bash
mix test test/symphony_elixir/live_stacking_e2e_test.exs
```

Expected: `1 test, 0 failures, 1 skipped` (or similar, depending on ExUnit version output).

- [ ] **Step 3: Verify the test runs (and passes the skeleton) with env**

```bash
SYMPHONY_RUN_LIVE_STACKING_E2E=1 LINEAR_API_KEY=$LINEAR_API_KEY \
  mix test test/symphony_elixir/live_stacking_e2e_test.exs
```

Expected: 1 test passes. (No real Linear calls happen yet — the skeleton only runs setup.)

- [ ] **Step 4: Commit**

```bash
git add test/symphony_elixir/live_stacking_e2e_test.exs
git commit -m "test(stacking): scaffold LiveStackingE2ETest with setup + skip gate

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.5: Provision the Linear project + four issues in setup

**Files:**
- Modify: `test/symphony_elixir/live_stacking_e2e_test.exs`

- [ ] **Step 1: Add helpers and Linear-resource creation**

Append after the GraphQL constants:

```elixir
  defp graphql!(query, vars \\ %{}) do
    case Client.graphql(query, vars) do
      {:ok, %{"data" => data}} when is_map(data) -> data
      {:ok, payload} -> flunk("Linear graphql unexpected payload: #{inspect(payload)}")
      {:error, reason} -> flunk("Linear graphql error: #{inspect(reason)}")
    end
  end

  defp fetch_team! do
    key = System.get_env("SYMPHONY_LIVE_LINEAR_TEAM_KEY") || @default_team_key
    nodes = graphql!(@team_query, %{key: key}) |> get_in(["teams", "nodes"]) || []

    case nodes do
      [team | _] -> team
      [] -> flunk("Linear team #{inspect(key)} not found. Create it or set SYMPHONY_LIVE_LINEAR_TEAM_KEY.")
    end
  end

  defp pick_state!(team, type) do
    states = team["states"]["nodes"] || []

    case Enum.find(states, &(&1["type"] == type)) do
      %{} = state -> state
      nil -> flunk("Team #{team["key"]} has no state of type #{inspect(type)}; needed for live e2e.")
    end
  end

  defp create_project!(team_id, name) do
    data = graphql!(@create_project_mutation, %{teamIds: [team_id], name: name})
    %{"projectCreate" => %{"success" => true, "project" => project}} = data
    project
  end

  defp create_issue!(team_id, project_id, state_id, title, branch_name) do
    data =
      graphql!(@create_issue_mutation, %{
        teamId: team_id,
        projectId: project_id,
        title: title,
        description: "Live stacking e2e: #{title}",
        stateId: state_id,
        labelIds: []
      })

    %{"issueCreate" => %{"success" => true, "issue" => issue}} = data

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      url: issue["url"],
      branch_name: branch_name,
      state: get_in(issue, ["state", "name"]),
      labels: ["repo:src", "AFK"],
      blocked_by: []
    }
  end

  defp link_blocker!(dependent_id, blocker_id) do
    data = graphql!(@issue_relation_mutation, %{issueId: dependent_id, relatedIssueId: blocker_id})
    %{"issueRelationCreate" => %{"success" => true}} = data
    :ok
  end

  defp completed_project_status_id! do
    nodes = graphql!(@project_statuses_query) |> get_in(["projectStatuses", "nodes"]) || []
    %{"id" => id} = Enum.find(nodes, &(&1["type"] == "completed")) || flunk("no completed project status")
    id
  end

  defp issue_state_type!(issue_id) do
    data = graphql!(@issue_state_query, %{id: issue_id})
    get_in(data, ["issue", "state", "type"])
  end

  defp complete_project_safe(project_id, status_id) do
    iso = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Client.graphql(@complete_project_mutation, %{
           id: project_id,
           statusId: status_id,
           completedAt: iso
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("project complete failed: #{inspect(reason)}")
    end
  end
```

- [ ] **Step 2: Extend setup to create the Linear resources**

Replace the `setup_live/1` function with:

```elixir
  defp setup_live(tmp) do
    cleanup_stub = GitHubStub.install()
    manifest_path = Path.join(tmp, "LIVE_STACKING_E2E_MANIFEST.jsonl")
    E2EManifest.open!(manifest_path)

    bare = GitFixture.bare_repo(tmp, "src.git")
    work = GitFixture.working_clone(bare, tmp, "src")
    repo = %{path: work, bare_path: bare, gh_slug: @gh_slug, handle: "src", remote: "origin", default_base: "main"}

    team = fetch_team!()
    todo_state = pick_state!(team, "unstarted")
    in_review_state = pick_state!(team, "started")
    done_state = pick_state!(team, "completed")
    completed_project_status_id = completed_project_status_id!()

    project_name = "Symphony Stacking E2E #{System.unique_integer([:positive])}"
    project = create_project!(team["id"], project_name)

    a = create_issue!(team["id"], project["id"], todo_state["id"], "stacking-e2e A", "feat/stacking-a")
    b = create_issue!(team["id"], project["id"], todo_state["id"], "stacking-e2e B", "feat/stacking-b")
    x = create_issue!(team["id"], project["id"], todo_state["id"], "stacking-e2e X", "feat/stacking-x")
    y = create_issue!(team["id"], project["id"], todo_state["id"], "stacking-e2e Y", "feat/stacking-y")

    :ok = link_blocker!(x.id, a.id)
    :ok = link_blocker!(x.id, b.id)
    :ok = link_blocker!(y.id, a.id)

    # Refresh blocked_by on the structs so downstream code sees the relationships.
    a = a
    b = b
    x = %{x | blocked_by: [
            %{id: a.id, identifier: a.identifier, state: "Todo"},
            %{id: b.id, identifier: b.identifier, state: "Todo"}
          ]}
    y = %{y | blocked_by: [%{id: a.id, identifier: a.identifier, state: "Todo"}]}

    E2EManifest.append!(manifest_path, %{
      event: "setup",
      linear: %{
        team_id: team["id"],
        team_key: team["key"],
        project_id: project["id"],
        project_url: project["url"]
      },
      issues: %{
        a: %{id: a.id, identifier: a.identifier, url: a.url},
        b: %{id: b.id, identifier: b.identifier, url: b.url},
        x: %{id: x.id, identifier: x.identifier, url: x.url},
        y: %{id: y.id, identifier: y.identifier, url: y.url}
      },
      repo: %{bare_path: repo.bare_path, work_path: repo.path}
    })

    on_exit(fn ->
      cleanup_stub.()
      complete_project_safe(project["id"], completed_project_status_id)
      Logger.info("LIVE_STACKING_E2E manifest: #{manifest_path}")
    end)

    {:ok,
     tmp: tmp,
     manifest_path: manifest_path,
     repo: repo,
     issues: %{a: a, b: b, x: x, y: y},
     state_ids: %{todo: todo_state["id"], in_review: in_review_state["id"], done: done_state["id"]}}
  end
```

- [ ] **Step 3: Update the placeholder test to assert on the new context**

Replace the test body with:

```elixir
  @tag skip: @skip_reason
  test "live stacking pipeline against real Linear and local Git", %{
    manifest_path: manifest_path,
    repo: repo,
    issues: issues,
    state_ids: _state_ids
  } do
    assert File.exists?(manifest_path)
    assert File.exists?(repo.path)

    # Confirm the four issues exist in Linear.
    for {key, issue} <- issues do
      assert is_binary(issue.id), "expected #{key} to have a Linear id"
      assert issue.identifier =~ ~r/[A-Z]+-\d+/
    end

    [setup_event | _] = E2EManifest.read!(manifest_path)
    assert setup_event["event"] == "setup"
  end
```

- [ ] **Step 4: Run with env set**

```bash
SYMPHONY_RUN_LIVE_STACKING_E2E=1 LINEAR_API_KEY=$LINEAR_API_KEY \
  mix test test/symphony_elixir/live_stacking_e2e_test.exs
```

Expected: 1 test, 1 pass. Linear should now have a fresh project with four issues; the `after` block completes it. Read the manifest:

```bash
cat /tmp/$(ls /tmp | grep tmp | tail -1)/LIVE_STACKING_E2E_MANIFEST.jsonl
```

Confirm the setup record has all four issue identifiers and the project URL. (ExUnit's `:tmp_dir` lives under `/tmp` on macOS; the on_exit log line also prints the manifest path.)

- [ ] **Step 5: Commit**

```bash
git add test/symphony_elixir/live_stacking_e2e_test.exs
git commit -m "test(stacking): provision Linear project + four issues in live e2e setup

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.6: Scenario A — Stacked dispatch

**Files:**
- Modify: `test/symphony_elixir/live_stacking_e2e_test.exs`

- [ ] **Step 1: Replace the placeholder test with scenario A**

```elixir
  @tag skip: @skip_reason
  test "live stacking pipeline against real Linear and local Git", %{
    manifest_path: manifest_path,
    repo: repo,
    issues: issues,
    state_ids: state_ids
  } do
    cfg = settings(repo)

    # ---- Scenario A: stacked dispatch ----
    # MockAgent dispatches A against main.
    a_result =
      MockAgent.dispatch!(issues.a, "main", repo,
        in_review_state_id: state_ids.in_review,
        manifest_path: manifest_path
      )

    assert a_result.branch == issues.a.branch_name

    # Refresh A from Linear so we see In Review.
    a_in_review = %{issues.a | state: "In Review"}

    # Y has only A as a blocker → resolves to single_blocker on feat/stacking-a.
    y_for_resolve = issues.y

    assert {:ok, {:single_blocker, base_for_y}} =
             BaseResolver.resolve(y_for_resolve, [a_in_review], cfg)

    assert base_for_y == issues.a.branch_name

    # MockAgent dispatches Y against A's branch.
    y_result =
      MockAgent.dispatch!(issues.y, base_for_y, repo,
        in_review_state_id: state_ids.in_review,
        manifest_path: manifest_path
      )

    assert y_result.branch == issues.y.branch_name

    # Verify the stub PR for Y has base = A's branch.
    {:ok, y_pr} = GitHubStub.pr_for_branch(repo.gh_slug, issues.y.branch_name)
    assert y_pr.base == issues.a.branch_name
    assert y_pr.state == "OPEN"

    # X is NOT dispatched — it has B as a second blocker still in Todo.
    {:ok, x_pr} = GitHubStub.pr_for_branch(repo.gh_slug, issues.x.branch_name)
    assert x_pr == nil
  end

  defp settings(repo) do
    %{
      stacking: %{
        enabled: true,
        unblock_states: ["In Review", "Done"],
        integration_branch_template: "symphony/integration/{{ issue.identifier | downcase }}",
        rework_state: "Todo"
      },
      agent_autonomy: %{
        label_dispatchable: "AFK",
        label_human_only: "HITL",
        default_when_missing: "HITL"
      },
      tracker: %{active_states: ["Todo", "In Progress", "In Review"], terminal_states: ["Done"]},
      repositories: %{
        default: "src",
        by_label: %{"repo:src" => "src"},
        paths: %{"src" => repo.path},
        remote: "origin",
        default_base_branch: "main"
      }
    }
  end
```

- [ ] **Step 2: Run with env set**

```bash
SYMPHONY_RUN_LIVE_STACKING_E2E=1 LINEAR_API_KEY=$LINEAR_API_KEY \
  mix test test/symphony_elixir/live_stacking_e2e_test.exs
```

Expected: PASS. Linear now has A and Y in `In Review`. Manifest contains two `agent_dispatch` events.

- [ ] **Step 3: Commit**

```bash
git add test/symphony_elixir/live_stacking_e2e_test.exs
git commit -m "test(stacking): scenario A — stacked dispatch (Y opens against A's branch)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.7: Scenario B — Retarget on merge

**Files:**
- Modify: `test/symphony_elixir/live_stacking_e2e_test.exs`

- [ ] **Step 1: Append scenario B inside the test function, after the existing assertions**

Add after the scenario-A assertions (before the closing `end` of the test):

```elixir
    # ---- Scenario B: retarget on merge ----
    FakeHuman.merge!(issues.a, repo,
      terminal_state_id: state_ids.done,
      manifest_path: manifest_path
    )

    # Run reconciler with forge_repos so it routes PRs.
    a_done = %{issues.a | state: "Done"}
    y_in_review = %{issues.y | state: "In Review"}

    # Refresh blocker references on Y so reconciler sees A as Done.
    y_in_review = %{
      y_in_review
      | blocked_by: [%{id: issues.a.id, identifier: issues.a.identifier, state: "Done"}]
    }

    {:ok, _events} =
      Reconciler.run([y_in_review], [a_done], cfg, forge_repos: %{"src" => repo.gh_slug})

    # Stub recorded a retarget for Y → main.
    retarget_calls = GitHubStub.calls(:retarget_pr)
    assert Enum.any?(retarget_calls, &match?({:retarget_pr, {_, _, "main"}}, &1))
```

- [ ] **Step 2: Run**

```bash
SYMPHONY_RUN_LIVE_STACKING_E2E=1 LINEAR_API_KEY=$LINEAR_API_KEY \
  mix test test/symphony_elixir/live_stacking_e2e_test.exs
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/symphony_elixir/live_stacking_e2e_test.exs
git commit -m "test(stacking): scenario B — retarget Y to main after A merges

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.8: Scenario C — Cascade rewind

**Files:**
- Modify: `test/symphony_elixir/live_stacking_e2e_test.exs`

- [ ] **Step 1: Append scenario C after scenario B**

```elixir
    # ---- Scenario C: cascade rewind ----
    # Restore Y's blocked_by reference so reconciler sees the rewind.
    FakeHuman.rewind!(issues.a, state_ids.todo, manifest_path: manifest_path)

    a_rewound = %{issues.a | state: "Todo"}
    y_in_review_after_rewind = %{
      y_in_review
      | blocked_by: [%{id: issues.a.id, identifier: issues.a.identifier, state: "Todo"}]
    }

    # Tick 1: prime previous-state (A was Done before).
    {:ok, _} = Reconciler.run([y_in_review], [a_done], cfg)

    # Tick 2: A is now Todo → cascade event for Y.
    {:ok, e2} = Reconciler.run([y_in_review_after_rewind], [a_rewound], cfg)
    assert {:cascade_pending, _y_id, _a_id} = Enum.find(e2, &match?({:cascade_pending, _, _}, &1))

    cascades = Reconciler.drain_cascades()

    issues_by_id = %{issues.y.id => y_in_review_after_rewind, issues.a.id => a_rewound}

    parent = self()

    apply_fn = fn identifier, _new_state ->
      send(parent, {:linear_state, identifier, "Todo"})

      # Use FakeHuman to actually move on Linear.
      issue = if identifier == issues.y.identifier, do: issues.y, else: nil

      if issue, do: FakeHuman.rewind!(issue, state_ids.todo, manifest_path: manifest_path)

      :ok
    end

    comment_fn = fn _identifier, _body -> :ok end
    lookup = fn id -> Map.fetch(issues_by_id, id) end

    decisions = Cascade.apply_cascades(cascades, lookup, apply_fn, comment_fn)
    assert Enum.any?(decisions, &match?({:rewind, _, _}, &1))

    assert_receive {:linear_state, _, "Todo"}, 5_000

    # Verify Linear actually has Y in an unstarted state now.
    assert issue_state_type!(issues.y.id) == "unstarted"
```

- [ ] **Step 2: Run**

```bash
SYMPHONY_RUN_LIVE_STACKING_E2E=1 LINEAR_API_KEY=$LINEAR_API_KEY \
  mix test test/symphony_elixir/live_stacking_e2e_test.exs
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/symphony_elixir/live_stacking_e2e_test.exs
git commit -m "test(stacking): scenario C — cascade rewinds Y when A returns to Todo

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.9: Scenario D — Feedback loop

**Files:**
- Modify: `test/symphony_elixir/live_stacking_e2e_test.exs`

- [ ] **Step 1: Append scenario D**

```elixir
    # ---- Scenario D: feedback loop ----
    # Re-merge A (move it back through In Review then Done).
    FakeHuman.rewind!(issues.a, state_ids.in_review, manifest_path: manifest_path)
    FakeHuman.merge!(issues.a, repo,
      terminal_state_id: state_ids.done,
      manifest_path: manifest_path
    )

    # Re-dispatch Y against main now that A is Done.
    _y_redispatch =
      MockAgent.dispatch!(issues.y, "main", repo,
        in_review_state_id: state_ids.in_review,
        manifest_path: manifest_path
      )

    # Reviewer requests changes on Y.
    FakeHuman.request_changes!(issues.y, "fix the regex on line 42 — empty inputs explode",
      manifest_path: manifest_path
    )

    # Fetch Y's fresh comments from Linear and run the detector.
    fresh_comments_query = """
    query FreshComments($id: String!) {
      issue(id: $id) {
        comments(first: 50) {
          nodes { id body createdAt updatedAt user { id name displayName } }
        }
      }
    }
    """

    data = graphql!(fresh_comments_query, %{id: issues.y.id})
    comments_raw = get_in(data, ["issue", "comments", "nodes"]) || []

    comments =
      Enum.map(comments_raw, fn c ->
        %{
          id: c["id"],
          body: c["body"],
          created_at: parse_iso(c["createdAt"]),
          updated_at: parse_iso(c["updatedAt"]),
          user_id: get_in(c, ["user", "id"]),
          user_name: get_in(c, ["user", "name"]) || get_in(c, ["user", "displayName"])
        }
      end)

    y_with_comments = %{issues.y | state: "In Review", comments: comments}

    assert {:feedback, [_ | _] = feedback} =
             SymphonyElixir.Feedback.Detector.evaluate(y_with_comments)

    assert Enum.any?(feedback, &(&1.body =~ "regex"))

    # Apply the rework: move Y back to Todo on Linear.
    FakeHuman.rewind!(issues.y, state_ids.todo, manifest_path: manifest_path)
    assert issue_state_type!(issues.y.id) == "unstarted"
```

Add the `parse_iso/1` helper near the other private helpers:

```elixir
  defp parse_iso(nil), do: nil

  defp parse_iso(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
```

- [ ] **Step 2: Run**

```bash
SYMPHONY_RUN_LIVE_STACKING_E2E=1 LINEAR_API_KEY=$LINEAR_API_KEY \
  mix test test/symphony_elixir/live_stacking_e2e_test.exs
```

Expected: PASS. Note: this scenario sleeps ~1.5s in `FakeHuman.request_changes!` to ensure the new comment's timestamp beats the workpad's.

- [ ] **Step 3: Commit**

```bash
git add test/symphony_elixir/live_stacking_e2e_test.exs
git commit -m "test(stacking): scenario D — feedback loop reroutes Y to Todo

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.10: Scenario E — Conflict integration

**Files:**
- Modify: `test/symphony_elixir/live_stacking_e2e_test.exs`

- [ ] **Step 1: Append scenario E**

```elixir
    # ---- Scenario E: conflict integration ----
    # Re-dispatch A with a conflicting commit on shared.txt.
    FakeHuman.rewind!(issues.a, state_ids.todo, manifest_path: manifest_path)

    MockAgent.dispatch!(issues.a, "main", repo,
      in_review_state_id: state_ids.in_review,
      file: "shared.txt",
      content: "from A\n",
      manifest_path: manifest_path
    )

    MockAgent.dispatch!(issues.b, "main", repo,
      in_review_state_id: state_ids.in_review,
      file: "shared.txt",
      content: "from B\n",
      manifest_path: manifest_path
    )

    a_in_review_e = %{issues.a | state: "In Review"}
    b_in_review_e = %{issues.b | state: "In Review"}

    x_for_resolve =
      %{
        issues.x
        | blocked_by: [
            %{id: issues.a.id, identifier: issues.a.identifier, state: "In Review"},
            %{id: issues.b.id, identifier: issues.b.identifier, state: "In Review"}
          ]
      }

    integration_branch =
      "symphony/integration/" <> String.downcase(issues.x.identifier)

    assert {:ok, {:integration, ^integration_branch}} =
             BaseResolver.resolve(x_for_resolve, [a_in_review_e, b_in_review_e], cfg)

    repo_for_builder = %{
      handle: "src",
      path: repo.path,
      remote: "origin",
      default_base: "main"
    }

    assert {:conflict, files} =
             IntegrationBuilder.rebuild(
               repo_for_builder,
               integration_branch,
               [issues.a.branch_name, issues.b.branch_name]
             )

    assert "shared.txt" in files

    ctx = %{
      files: files,
      blocker_branches: [issues.a.branch_name, issues.b.branch_name],
      blocker_shas: %{}
    }

    assert :new = ConflictFallback.mark_conflict(issues.x.id, ctx)

    ws = Path.join(Path.dirname(repo.path), "ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)

    assert {:ok, %{path: prepared_path}} =
             ConflictFallback.prepare_worktree(
               repo_for_builder,
               issues.x.identifier,
               issues.x.branch_name,
               [issues.a.branch_name, issues.b.branch_name],
               workspace_root: ws,
               fetch: true
             )

    {status, 0} = System.cmd("git", ["-C", prepared_path, "status", "--porcelain"], stderr_to_stdout: true)
    assert status =~ "shared.txt"

    E2EManifest.append!(manifest_path, %{
      event: "conflict_fallback_prepared",
      issue: issues.x.identifier,
      worktree: prepared_path,
      conflict_files: files
    })
```

- [ ] **Step 2: Run**

```bash
SYMPHONY_RUN_LIVE_STACKING_E2E=1 LINEAR_API_KEY=$LINEAR_API_KEY \
  mix test test/symphony_elixir/live_stacking_e2e_test.exs
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/symphony_elixir/live_stacking_e2e_test.exs
git commit -m "test(stacking): scenario E — conflict integration falls back to in-tree merge

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.11: Manifest verification at end of test

**Files:**
- Modify: `test/symphony_elixir/live_stacking_e2e_test.exs`

- [ ] **Step 1: Add a final manifest sanity check**

Append before the closing `end` of the test function:

```elixir
    # ---- Final manifest sanity ----
    records = E2EManifest.read!(manifest_path)
    events = Enum.map(records, & &1["event"])

    for required <- ["setup", "agent_dispatch", "human_merge", "human_rewind", "human_request_changes", "conflict_fallback_prepared"] do
      assert required in events, "manifest missing #{required}"
    end

    Logger.info("manifest path: #{manifest_path}")
```

- [ ] **Step 2: Run the whole test once more**

```bash
SYMPHONY_RUN_LIVE_STACKING_E2E=1 LINEAR_API_KEY=$LINEAR_API_KEY \
  mix test test/symphony_elixir/live_stacking_e2e_test.exs
```

Expected: PASS. The log output should print the manifest path. Open it and confirm every event appears at least once:

```bash
cat <printed-path>
```

- [ ] **Step 3: Commit**

```bash
git add test/symphony_elixir/live_stacking_e2e_test.exs
git commit -m "test(stacking): assert manifest contains every expected event class

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.12: Operator runbook

**Files:**
- Create: `docs/operators/testing-stacking-locally.md`

- [ ] **Step 1: Write the runbook**

```markdown
# Testing the Stacking Pipeline Locally

This repo ships two layers of tests for the multi-repo + dependency
stacking pipeline. Use this guide to pick the right one for what you're
verifying.

## Layer 1: plumbing (fast, deterministic)

`test/symphony_elixir/stacking_pipeline_test.exs` covers all the routing,
base-resolution, integration-build, conflict-fallback, cascade, feedback,
and post-deploy-mediation logic against local bare repos and an
in-memory forge stub. No real Linear, no real GitHub.

```bash
mix test test/symphony_elixir/stacking_pipeline_test.exs
```

Run this every time you touch `BaseResolver`, `DispatchGuard`,
`IntegrationBuilder`, `ConflictFallback`, `Reconciler`, `Rebaser`,
`PR.Router`, `Cascade`, or `Feedback.Detector`.

## Layer 2: live Linear + local git (slow, real Linear, deterministic agent)

`test/symphony_elixir/live_stacking_e2e_test.exs` creates a real Linear
project + four issues, provisions local bare/working git repos,
substitutes a deterministic `MockAgent` for the real LLM agent, and
scripts reviewer actions through Linear's real GraphQL API.

### Required env

| Variable | Purpose |
| --- | --- |
| `SYMPHONY_RUN_LIVE_STACKING_E2E=1` | Opt in. Default `mix test` skips the test. |
| `LINEAR_API_KEY` | Linear personal API key. Same one the orchestrator uses. |
| `SYMPHONY_LIVE_LINEAR_TEAM_KEY` (optional) | Default `SYME2E`. Override if your test team uses a different key. |

### Run

```bash
SYMPHONY_RUN_LIVE_STACKING_E2E=1 \
  LINEAR_API_KEY=lin_api_… \
  mix test test/symphony_elixir/live_stacking_e2e_test.exs
```

The test takes ~30–60 seconds. Most of that is sequential Linear API
roundtrips.

### What it creates in your Linear workspace

- One project named `Symphony Stacking E2E <run-id>`.
- Four issues in that project: `…-A`, `…-B`, `…-X`, `…-Y` with stacking
  relationships (`X.blockedBy = [A, B]`, `Y.blockedBy = [A]`).

The test cleans up by moving the project to a `completed`-type status in
its `after` block. Issues stay attached to the project but won't show up
in active-state queries because the project itself is completed.

If the test crashes mid-run, complete the project manually in the Linear
UI to stop it cluttering candidate fetches.

### The manifest

Every artifact the test creates is recorded in
`<tmp_dir>/LIVE_STACKING_E2E_MANIFEST.jsonl`. The path is logged at the
end of the test (Logger.info "manifest path: …"). Each line is one
event:

```jsonl
{"event":"setup","linear":{"team_id":"…","project_id":"…","project_url":"…"},"issues":{…},"repo":{…},"ts":"…"}
{"event":"agent_dispatch","issue":"SYME2E-101","branch":"feat/stacking-a","base":"main","head_sha":"abc1234","pr_number":1042,"ts":"…"}
{"event":"human_merge","issue":"SYME2E-101","branch":"feat/stacking-a","ts":"…"}
…
```

Read it to deduce exactly what the test touched. Useful when:
- Linear has unexpected residue and you want to clean up by hand.
- Debugging a flaky scenario — the manifest shows the order of operations.
- Verifying the test exercised every scenario you cared about.

### Adding scenarios

`MockAgent.dispatch!/4` is the place to add new agent-side behaviors.
`FakeHuman` is the place to add new reviewer actions. Both write to
the manifest when given `manifest_path:` so the audit log stays
complete. New scenarios should append assertions inside the same
`test "..."` function so they share the live Linear project.
```

- [ ] **Step 2: Commit**

```bash
git add docs/operators/testing-stacking-locally.md
git commit -m "docs(operators): runbook for stacking pipeline test layers

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.13: Final gate — full suite + lint

**Files:** none

- [ ] **Step 1: Run the full default test suite (live test must skip)**

```bash
mix test
```

Expected: every test passes (modulo two pre-existing flakes in `core_test.exs` and `workspace_and_config_test.exs`). The live e2e test must report as skipped, not run.

- [ ] **Step 2: Run static checks**

```bash
mix specs.check
mix credo --strict
```

Expected: no spec violations, no new credo warnings on the new files.

- [ ] **Step 3: Run the live e2e once end-to-end**

```bash
SYMPHONY_RUN_LIVE_STACKING_E2E=1 LINEAR_API_KEY=$LINEAR_API_KEY \
  mix test test/symphony_elixir/live_stacking_e2e_test.exs
```

Expected: 1 test, 1 pass. Read the manifest at the path printed in the
log and confirm every scenario class is present. Check Linear: the test
project should be in a completed state, not active.

- [ ] **Step 4: If everything is green, the harness is done.**

No commit needed for this checkpoint — it's a verification gate.

---

## Self-Review

After writing this plan, the spec sections map to tasks as follows:

- **Phase 1 scenario 1** (3-blocker collapse) → Task 1.1.
- **Phase 1 scenario 2** (post-deploy clean rebase) → Task 1.2.
- **Phase 1 scenario 3** (post-deploy rebase conflict) → Task 1.3.
- **Phase 1 scenario 4** (branch drift; spec said "retry once" but code doesn't — plan tests current single-attempt behavior) → Task 1.4.
- **Phase 1 scenario 5** (feedback loop trigger) → Task 1.5.
- **Phase 1 scenario 6** (cascade chain) → Task 1.6.
- **Phase 1 scenario 7** (re-dispatch preserves branch_name) → Task 1.7.
- **Phase 1 scenario 8** (blocker branch missing) → Task 1.8.
- **Phase 2 scenario A** (stacked dispatch) → Task 2.6.
- **Phase 2 scenario B** (retarget on merge) → Task 2.7.
- **Phase 2 scenario C** (cascade rewind) → Task 2.8.
- **Phase 2 scenario D** (feedback loop) → Task 2.9.
- **Phase 2 scenario E** (conflict integration) → Task 2.10.
- **Phase 2 manifest** → Task 2.1 (module) + Task 2.11 (verification).
- **Phase 2 MockAgent** → Task 2.2.
- **Phase 2 FakeHuman** → Task 2.3.
- **Phase 2 setup/teardown** → Tasks 2.4, 2.5.
- **Operator runbook** → Task 2.12.

Coverage looks complete. The one place the plan diverges from the spec is scenario #4: the spec assumed retry logic exists; code inspection showed it doesn't, so the plan tests the actual `{:error, :push_failed}` behavior instead. That's noted at the top.
