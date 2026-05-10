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

  # Aliases below are commented out in this skeleton (Task 2.4) to keep
  # `--warnings-as-errors` clean. Subsequent tasks (2.5+) re-enable them as
  # the scenarios that use each module land.
  alias SymphonyElixir.Branches.BaseResolver
  alias SymphonyElixir.Branches.Reconciler
  # alias SymphonyElixir.Branches.{ConflictFallback, IntegrationBuilder}
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

    bare = GitFixture.bare_repo(tmp, "src.git")
    work = GitFixture.working_clone(bare, tmp, "src")

    repo = %{
      path: work,
      bare_path: bare,
      gh_slug: @gh_slug,
      handle: "src",
      remote: "origin",
      default_base: "main"
    }

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

    x = %{
      x
      | blocked_by: [
          %{id: a.id, identifier: a.identifier, state: "Todo"},
          %{id: b.id, identifier: b.identifier, state: "Todo"}
        ]
    }

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

  @tag skip: @skip_reason
  test "live stacking pipeline against real Linear and local Git", %{
    manifest_path: manifest_path,
    repo: repo,
    issues: issues,
    state_ids: state_ids
  } do
    cfg = settings(repo)

    # ---- Scenario A: stacked dispatch ----
    a_result =
      MockAgent.dispatch!(issues.a, "main", repo,
        in_review_state_id: state_ids.in_review,
        manifest_path: manifest_path
      )

    assert a_result.branch == issues.a.branch_name

    a_in_review = %{issues.a | state: "In Review"}
    y_for_resolve = issues.y

    assert {:ok, {:single_blocker, base_for_y}} =
             BaseResolver.resolve(y_for_resolve, [a_in_review], cfg)

    assert base_for_y == issues.a.branch_name

    y_result =
      MockAgent.dispatch!(issues.y, base_for_y, repo,
        in_review_state_id: state_ids.in_review,
        manifest_path: manifest_path
      )

    assert y_result.branch == issues.y.branch_name

    {:ok, y_pr} = GitHubStub.pr_for_branch(repo.gh_slug, issues.y.branch_name)
    assert y_pr.base == issues.a.branch_name
    assert y_pr.state == "OPEN"

    {:ok, x_pr} = GitHubStub.pr_for_branch(repo.gh_slug, issues.x.branch_name)
    assert x_pr == nil

    # ---- Scenario B: retarget on merge ----
    FakeHuman.merge!(issues.a, repo,
      terminal_state_id: state_ids.done,
      manifest_path: manifest_path
    )

    a_done = %{issues.a | state: "Done"}

    y_in_review = %{
      issues.y
      | state: "In Review",
        blocked_by: [%{id: issues.a.id, identifier: issues.a.identifier, state: "Done"}]
    }

    {:ok, _events} =
      Reconciler.run([y_in_review], [a_done], cfg, forge_repos: %{"src" => repo.gh_slug})

    retarget_calls = GitHubStub.calls(:retarget_pr)
    assert Enum.any?(retarget_calls, &match?({:retarget_pr, {_, _, "main"}}, &1))

    # ---- Scenario C: cascade rewind ----
    FakeHuman.rewind!(issues.a, state_ids.todo, manifest_path: manifest_path)

    a_rewound = %{issues.a | state: "Todo"}

    y_in_review_after_rewind = %{
      y_in_review
      | blocked_by: [%{id: issues.a.id, identifier: issues.a.identifier, state: "Todo"}]
    }

    # Tick 1: prime previous-state cache (A was Done before).
    {:ok, _} = Reconciler.run([y_in_review], [a_done], cfg)

    # Tick 2: A is now Todo → cascade event for Y.
    {:ok, e2} = Reconciler.run([y_in_review_after_rewind], [a_rewound], cfg)
    assert {:cascade_pending, _y_id, _a_id} = Enum.find(e2, &match?({:cascade_pending, _, _}, &1))

    cascades = Reconciler.drain_cascades()

    issues_by_id = %{issues.y.id => y_in_review_after_rewind, issues.a.id => a_rewound}

    parent = self()

    apply_fn = fn identifier, _new_state ->
      send(parent, {:linear_state, identifier, "Todo"})

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
end
