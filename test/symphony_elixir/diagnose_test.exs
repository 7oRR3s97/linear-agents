defmodule SymphonyElixir.DiagnoseTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Diagnose
  alias SymphonyElixir.Linear.Issue

  test "renders a full report for a 2-blocker issue with PR open" do
    issue = %Issue{
      id: "id-X",
      identifier: "PES-7",
      state: "Todo",
      branch_name: "feat/X",
      labels: ["repo:web", "AFK"],
      blocked_by: [
        %{id: "id-A", identifier: "PES-1", state: "In Review"},
        %{id: "id-B", identifier: "PES-2", state: "In Review"}
      ]
    }

    blockers = [
      %Issue{
        id: "id-A",
        identifier: "PES-1",
        labels: ["repo:web"],
        branch_name: "feat/A",
        state: "In Review"
      },
      %Issue{
        id: "id-B",
        identifier: "PES-2",
        labels: ["repo:api"],
        branch_name: "feat/B",
        state: "In Review"
      }
    ]

    pr = %{number: 42, base: "feat/A", head: "feat/X", state: "OPEN"}

    report = Diagnose.render(%{issue: issue, blockers: blockers, settings: settings(), pr: pr})

    assert report =~ "# Symphony Diagnose: PES-7"
    assert report =~ "handle:        web"
    assert report =~ "default_base:  main"
    assert report =~ "PES-1"
    assert report =~ "hard (same repo)"
    assert report =~ "PES-2"
    assert report =~ "soft (cross-repo: api)"
    assert report =~ "DispatchGuard"
    assert report =~ "BaseResolver"
    assert report =~ ":single_blocker"
    assert report =~ "##{42}"
  end

  test "renders 'no PR yet' when nil" do
    issue = %Issue{identifier: "PES-1", state: "Todo", labels: ["repo:web", "AFK"], branch_name: "feat/X"}
    report = Diagnose.render(%{issue: issue, blockers: [], settings: settings(), pr: nil})

    assert report =~ "(no PR yet)"
  end

  test "renders error blocks when repo routing fails" do
    issue = %Issue{identifier: "PES-1", state: "Todo", labels: [], branch_name: "feat/X"}
    cfg = settings(default: nil, by_label: %{}, paths: %{})

    report = Diagnose.render(%{issue: issue, blockers: [], settings: cfg, pr: nil})

    assert report =~ "## Repo Routing"
    assert report =~ "error:"
    assert report =~ "BaseResolver"
    assert report =~ "issue_repo_unresolvable"
  end

  test "renders blockers (none) when issue has none" do
    issue = %Issue{identifier: "PES-1", state: "Todo", labels: ["repo:web", "AFK"], branch_name: "feat/X"}

    report = Diagnose.render(%{issue: issue, blockers: [], settings: settings(), pr: nil})
    assert report =~ "## Blockers (0)"
    assert report =~ "(none)"
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
      tracker: %{
        active_states: ["Todo", "In Progress", "In Review"],
        terminal_states: ["Done"]
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
