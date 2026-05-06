defmodule SymphonyElixir.WorkspaceWorktreeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitFixture
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Workspace

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    bare = GitFixture.bare_repo(tmp)
    source = GitFixture.working_clone(bare, tmp, "src")
    workspace_root = Path.join(tmp, "ws")
    File.mkdir_p!(workspace_root)

    workflow_path = Path.join(tmp, "WORKFLOW.md")
    write_workflow!(workflow_path, source, workspace_root, true)
    Workflow.set_workflow_file_path(workflow_path)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :workflow_file_path)
    end)

    {:ok, bare: bare, source: source, workspace_root: workspace_root, workflow_path: workflow_path}
  end

  test "stacking enabled: create_worktree_for_issue/2 produces a worktree", %{
    workspace_root: ws
  } do
    issue = %Issue{identifier: "PES-1", labels: ["repo:src", "AFK"], branch_name: "feat/x"}

    assert {:ok, path} = Workspace.create_worktree_for_issue(issue, fetch: false)

    assert File.dir?(path)
    assert File.exists?(Path.join(path, ".git"))
    assert String.starts_with?(path, Path.expand(ws))

    {branch, 0} = System.cmd("git", ["-C", path, "branch", "--show-current"])
    assert String.trim(branch) == "feat/x"
  end

  test "stacking enabled: missing branch_name returns error" do
    issue = %Issue{identifier: "PES-1", labels: ["repo:src", "AFK"], branch_name: nil}

    assert {:error, :missing_branch_name} = Workspace.create_worktree_for_issue(issue, fetch: false)
  end

  test "stacking enabled: workspace.root with leading ~ is expanded for git worktree add", %{
    source: source,
    workflow_path: workflow_path,
    workspace_root: ws
  } do
    relative_under_home = Path.relative_to(ws, System.user_home!())

    cond do
      relative_under_home == ws ->
        # tmp dir is not under $HOME — skip rather than break the assumption.
        :ok

      true ->
        write_workflow!(workflow_path, source, "~/" <> relative_under_home, true)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

        issue = %Issue{identifier: "PES-EXPAND", labels: ["repo:src", "AFK"], branch_name: "feat/expand"}

        assert {:ok, path} = Workspace.create_worktree_for_issue(issue, fetch: false)

        refute path =~ ~r{/~/}
        assert String.starts_with?(path, Path.expand(ws))
        assert File.exists?(Path.join(path, ".git"))
    end
  end

  test "stacking enabled: removes only the worktree, not the source clone", %{
    source: source
  } do
    issue = %Issue{identifier: "PES-2", labels: ["repo:src", "AFK"], branch_name: "feat/y"}
    {:ok, path} = Workspace.create_worktree_for_issue(issue, fetch: false)

    assert :ok = Workspace.remove_worktree_for_issue(issue)
    refute File.dir?(path)
    assert File.dir?(source)
  end

  test "stacking disabled: falls through to legacy mkdir path", %{
    source: source,
    workspace_root: ws,
    workflow_path: workflow_path
  } do
    write_workflow!(workflow_path, source, ws, false)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    issue = %Issue{identifier: "PES-DISABLED", labels: ["repo:src", "AFK"], branch_name: "feat/z"}

    assert {:ok, path} = Workspace.create_worktree_for_issue(issue)
    assert File.dir?(path)
    refute File.exists?(Path.join(path, ".git"))
    assert String.starts_with?(path, Path.expand(ws))
  end

  defp write_workflow!(path, source, workspace_root, stacking_enabled) do
    File.write!(path, """
    ---
    tracker:
      kind: linear
      api_key: token
      project_slug: project
      active_states: ["Todo", "In Progress", "In Review"]
      terminal_states: ["Done", "Canceled"]
    polling:
      interval_ms: 30000
    workspace:
      root: #{workspace_root}
    agent:
      max_concurrent_agents: 1
      max_turns: 1
    codex:
      command: codex app-server
    repositories:
      default: src
      by_label:
        "repo:src": src
      paths:
        src: #{source}
      remote: origin
      default_base_branch: main
    agent_autonomy:
      label_dispatchable: "AFK"
      label_human_only: "HITL"
      default_when_missing: "HITL"
    stacking:
      enabled: #{stacking_enabled}
      unblock_states: ["In Review", "Done"]
    ---
    Prompt body.
    """)
  end
end
