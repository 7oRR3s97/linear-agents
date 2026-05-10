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
