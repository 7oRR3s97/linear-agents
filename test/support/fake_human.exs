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
    {:ok, pr} = GitHubStub.pr_for_branch(repo, branch)
    pr
  end
end
