defmodule SymphonyElixir.ConfigRuntimeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Workflow

  setup do
    workflow_root =
      Path.join(System.tmp_dir!(), "symphony-runtime-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workflow_root)
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")
    Workflow.set_workflow_file_path(workflow_file)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :workflow_file_path)
      File.rm_rf(workflow_root)
    end)

    {:ok, workflow_file: workflow_file}
  end

  test "claude_code runtime fails preflight when claude binary is missing", %{
    workflow_file: workflow_file
  } do
    File.write!(workflow_file, """
    ---
    tracker:
      kind: linear
      api_key: token
      project_slug: project
    polling:
      interval_ms: 30000
    workspace:
      root: /tmp/x
    agent:
      max_concurrent_agents: 1
      max_turns: 1
      runtime: claude_code
    claude_code:
      command: nonexistent-claude-binary-#{System.unique_integer([:positive])}
    ---
    Prompt body.
    """)

    if Process.whereis(SymphonyElixir.WorkflowStore),
      do: SymphonyElixir.WorkflowStore.force_reload()

    assert {:error, {:claude_code_cli_missing, _}} = Config.validate!()
  end

  test "claude_code runtime passes preflight when claude binary is on PATH", %{
    workflow_file: workflow_file
  } do
    # Use /bin/echo as a stand-in — guaranteed to be on PATH on POSIX systems.
    File.write!(workflow_file, """
    ---
    tracker:
      kind: linear
      api_key: token
      project_slug: project
    polling:
      interval_ms: 30000
    workspace:
      root: /tmp/x
    agent:
      max_concurrent_agents: 1
      max_turns: 1
      runtime: claude_code
    claude_code:
      command: echo
    ---
    Prompt body.
    """)

    if Process.whereis(SymphonyElixir.WorkflowStore),
      do: SymphonyElixir.WorkflowStore.force_reload()

    assert :ok = Config.validate!()
  end

  test "codex runtime is the default and skips claude preflight", %{workflow_file: workflow_file} do
    File.write!(workflow_file, """
    ---
    tracker:
      kind: linear
      api_key: token
      project_slug: project
    polling:
      interval_ms: 30000
    workspace:
      root: /tmp/x
    agent:
      max_concurrent_agents: 1
      max_turns: 1
    codex:
      command: codex app-server
    ---
    Prompt body.
    """)

    if Process.whereis(SymphonyElixir.WorkflowStore),
      do: SymphonyElixir.WorkflowStore.force_reload()

    assert :ok = Config.validate!()
  end
end
