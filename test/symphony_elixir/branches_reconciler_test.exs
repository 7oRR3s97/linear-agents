defmodule SymphonyElixir.Branches.ReconcilerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Branches.Reconciler
  alias SymphonyElixir.Forge.GitHubStub
  alias SymphonyElixir.GitFixture
  alias SymphonyElixir.Linear.Issue

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    bare = GitFixture.bare_repo(tmp)
    source = GitFixture.working_clone(bare, tmp, "src")

    cleanup = GitHubStub.install()
    on_exit(cleanup)

    on_exit(fn ->
      # Clear ETS state between tests so cascade tracking doesn't leak.
      if :ets.whereis(:symphony_branches_reconciler) != :undefined do
        :ets.delete_all_objects(:symphony_branches_reconciler)
      end
    end)

    {:ok, bare: bare, source: source}
  end

  describe "stacking disabled" do
    test "is a no-op" do
      x = issue("PES-1", ["repo:src", "AFK"], "feat/x")
      cfg = settings(stacking_enabled: false)

      assert {:ok, []} = Reconciler.run([x], [], cfg)
    end
  end

  describe "branch SHA cache + branch_exists?" do
    test "refreshes the cache for same-repo blocker branches", %{source: source} do
      push_branch_with_file(source, "feat/A", "a.txt", "a\n")

      x = issue("PES-X", ["repo:src", "AFK"], "feat/x", blocked_by: [%{id: "A", state: "In Review"}])
      a = blocker_issue("PES-A", "src", "feat/A", "A", "In Review")

      cfg = settings(repo_path: source)

      assert {:ok, _events} = Reconciler.run([x], [a], cfg)
      assert is_binary(Reconciler.branch_sha("src", "feat/A"))
      assert Reconciler.branch_exists?("src", "feat/A")
      refute Reconciler.branch_exists?("src", "feat/missing")
    end
  end

  describe "rebase scheduling for single-blocker hard deps" do
    test "writes a :rebase_target entry", %{source: source} do
      push_branch_with_file(source, "feat/A", "a.txt", "a\n")

      x = issue("PES-X", ["repo:src", "AFK"], "feat/x", blocked_by: [%{id: "A", state: "In Review"}])
      a = blocker_issue("PES-A", "src", "feat/A", "A", "In Review")

      cfg = settings(repo_path: source)

      {:ok, events} = Reconciler.run([x], [a], cfg)

      assert {:rebase_scheduled, "PES-X", "feat/A"} in events
      assert Reconciler.rebase_target("id-PES-X") == "feat/A"
    end
  end

  describe "integration rebuild for multi-blocker hard deps" do
    test "calls IntegrationBuilder when 2+ same-repo blockers in unblock states", %{source: source} do
      push_branch_with_file(source, "feat/A", "a.txt", "a\n")
      push_branch_with_file(source, "feat/B", "b.txt", "b\n")

      x =
        issue("PES-X", ["repo:src", "AFK"], "feat/x",
          blocked_by: [
            %{id: "A", state: "In Review"},
            %{id: "B", state: "In Review"}
          ]
        )

      a = blocker_issue("PES-A", "src", "feat/A", "A", "In Review")
      b = blocker_issue("PES-B", "src", "feat/B", "B", "In Review")

      builder = fn _repo, name, branches, _base ->
        send(self(), {:built, name, branches})
        {:ok, "abc1234"}
      end

      cfg = settings(repo_path: source)

      {:ok, events} = Reconciler.run([x], [a, b], cfg, integration_builder: builder)

      assert_received {:built, "symphony/integration/pes-x", branches}
      assert Enum.sort(branches) == ["feat/A", "feat/B"]
      assert {:integration_rebuilt, "PES-X", {:ok, "abc1234"}} in events
    end
  end

  describe "PR routing on Done blocker" do
    test "calls PR.Router via Forge stub when forge_repos provided", %{source: source} do
      push_branch_with_file(source, "feat/A", "a.txt", "a\n")

      x = issue("PES-X", ["repo:src", "AFK"], "feat/x", blocked_by: [%{id: "A", state: "Done"}])
      a = blocker_issue("PES-A", "src", "feat/A", "A", "Done")

      GitHubStub.set_pr({"acme/src", "feat/x"}, %{
        number: 7,
        base: "feat/A",
        head: "feat/x",
        state: "OPEN",
        merged: false
      })

      cfg = settings(repo_path: source)

      {:ok, events} =
        Reconciler.run([x], [a], cfg, forge_repos: %{"src" => "acme/src"})

      # Done blocker → drop from active list → desired base = main → retarget
      assert Enum.any?(events, fn
               {:pr_routed, "PES-X", :ok} -> true
               _ -> false
             end)

      assert [{:retarget_pr, {"acme/src", 7, "main"}}] = GitHubStub.calls(:retarget_pr)
    end
  end

  describe "post-deploy active rebase" do
    test "all-blockers-Done triggers Rebaser when dependent isn't In Progress", %{source: source} do
      x =
        issue("PES-X", ["repo:src", "AFK"], "feat/x",
          state: "In Review",
          blocked_by: [%{id: "A", state: "Done"}]
        )

      a = blocker_issue("PES-A", "src", "feat/A", "A", "Done")
      cfg = settings(repo_path: source)

      parent = self()

      rebaser = fn _repo, branch, target, _opts ->
        send(parent, {:rebase_called, branch, target})
        {:ok, %{from: "old", to: "new"}}
      end

      {:ok, events} = Reconciler.run([x], [a], cfg, rebaser: rebaser)

      assert_received {:rebase_called, "feat/x", "main"}
      assert {:rebase_run, "PES-X", {:ok, %{from: "old", to: "new"}}} in events
    end

    test "skips rebase when dependent is currently In Progress", %{source: source} do
      x =
        issue("PES-X", ["repo:src", "AFK"], "feat/x",
          state: "In Progress",
          blocked_by: [%{id: "A", state: "Done"}]
        )

      a = blocker_issue("PES-A", "src", "feat/A", "A", "Done")
      cfg = settings(repo_path: source)

      rebaser = fn _, _, _, _ -> flunk("rebase should be deferred for In Progress") end

      {:ok, events} =
        Reconciler.run([x], [a], cfg, rebaser: rebaser, in_progress_ids: MapSet.new(["id-PES-X"]))

      refute Enum.any?(events, &match?({:rebase_run, _, _}, &1))
    end

    test "doesn't rebase while a blocker is still In Review (not all done)", %{source: source} do
      x =
        issue("PES-X", ["repo:src", "AFK"], "feat/x",
          state: "In Review",
          blocked_by: [
            %{id: "A", state: "Done"},
            %{id: "B", state: "In Review"}
          ]
        )

      a = blocker_issue("PES-A", "src", "feat/A", "A", "Done")
      b = blocker_issue("PES-B", "src", "feat/B", "B", "In Review")
      cfg = settings(repo_path: source)

      rebaser = fn _, _, _, _ -> flunk("rebase only fires when ALL blockers are Done") end

      {:ok, _events} = Reconciler.run([x], [a, b], cfg, rebaser: rebaser)
    end

    test "surfaces rebase conflicts as :rebase_run events without crashing", %{source: source} do
      x =
        issue("PES-X", ["repo:src", "AFK"], "feat/x",
          state: "In Review",
          blocked_by: [%{id: "A", state: "Done"}]
        )

      a = blocker_issue("PES-A", "src", "feat/A", "A", "Done")
      cfg = settings(repo_path: source)
      rebaser = fn _, _, _, _ -> {:conflict, ["shared.txt"]} end

      {:ok, events} = Reconciler.run([x], [a], cfg, rebaser: rebaser)

      assert {:rebase_run, "PES-X", {:conflict, ["shared.txt"]}} in events
    end
  end

  describe "cascade detection on In Review → Todo rewind" do
    test "emits a cascade event the first time, idempotent thereafter", %{source: source} do
      push_branch_with_file(source, "feat/A", "a.txt", "a\n")

      x = issue("PES-X", ["repo:src", "AFK"], "feat/x", blocked_by: [%{id: "A", state: "In Review"}])
      a_in_review = blocker_issue("PES-A", "src", "feat/A", "A", "In Review")
      a_rewound = blocker_issue("PES-A", "src", "feat/A", "A", "Todo")

      cfg = settings(repo_path: source)

      # First pass: blocker is In Review → no cascade.
      {:ok, e1} = Reconciler.run([x], [a_in_review], cfg)
      refute Enum.any?(e1, &match?({:cascade_pending, _, _}, &1))

      # Second pass: blocker dropped to Todo → cascade event.
      {:ok, e2} = Reconciler.run([x], [a_rewound], cfg)
      assert {:cascade_pending, "id-PES-X", "A"} in e2

      cascades = Reconciler.drain_cascades()
      assert {"id-PES-X", "A"} in cascades

      # After draining, no duplicate.
      assert Reconciler.drain_cascades() == []
    end
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

  defp settings(opts) do
    %{
      stacking: %{
        enabled: Keyword.get(opts, :stacking_enabled, true),
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
        paths: %{"src" => Keyword.get(opts, :repo_path, "/tmp/src")},
        remote: "origin",
        default_base_branch: "main"
      }
    }
  end

  defp push_branch_with_file(source, branch, filename, contents) do
    {_out, 0} = System.cmd("git", ["-C", source, "checkout", "main"], stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["-C", source, "checkout", "-b", branch], stderr_to_stdout: true)
    GitFixture.commit_file(source, filename, contents, "add #{filename} on #{branch}")
    {_out, 0} = System.cmd("git", ["-C", source, "push", "-u", "origin", branch], stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["-C", source, "checkout", "main"], stderr_to_stdout: true)
  end
end
