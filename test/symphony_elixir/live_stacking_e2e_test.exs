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
  alias SymphonyElixir.Branches.{BaseResolver, ConflictFallback, IntegrationBuilder, Reconciler}
  alias SymphonyElixir.Deps.Cascade
  alias SymphonyElixir.E2EManifest
  alias SymphonyElixir.FakeHuman
  alias SymphonyElixir.Feedback.Detector
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

    repo_for_builder = %{
      handle: "src",
      path: repo.path,
      remote: "origin",
      default_base: "main"
    }

    # ---- Scenario A: full stacking dispatch ----
    # A and B are independent (no blockers) and dispatch first. Y depends on
    # A only → stacks against A's branch. X depends on A AND B → integration
    # branch over both. All four reach In Review.
    MockAgent.dispatch!(issues.a, "main", repo,
      in_review_state_id: state_ids.in_review,
      manifest_path: manifest_path
    )

    MockAgent.dispatch!(issues.b, "main", repo,
      in_review_state_id: state_ids.in_review,
      manifest_path: manifest_path
    )

    a_in_review = %{issues.a | state: "In Review"}
    b_in_review = %{issues.b | state: "In Review"}

    assert {:ok, {:single_blocker, base_for_y}} =
             BaseResolver.resolve(issues.y, [a_in_review], cfg)

    assert base_for_y == issues.a.branch_name

    MockAgent.dispatch!(issues.y, base_for_y, repo,
      in_review_state_id: state_ids.in_review,
      manifest_path: manifest_path
    )

    assert {:ok, {:integration, integration_branch}} =
             BaseResolver.resolve(issues.x, [a_in_review, b_in_review], cfg)

    # IntegrationBuilder builds the synthetic merge branch from A and B's
    # branches — what the Reconciler does in production once 2+ blockers are
    # In Review.
    assert {:ok, _sha} =
             IntegrationBuilder.rebuild(
               repo_for_builder,
               integration_branch,
               [issues.a.branch_name, issues.b.branch_name]
             )

    MockAgent.dispatch!(issues.x, integration_branch, repo,
      in_review_state_id: state_ids.in_review,
      manifest_path: manifest_path
    )

    {:ok, a_pr} = GitHubStub.pr_for_branch(repo.gh_slug, issues.a.branch_name)
    {:ok, b_pr} = GitHubStub.pr_for_branch(repo.gh_slug, issues.b.branch_name)
    {:ok, y_pr} = GitHubStub.pr_for_branch(repo.gh_slug, issues.y.branch_name)
    {:ok, x_pr} = GitHubStub.pr_for_branch(repo.gh_slug, issues.x.branch_name)

    assert a_pr.base == "main"
    assert b_pr.base == "main"
    assert y_pr.base == issues.a.branch_name
    assert x_pr.base == integration_branch

    for pr <- [a_pr, b_pr, y_pr, x_pr], do: assert(pr.state == "OPEN")

    # Confirm Linear sees all four In Review.
    for issue <- [issues.a, issues.b, issues.y, issues.x] do
      assert issue_state_type!(issue.id) == "started",
             "expected #{issue.identifier} in a started state after dispatch"
    end

    # ---- Scenario B: A merges → Y retargets to main, X retargets to B ----
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

    x_in_review = %{
      issues.x
      | state: "In Review",
        blocked_by: [
          %{id: issues.a.id, identifier: issues.a.identifier, state: "Done"},
          %{id: issues.b.id, identifier: issues.b.identifier, state: "In Review"}
        ]
    }

    {:ok, _events} =
      Reconciler.run([y_in_review, x_in_review], [a_done, b_in_review], cfg,
        forge_repos: %{"src" => repo.gh_slug}
      )

    retarget_calls = GitHubStub.calls(:retarget_pr)

    assert Enum.any?(retarget_calls, fn
             {:retarget_pr, {_, n, "main"}} -> n == y_pr.number
             _ -> false
           end),
           "expected Y to retarget to main; got: #{inspect(retarget_calls)}"

    assert Enum.any?(retarget_calls, fn
             {:retarget_pr, {_, n, base}} -> n == x_pr.number and base == issues.b.branch_name
             _ -> false
           end),
           "expected X to retarget to feat/B; got: #{inspect(retarget_calls)}"

    # ---- Scenario C: B merges → X final retarget to main ----
    FakeHuman.merge!(issues.b, repo,
      terminal_state_id: state_ids.done,
      manifest_path: manifest_path
    )

    b_done = %{issues.b | state: "Done"}

    x_in_review_after_b = %{
      x_in_review
      | blocked_by: [
          %{id: issues.a.id, identifier: issues.a.identifier, state: "Done"},
          %{id: issues.b.id, identifier: issues.b.identifier, state: "Done"}
        ]
    }

    # Refresh stub PR base so PR.Router sees X currently on feat/B (per
    # scenario B's retarget).
    GitHubStub.set_pr({repo.gh_slug, issues.x.branch_name}, %{x_pr | base: issues.b.branch_name})

    {:ok, _events} =
      Reconciler.run([x_in_review_after_b], [a_done, b_done], cfg,
        forge_repos: %{"src" => repo.gh_slug}
      )

    final_retargets = GitHubStub.calls(:retarget_pr)

    assert Enum.count(final_retargets, fn
             {:retarget_pr, {_, n, "main"}} -> n == x_pr.number
             _ -> false
           end) >= 1,
           "expected X to be retargeted to main after B merged; got: #{inspect(final_retargets)}"

    # ---- Scenario D: cascade rewind ----
    # A returns to Todo (a reviewer un-merged or rewound it). Both Y and X
    # depend on A and are currently In Review → both should cascade.
    FakeHuman.rewind!(issues.a, state_ids.todo, manifest_path: manifest_path)
    a_rewound = %{issues.a | state: "Todo"}

    y_with_a_rewound = %{
      y_in_review
      | blocked_by: [%{id: issues.a.id, identifier: issues.a.identifier, state: "Todo"}]
    }

    x_with_a_rewound = %{
      x_in_review_after_b
      | blocked_by: [
          %{id: issues.a.id, identifier: issues.a.identifier, state: "Todo"},
          %{id: issues.b.id, identifier: issues.b.identifier, state: "Done"}
        ]
    }

    # Tick 1 primes previous-state cache (A was Done before the rewind).
    {:ok, _} = Reconciler.run([y_in_review, x_in_review_after_b], [a_done, b_done], cfg)

    # Tick 2: A → Todo → cascade events for both Y and X.
    {:ok, e2} =
      Reconciler.run([y_with_a_rewound, x_with_a_rewound], [a_rewound, b_done], cfg)

    cascade_events = Enum.filter(e2, &match?({:cascade_pending, _, _}, &1))

    assert length(cascade_events) >= 2,
           "expected cascade events for both Y and X; got: #{inspect(cascade_events)}"

    cascades = Reconciler.drain_cascades()

    issues_by_id = %{
      issues.y.id => y_with_a_rewound,
      issues.x.id => x_with_a_rewound,
      issues.a.id => a_rewound,
      issues.b.id => b_done
    }

    parent = self()

    apply_fn = fn identifier, _new_state ->
      issue =
        cond do
          identifier == issues.y.identifier -> issues.y
          identifier == issues.x.identifier -> issues.x
          true -> nil
        end

      if issue do
        FakeHuman.rewind!(issue, state_ids.todo, manifest_path: manifest_path)
        send(parent, {:rewound, identifier})
      end

      :ok
    end

    comment_fn = fn _identifier, _body -> :ok end
    lookup = fn id -> Map.fetch(issues_by_id, id) end

    decisions = Cascade.apply_cascades(cascades, lookup, apply_fn, comment_fn)
    rewinds = Enum.filter(decisions, &match?({:rewind, _, _}, &1))

    assert length(rewinds) >= 2,
           "expected both Y and X to rewind; got: #{inspect(decisions)}"

    assert_receive {:rewound, _}, 5_000
    assert_receive {:rewound, _}, 5_000

    assert issue_state_type!(issues.y.id) == "unstarted"
    assert issue_state_type!(issues.x.id) == "unstarted"

    # ---- Scenario E: feedback loop ----
    # Re-dispatch Y on main (A is Todo, but the detector test only needs Y to
    # have a workpad; we set base=main to bypass blocker logic for this slice).
    MockAgent.dispatch!(issues.y, "main", repo,
      in_review_state_id: state_ids.in_review,
      manifest_path: manifest_path
    )

    FakeHuman.request_changes!(issues.y, "fix the regex on line 42 — empty inputs explode",
      manifest_path: manifest_path
    )

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

    assert {:feedback, [_ | _] = feedback} = Detector.evaluate(y_with_comments)

    assert Enum.any?(feedback, &(&1.body =~ "regex"))

    FakeHuman.rewind!(issues.y, state_ids.todo, manifest_path: manifest_path)
    assert issue_state_type!(issues.y.id) == "unstarted"

    # ---- Scenario F: conflict integration ----
    # Re-dispatch A and B with content that touches the same file. The
    # IntegrationBuilder must report :conflict and ConflictFallback must
    # produce an in-tree merge worktree where the agent would resolve.
    #
    # X's branch was created locally in scenario A; ConflictFallback's
    # `git worktree add -b feat/stacking-x` would fail if that branch still
    # exists. Drop it from the source clone first.
    {_out, _code} =
      System.cmd("git", ["-C", repo.path, "branch", "-D", issues.x.branch_name],
        stderr_to_stdout: true
      )

    {_out, _code} =
      System.cmd("git", ["-C", repo.path, "push", "origin", "--delete", issues.x.branch_name],
        stderr_to_stdout: true
      )

    FakeHuman.rewind!(issues.a, state_ids.todo, manifest_path: manifest_path)
    FakeHuman.rewind!(issues.b, state_ids.todo, manifest_path: manifest_path)

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

    a_conflict_in_review = %{issues.a | state: "In Review"}
    b_conflict_in_review = %{issues.b | state: "In Review"}

    x_for_conflict = %{
      issues.x
      | blocked_by: [
          %{id: issues.a.id, identifier: issues.a.identifier, state: "In Review"},
          %{id: issues.b.id, identifier: issues.b.identifier, state: "In Review"}
        ]
    }

    conflict_integration_branch =
      "symphony/integration/" <> String.downcase(issues.x.identifier)

    assert {:ok, {:integration, ^conflict_integration_branch}} =
             BaseResolver.resolve(x_for_conflict, [a_conflict_in_review, b_conflict_in_review], cfg)

    assert {:conflict, files} =
             IntegrationBuilder.rebuild(
               repo_for_builder,
               conflict_integration_branch,
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

    {status, 0} =
      System.cmd("git", ["-C", prepared_path, "status", "--porcelain"], stderr_to_stdout: true)

    assert status =~ "shared.txt"

    E2EManifest.append!(manifest_path, %{
      event: "conflict_fallback_prepared",
      issue: issues.x.identifier,
      worktree: prepared_path,
      conflict_files: files
    })

    # ---- Tidy up: move every issue to a terminal state so the operator's
    # Linear workspace doesn't accumulate residue. The project itself is
    # completed in on_exit, but issues stay attached.
    for issue <- [issues.a, issues.b, issues.x, issues.y] do
      FakeHuman.rewind!(issue, state_ids.done, manifest_path: manifest_path)
    end

    # ---- Final manifest sanity ----
    records = E2EManifest.read!(manifest_path)
    events = Enum.map(records, & &1["event"])

    for required <- [
          "setup",
          "agent_dispatch",
          "human_merge",
          "human_rewind",
          "human_request_changes",
          "conflict_fallback_prepared"
        ] do
      assert required in events, "manifest missing #{required}"
    end

    Logger.info("manifest path: #{manifest_path}")
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

  defp parse_iso(nil), do: nil

  defp parse_iso(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
