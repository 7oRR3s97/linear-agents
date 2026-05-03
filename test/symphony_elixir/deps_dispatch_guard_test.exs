defmodule SymphonyElixir.Deps.DispatchGuardTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Deps.DispatchGuard
  alias SymphonyElixir.Linear.Issue

  describe "evaluate/3 — autonomy gate" do
    test "AFK label dispatchable" do
      assert :ok = DispatchGuard.evaluate(issue("PES-1", ["repo:web", "AFK"]), snapshot(), settings())
    end

    test "HITL label blocks" do
      assert {:skip, :hitl} =
               DispatchGuard.evaluate(issue("PES-1", ["repo:web", "HITL"]), snapshot(), settings())
    end

    test "missing autonomy label with default HITL blocks" do
      assert {:skip, :hitl} =
               DispatchGuard.evaluate(issue("PES-1", ["repo:web"]), snapshot(), settings())
    end

    test "missing autonomy label with default AFK dispatches" do
      cfg = settings(default_when_missing: "AFK")
      assert :ok = DispatchGuard.evaluate(issue("PES-1", ["repo:web"]), snapshot(), cfg)
    end

    test "case-insensitive autonomy label match" do
      assert :ok = DispatchGuard.evaluate(issue("PES-1", ["repo:web", "afk"]), snapshot(), settings())

      assert {:skip, :hitl} =
               DispatchGuard.evaluate(issue("PES-1", ["repo:web", "hitl"]), snapshot(), settings())
    end
  end

  describe "evaluate/3 — repo routing" do
    test "no repo:* label and no default fails" do
      cfg = settings(default: nil, by_label: %{}, paths: %{})

      assert {:skip, :repo_routing_failed} =
               DispatchGuard.evaluate(issue("PES-1", ["AFK"]), snapshot(), cfg)
    end

    test "ambiguous repo:* labels fail" do
      assert {:skip, :repo_routing_ambiguous} =
               DispatchGuard.evaluate(issue("PES-1", ["repo:web", "repo:api", "AFK"]), snapshot(), settings())
    end
  end

  describe "evaluate/3 — same-repo (hard-dep) blockers" do
    test "blocker in unblock state with branch present passes" do
      x = issue("PES-2", ["repo:web", "AFK"], blocked_by: [%{id: "id-A", identifier: "PES-1", state: "In Review"}])

      blocker_a = blocker_issue("PES-1", "web", "br-a", "id-A", "In Review")
      snap = snapshot(blockers: [blocker_a])

      assert :ok = DispatchGuard.evaluate(x, snap, settings())
    end

    test "blocker not in unblock state skips" do
      x = issue("PES-2", ["repo:web", "AFK"], blocked_by: [%{id: "id-A", identifier: "PES-1", state: "Todo"}])

      blocker = blocker_issue("PES-1", "web", "br-a", "id-A", "Todo")
      snap = snapshot(blockers: [blocker])

      assert {:skip, {:blocker_not_in_unblock_states, "PES-1"}} =
               DispatchGuard.evaluate(x, snap, settings())
    end

    test "blocker branch missing skips" do
      x = issue("PES-2", ["repo:web", "AFK"], blocked_by: [%{id: "id-A", identifier: "PES-1", state: "In Review"}])

      blocker = blocker_issue("PES-1", "web", "br-a", "id-A", "In Review")

      snap =
        snapshot(blockers: [blocker], branch_exists?: fn _handle, _branch -> false end)

      assert {:skip, {:blocker_branch_missing, "PES-1"}} =
               DispatchGuard.evaluate(x, snap, settings())
    end

    test "blocker without branch_name in snapshot skips with branch_missing" do
      x = issue("PES-2", ["repo:web", "AFK"], blocked_by: [%{id: "id-A", identifier: "PES-1", state: "In Review"}])

      blocker = %{blocker_issue("PES-1", "web", "br-a", "id-A", "In Review") | branch_name: nil}
      snap = snapshot(blockers: [blocker])

      assert {:skip, {:blocker_branch_missing, "PES-1"}} =
               DispatchGuard.evaluate(x, snap, settings())
    end
  end

  describe "evaluate/3 — cross-repo (soft-dep) blockers" do
    test "blocker in unblock state passes regardless of branch" do
      x =
        issue("PES-2", ["repo:web", "AFK"], blocked_by: [%{id: "id-A", identifier: "PES-1", state: "In Review"}])

      blocker = blocker_issue("PES-1", "api", nil, "id-A", "In Review")

      snap =
        snapshot(blockers: [blocker], branch_exists?: fn _handle, _branch -> false end)

      assert :ok = DispatchGuard.evaluate(x, snap, settings())
    end

    test "blocker not in unblock state skips" do
      x = issue("PES-2", ["repo:web", "AFK"], blocked_by: [%{id: "id-A", identifier: "PES-1", state: "Todo"}])

      blocker = blocker_issue("PES-1", "api", nil, "id-A", "Todo")
      snap = snapshot(blockers: [blocker])

      assert {:skip, {:blocker_not_in_unblock_states, "PES-1"}} =
               DispatchGuard.evaluate(x, snap, settings())
    end
  end

  describe "evaluate/3 — multi blocker" do
    test "diamond: hard dep + soft dep both must clear" do
      x =
        issue("PES-3", ["repo:web", "AFK"],
          blocked_by: [
            %{id: "id-A", identifier: "PES-1", state: "In Review"},
            %{id: "id-B", identifier: "PES-2", state: "In Review"}
          ]
        )

      hard = blocker_issue("PES-1", "web", "br-a", "id-A", "In Review")
      soft = blocker_issue("PES-2", "api", nil, "id-B", "In Review")

      snap = snapshot(blockers: [hard, soft])
      assert :ok = DispatchGuard.evaluate(x, snap, settings())
    end

    test "diamond: hard dep ok but soft dep stuck — skipped" do
      x =
        issue("PES-3", ["repo:web", "AFK"],
          blocked_by: [
            %{id: "id-A", identifier: "PES-1", state: "In Review"},
            %{id: "id-B", identifier: "PES-2", state: "Todo"}
          ]
        )

      hard = blocker_issue("PES-1", "web", "br-a", "id-A", "In Review")
      soft = blocker_issue("PES-2", "api", nil, "id-B", "Todo")

      snap = snapshot(blockers: [hard, soft])

      assert {:skip, {:blocker_not_in_unblock_states, "PES-2"}} =
               DispatchGuard.evaluate(x, snap, settings())
    end
  end

  describe "evaluate/3 — when stacking is disabled" do
    test "returns :ok with no further checks" do
      cfg = settings(stacking_enabled: false)

      assert :ok =
               DispatchGuard.evaluate(
                 issue("PES-1", ["HITL"]),
                 snapshot(),
                 cfg
               )
    end
  end

  defp issue(identifier, labels, opts \\ []) do
    %Issue{
      id: "id-" <> identifier,
      identifier: identifier,
      labels: labels,
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

  defp snapshot(opts \\ []) do
    blockers = Keyword.get(opts, :blockers, [])

    %{
      blockers_by_id: Map.new(blockers, fn b -> {b.id, b} end),
      branch_exists?: Keyword.get(opts, :branch_exists?, fn _handle, _branch -> true end)
    }
  end

  defp settings(opts \\ []) do
    %{
      stacking: %{
        enabled: Keyword.get(opts, :stacking_enabled, true),
        unblock_states: Keyword.get(opts, :unblock_states, ["In Review", "Done"])
      },
      agent_autonomy: %{
        label_dispatchable: Keyword.get(opts, :label_dispatchable, "AFK"),
        label_human_only: Keyword.get(opts, :label_human_only, "HITL"),
        default_when_missing: Keyword.get(opts, :default_when_missing, "HITL")
      },
      tracker: %{
        active_states: Keyword.get(opts, :active_states, ["Todo", "In Progress", "In Review"]),
        terminal_states: Keyword.get(opts, :terminal_states, ["Done", "Canceled", "Duplicate"])
      },
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
