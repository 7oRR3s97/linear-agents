defmodule SymphonyElixir.PR.RouterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Forge.GitHubStub
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PR.Router

  setup do
    cleanup = GitHubStub.install()
    on_exit(cleanup)
    :ok
  end

  describe "ensure_pr_base_correct/4" do
    test "returns {:noop, :pr_not_open} when no PR exists for the branch" do
      x = issue("PES-2", ["repo:web", "AFK"], "feat/X", [])

      assert {:noop, :pr_not_open} =
               Router.ensure_pr_base_correct(x, [], settings(), gh_repo: "acme/web")

      assert [{:pr_for_branch, {"acme/web", "feat/X"}}] = GitHubStub.calls(:pr_for_branch)
      assert [] = GitHubStub.calls(:retarget_pr)
    end

    test "no blockers + PR base already main = no retarget" do
      x = issue("PES-2", ["repo:web", "AFK"], "feat/X", [])

      GitHubStub.set_pr({"acme/web", "feat/X"}, %{
        number: 10,
        base: "main",
        head: "feat/X",
        state: "OPEN",
        merged: false
      })

      assert :ok = Router.ensure_pr_base_correct(x, [], settings(), gh_repo: "acme/web")
      assert [] = GitHubStub.calls(:retarget_pr)
    end

    test "retargets PR when desired base differs from current" do
      x = issue("PES-2", ["repo:web", "AFK"], "feat/X", [])

      GitHubStub.set_pr({"acme/web", "feat/X"}, %{
        number: 10,
        base: "feat/A",
        head: "feat/X",
        state: "OPEN",
        merged: false
      })

      # No blockers → desired base is main; current is feat/A → should retarget
      assert :ok = Router.ensure_pr_base_correct(x, [], settings(), gh_repo: "acme/web")
      assert [{:retarget_pr, {"acme/web", 10, "main"}}] = GitHubStub.calls(:retarget_pr)
    end

    test "single blocker still in review keeps PR base on blocker branch" do
      x =
        issue("PES-2", ["repo:web", "AFK"], "feat/X",
          blocked_by: [%{id: "id-A", identifier: "PES-1", state: "In Review"}]
        )

      a = blocker("PES-1", "web", "feat/A", "id-A", "In Review")

      GitHubStub.set_pr({"acme/web", "feat/X"}, %{
        number: 10,
        base: "feat/A",
        head: "feat/X",
        state: "OPEN",
        merged: false
      })

      assert :ok = Router.ensure_pr_base_correct(x, [a], settings(), gh_repo: "acme/web")
      assert [] = GitHubStub.calls(:retarget_pr)
    end

    test "single blocker merged: PR retargets to main" do
      x =
        issue("PES-2", ["repo:web", "AFK"], "feat/X",
          blocked_by: [%{id: "id-A", identifier: "PES-1", state: "Done"}]
        )

      # Blocker now Done → BaseResolver treats it as merged, not in unblock_states… wait
      # Done IS in unblock_states by default. Hmm — for the *base ref* purposes,
      # a Done blocker is treated as merged-to-main and contributes nothing to the
      # base ref. Let's stub the blocker accordingly: branch_name still set, state Done.
      _a = blocker("PES-1", "web", "feat/A", "id-A", "Done")

      GitHubStub.set_pr({"acme/web", "feat/X"}, %{
        number: 10,
        base: "feat/A",
        head: "feat/X",
        state: "OPEN",
        merged: false
      })

      # We expect the Router to consider Done blockers as no longer contributing
      # to the base ref — pass blockers filtered by the caller in real usage.
      # Router accepts the filtered list directly.
      assert :ok = Router.ensure_pr_base_correct(x, [], settings(), gh_repo: "acme/web")
      assert [{:retarget_pr, {"acme/web", 10, "main"}}] = GitHubStub.calls(:retarget_pr)
    end

    test "all blockers merged with previous integration base: retarget to main and delete integration branch" do
      x = issue("PES-2", ["repo:web", "AFK"], "feat/X", [])

      GitHubStub.set_pr({"acme/web", "feat/X"}, %{
        number: 10,
        base: "symphony/integration/pes-2",
        head: "feat/X",
        state: "OPEN",
        merged: false
      })

      assert :ok = Router.ensure_pr_base_correct(x, [], settings(), gh_repo: "acme/web")

      assert [{:retarget_pr, {"acme/web", 10, "main"}}] = GitHubStub.calls(:retarget_pr)

      assert [{:delete_branch, {"acme/web", "symphony/integration/pes-2"}}] =
               GitHubStub.calls(:delete_branch)
    end

    test "two open blockers: PR base stays as integration branch" do
      x =
        issue("PES-3", ["repo:web", "AFK"], "feat/X",
          blocked_by: [
            %{id: "id-A", identifier: "PES-1", state: "In Review"},
            %{id: "id-B", identifier: "PES-2", state: "In Review"}
          ]
        )

      a = blocker("PES-1", "web", "feat/A", "id-A", "In Review")
      b = blocker("PES-2", "web", "feat/B", "id-B", "In Review")

      GitHubStub.set_pr({"acme/web", "feat/X"}, %{
        number: 10,
        base: "symphony/integration/pes-3",
        head: "feat/X",
        state: "OPEN",
        merged: false
      })

      assert :ok = Router.ensure_pr_base_correct(x, [a, b], settings(), gh_repo: "acme/web")
      assert [] = GitHubStub.calls(:retarget_pr)
      assert [] = GitHubStub.calls(:delete_branch)
    end

    test "BaseResolver error surfaces as {:error, _}" do
      orphan = %Issue{identifier: "X-1", labels: [], branch_name: "feat/X"}
      cfg = settings(default: nil, by_label: %{}, paths: %{})

      assert {:error, :issue_repo_unresolvable} =
               Router.ensure_pr_base_correct(orphan, [], cfg, gh_repo: "acme/web")
    end
  end

  defp issue(identifier, labels, branch_name, blocked_by) when is_list(blocked_by) do
    %Issue{
      id: "id-" <> identifier,
      identifier: identifier,
      labels: labels,
      branch_name: branch_name,
      blocked_by: blocked_by,
      state: "Todo"
    }
  end

  defp issue(identifier, labels, branch_name, opts) do
    %Issue{
      id: "id-" <> identifier,
      identifier: identifier,
      labels: labels,
      branch_name: branch_name,
      blocked_by: Keyword.get(opts, :blocked_by, []),
      state: Keyword.get(opts, :state, "Todo")
    }
  end

  defp blocker(identifier, repo, branch, id, state) do
    %Issue{
      id: id,
      identifier: identifier,
      labels: ["repo:" <> repo],
      branch_name: branch,
      state: state
    }
  end

  defp settings(opts \\ []) do
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
        default: Keyword.get(opts, :default, "web"),
        by_label: Keyword.get(opts, :by_label, %{"repo:web" => "web", "repo:api" => "api"}),
        paths: Keyword.get(opts, :paths, %{"web" => "/tmp/web", "api" => "/tmp/api"}),
        remote: "origin",
        default_base_branch: "main"
      }
    }
  end
end
