defmodule SymphonyElixir.StackingPipelineTest do
  @moduledoc """
  End-to-end Layer-4 tests for the stacking pipeline. Each scenario composes
  the modules built across A1–E2 and asserts behavior at the seam between
  decision logic (BaseResolver, DispatchGuard, Cascade) and side-effect
  drivers (Reconciler, IntegrationBuilder, PR.Router) using:

  - `SymphonyElixir.GitFixture` for real bare + working clones (A3).
  - `SymphonyElixir.Forge.GitHubStub` for in-process forge calls (D2).
  - Plain Elixir for mocked Linear state (no real Linear API).

  These tests don't stand up the Orchestrator GenServer — that's the
  existing test layer. F1 covers the *new* stacking-specific pipeline at
  module-composition level, which is where the design-doc bugs would live.
  """

  use ExUnit.Case, async: false

  alias SymphonyElixir.Branches.{ConflictFallback, IntegrationBuilder, Rebaser, Reconciler}
  alias SymphonyElixir.Branches.BaseResolver
  alias SymphonyElixir.Deps.{Cascade, DispatchGuard}
  alias SymphonyElixir.Forge.GitHubStub
  alias SymphonyElixir.GitFixture
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Repos.Worktree

  @moduletag :tmp_dir
  @moduletag :integration

  setup %{tmp_dir: tmp} do
    cleanup = GitHubStub.install()
    on_exit(cleanup)

    on_exit(fn ->
      for table <- [:symphony_branches_reconciler, :symphony_branches_conflict_fallback] do
        if :ets.whereis(table) != :undefined do
          :ets.delete_all_objects(table)
        end
      end
    end)

    {:ok, tmp: tmp}
  end

  describe "scenario: multi-repo dispatch" do
    test "two issues across two configured repos both produce worktrees", %{tmp: tmp} do
      {repo_web, _} = make_source_repo!(tmp, "web")
      {repo_api, _} = make_source_repo!(tmp, "api")

      ws = Path.join(tmp, "ws")
      File.mkdir_p!(ws)

      issue_web = issue("PES-1", ["repo:web", "AFK"], "feat/web-1")
      issue_api = issue("PES-2", ["repo:api", "AFK"], "feat/api-1")

      assert {:ok, %{path: web_path}} =
               Worktree.add(repo_web, "PES-1", "main", "feat/web-1", workspace_root: ws, fetch: false)

      assert {:ok, %{path: api_path}} =
               Worktree.add(repo_api, "PES-2", "main", "feat/api-1", workspace_root: ws, fetch: false)

      assert String.contains?(web_path, "/web/")
      assert String.contains?(api_path, "/api/")

      # DispatchGuard sees both as eligible.
      cfg = settings_with_paths(%{"web" => repo_web.path, "api" => repo_api.path})
      assert :ok = DispatchGuard.evaluate(issue_web, snapshot([]), cfg)
      assert :ok = DispatchGuard.evaluate(issue_api, snapshot([]), cfg)
    end
  end

  describe "scenario: hard-dep stacking (single blocker)" do
    test "A in In Review → X dispatches against feat/A → A in Done → PR retargets to main", %{tmp: tmp} do
      {repo, _} = make_source_repo!(tmp, "src")
      push_branch(repo.path, "feat/A", "a.txt", "from A\n")

      a_in_review = blocker_issue("PES-A", "src", "feat/A", "id-A", "In Review")
      a_done = %{a_in_review | state: "Done"}

      x =
        issue("PES-X", ["repo:src", "AFK"], "feat/x",
          blocked_by: [%{id: "id-A", identifier: "PES-A", state: "In Review"}]
        )

      cfg = settings_with_paths(%{"src" => repo.path})

      # X dispatchable while A is In Review (with branch_exists? from cache).
      Reconciler.run([x], [a_in_review], cfg)
      assert :ok = DispatchGuard.evaluate(x, snapshot([a_in_review]), cfg)

      # BaseResolver picks A's branch.
      assert {:ok, {:single_blocker, "feat/A"}} = BaseResolver.resolve(x, [a_in_review], cfg)

      # PR opens against feat/A.
      GitHubStub.set_pr({"acme/src", "feat/x"}, %{
        number: 100,
        base: "feat/A",
        head: "feat/x",
        state: "OPEN",
        merged: false
      })

      # A reaches Done. Reconciler with forge_repos calls Router → retargets to main.
      Reconciler.run([x], [a_done], cfg, forge_repos: %{"src" => "acme/src"})

      assert [{:retarget_pr, {"acme/src", 100, "main"}}] = GitHubStub.calls(:retarget_pr)
    end
  end

  describe "scenario: multi-blocker integration" do
    test "two blockers In Review → integration branch built → X opens PR against it", %{tmp: tmp} do
      {repo, bare} = make_source_repo!(tmp, "src")
      push_branch(repo.path, "feat/A", "a.txt", "A\n")
      push_branch(repo.path, "feat/B", "b.txt", "B\n")

      a = blocker_issue("PES-A", "src", "feat/A", "id-A", "In Review")
      b = blocker_issue("PES-B", "src", "feat/B", "id-B", "In Review")

      x =
        issue("PES-X", ["repo:src", "AFK"], "feat/x",
          blocked_by: [
            %{id: "id-A", identifier: "PES-A", state: "In Review"},
            %{id: "id-B", identifier: "PES-B", state: "In Review"}
          ]
        )

      cfg = settings_with_paths(%{"src" => repo.path})

      assert {:ok, {:integration, "symphony/integration/pes-x"}} =
               BaseResolver.resolve(x, [a, b], cfg)

      assert {:ok, _sha} =
               IntegrationBuilder.rebuild(repo, "symphony/integration/pes-x", ["feat/A", "feat/B"])

      # Integration branch exists at origin.
      {_out, 0} =
        System.cmd("git", ["-C", bare, "rev-parse", "symphony/integration/pes-x"], stderr_to_stdout: true)
    end

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
  end

  describe "scenario: cascade rework" do
    test "X in In Review rewinds to Todo when blocker A goes In Review → Todo", %{tmp: tmp} do
      {repo, _} = make_source_repo!(tmp, "src")
      push_branch(repo.path, "feat/A", "a.txt", "A\n")

      x =
        issue("PES-X", ["repo:src", "AFK"], "feat/x",
          state: "In Review",
          blocked_by: [%{id: "id-A", identifier: "PES-A", state: "In Review"}]
        )

      a_in_review = blocker_issue("PES-A", "src", "feat/A", "id-A", "In Review")
      a_rewound = blocker_issue("PES-A", "src", "feat/A", "id-A", "Todo")

      cfg = settings_with_paths(%{"src" => repo.path})

      # First pass: blocker In Review — no cascade.
      {:ok, e1} = Reconciler.run([x], [a_in_review], cfg)
      refute Enum.any?(e1, &match?({:cascade_pending, _, _}, &1))

      # Second pass: blocker rewound — cascade event.
      {:ok, e2} = Reconciler.run([x], [a_rewound], cfg)
      assert {:cascade_pending, "id-PES-X", "id-A"} in e2

      # Apply cascade: should rewind X (which is In Review).
      events = Reconciler.drain_cascades()
      issues_by_id = %{"id-PES-X" => %{x | state: "In Review"}, "id-A" => a_rewound}

      lookup = fn id ->
        case Map.fetch(issues_by_id, id) do
          {:ok, i} -> {:ok, i}
          :error -> :error
        end
      end

      parent = self()
      apply_fn = fn ident, state -> send(parent, {:linear_state, ident, state}); :ok end
      comment_fn = fn ident, body -> send(parent, {:linear_comment, ident, body}); :ok end

      assert [{:rewind, "PES-X", _}] = Cascade.apply_cascades(events, lookup, apply_fn, comment_fn)

      assert_received {:linear_state, "PES-X", "Todo"}
      assert_received {:linear_comment, "PES-X", comment}
      assert comment =~ "PES-A returned to `Todo`"
    end
  end

  describe "scenario: post-deploy mediation" do
    test "blocker reaches Done; dependent branch rebases onto main, force-push fires once", %{tmp: tmp} do
      {repo, _bare} = make_source_repo!(tmp, "src")
      push_branch(repo.path, "feat/A", "a.txt", "from A\n")

      # Branch feat/x off feat/A so X carries A's commits.
      {_out, 0} = System.cmd("git", ["-C", repo.path, "checkout", "feat/A"], stderr_to_stdout: true)
      {_out, 0} = System.cmd("git", ["-C", repo.path, "checkout", "-b", "feat/x"], stderr_to_stdout: true)
      GitFixture.commit_file(repo.path, "x.txt", "X content\n", "x adds x.txt")
      {_out, 0} = System.cmd("git", ["-C", repo.path, "push", "-u", "origin", "feat/x"], stderr_to_stdout: true)
      {_out, 0} = System.cmd("git", ["-C", repo.path, "checkout", "main"], stderr_to_stdout: true)

      # Land A on main via cherry-pick + add an unrelated commit so feat/x is
      # provably behind. Without the second commit, the rebase can collapse to
      # a no-op via patch-id matching depending on test ordering.
      {a_sha, 0} = System.cmd("git", ["-C", repo.path, "rev-parse", "origin/feat/A"], stderr_to_stdout: true)
      {_out, 0} = System.cmd("git", ["-C", repo.path, "cherry-pick", String.trim(a_sha)], stderr_to_stdout: true)
      GitFixture.commit_file(repo.path, "main_only.txt", "advance main\n", "advance main")
      {_out, 0} = System.cmd("git", ["-C", repo.path, "push", "origin", "main"], stderr_to_stdout: true)

      assert {:ok, %{from: from_sha, to: to_sha}} =
               Rebaser.rebase_onto(repo, "feat/x", "main", fetch: false)

      assert byte_size(from_sha) >= 7
      assert byte_size(to_sha) >= 7
      assert from_sha != to_sha

      # Confirm origin's feat/x now points at the rebased SHA.
      {origin_sha, 0} =
        System.cmd("git", ["-C", repo.path, "rev-parse", "origin/feat/x"], stderr_to_stdout: true)

      assert String.trim(origin_sha) |> String.starts_with?(to_sha)
    end
  end

  describe "scenario: cross-repo soft dep" do
    test "X in web blocked by A in api: dispatch from main, no integration branch", %{tmp: tmp} do
      {repo_web, _} = make_source_repo!(tmp, "web")
      {repo_api, _} = make_source_repo!(tmp, "api")
      push_branch(repo_api.path, "feat/api-A", "a.txt", "A\n")

      a = blocker_issue("PES-A", "api", "feat/api-A", "id-A", "In Review")

      x =
        issue("PES-X", ["repo:web", "AFK"], "feat/x",
          blocked_by: [%{id: "id-A", identifier: "PES-A", state: "In Review"}]
        )

      cfg = settings_with_paths(%{"web" => repo_web.path, "api" => repo_api.path})

      # BaseResolver: cross-repo blocker filtered → branches from main.
      assert {:ok, {:main, "main"}} = BaseResolver.resolve(x, [a], cfg)

      # DispatchGuard accepts (cross-repo blocker still gates; A is In Review so passes).
      assert :ok = DispatchGuard.evaluate(x, snapshot([a]), cfg)
    end
  end

  describe "scenario: HITL gate" do
    test "HITL-labeled issue is never dispatched, even with all blockers cleared", %{tmp: tmp} do
      {repo, _} = make_source_repo!(tmp, "src")

      x = issue("PES-X", ["repo:src", "HITL"], "feat/x")

      cfg = settings_with_paths(%{"src" => repo.path})

      assert {:skip, :hitl} = DispatchGuard.evaluate(x, snapshot([]), cfg)
    end
  end

  describe "scenario: integration conflict fallback" do
    test "conflict in integration build → workspace prep produces in-tree merge", %{tmp: tmp} do
      {repo, _} = make_source_repo!(tmp, "src")
      push_branch(repo.path, "feat/A", "shared.txt", "lineA\n")
      push_branch(repo.path, "feat/B", "shared.txt", "lineB\n")

      assert {:conflict, files} =
               IntegrationBuilder.rebuild(repo, "symphony/integration/pes-x", ["feat/A", "feat/B"])

      ctx = %{files: files, blocker_branches: ["feat/A", "feat/B"], blocker_shas: %{}}
      assert :new = ConflictFallback.mark_conflict("id-PES-X", ctx)

      ws = Path.join(repo.path |> Path.dirname(), "ws")
      File.mkdir_p!(ws)

      assert {:ok, %{path: path, blocker_shas: shas}} =
               ConflictFallback.prepare_worktree(repo, "PES-X", "feat/x", ["feat/A", "feat/B"],
                 workspace_root: ws,
                 fetch: false
               )

      assert byte_size(shas["feat/A"]) >= 7

      {status, 0} = System.cmd("git", ["-C", path, "status", "--porcelain"], stderr_to_stdout: true)
      assert status =~ "shared.txt"
    end
  end

  defp make_source_repo!(tmp, name) do
    bare = GitFixture.bare_repo(tmp, "#{name}.git")
    source = GitFixture.working_clone(bare, tmp, name)
    repo = %{handle: name, path: source, remote: "origin", default_base: "main"}
    {repo, bare}
  end

  defp push_branch(source, branch, file, content) do
    {_out, 0} = System.cmd("git", ["-C", source, "checkout", "main"], stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["-C", source, "checkout", "-b", branch], stderr_to_stdout: true)
    GitFixture.commit_file(source, file, content, "add #{file} on #{branch}")
    {_out, 0} = System.cmd("git", ["-C", source, "push", "-u", "origin", branch], stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["-C", source, "checkout", "main"], stderr_to_stdout: true)
  end

  defp issue(identifier, labels, branch_name, opts \\ []) do
    %Issue{
      id: "id-" <> identifier,
      identifier: identifier,
      labels: labels,
      branch_name: branch_name,
      blocked_by: Keyword.get(opts, :blocked_by, []),
      state: Keyword.get(opts, :state, "Todo")
    }
  end

  defp blocker_issue(identifier, repo_handle, branch_name, id, state) do
    %Issue{
      id: id,
      identifier: identifier,
      labels: ["repo:" <> repo_handle],
      branch_name: branch_name,
      state: state
    }
  end

  defp snapshot(blockers) do
    %{
      blockers_by_id: Map.new(blockers, fn b -> {b.id, b} end),
      branch_exists?: fn _h, _b -> true end
    }
  end

  defp settings_with_paths(paths) do
    by_label = Map.new(paths, fn {handle, _} -> {"repo:" <> handle, handle} end)

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
        default: paths |> Map.keys() |> hd(),
        by_label: by_label,
        paths: paths,
        remote: "origin",
        default_base_branch: "main"
      }
    }
  end
end
