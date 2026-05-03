defmodule SymphonyElixir.ConfigStackingTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Workflow

  setup do
    workflow_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-stacking-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workflow_root)
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")
    Workflow.set_workflow_file_path(workflow_file)

    if Process.whereis(SymphonyElixir.WorkflowStore),
      do: SymphonyElixir.WorkflowStore.force_reload()

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :workflow_file_path)
      File.rm_rf(workflow_root)
    end)

    {:ok, workflow_file: workflow_file, workflow_root: workflow_root}
  end

  describe "validate!/0 with stacking.enabled = false" do
    test "is a no-op even with no repositories block", %{workflow_file: workflow_file} do
      File.write!(workflow_file, simple_workflow(stacking_enabled: false))
      reload_workflow()

      assert :ok = Config.validate!()
    end

    test "ignores repositories validation when stacking is disabled", %{workflow_file: workflow_file} do
      File.write!(
        workflow_file,
        simple_workflow(
          stacking_enabled: false,
          repositories_paths: %{"web" => "/nonexistent/path"}
        )
      )

      reload_workflow()

      assert :ok = Config.validate!()
    end
  end

  describe "validate!/0 with stacking.enabled = true" do
    test "fails when paths is empty", %{workflow_file: workflow_file} do
      File.write!(workflow_file, simple_workflow(stacking_enabled: true))
      reload_workflow()

      assert {:error, :stacking_repositories_paths_missing} = Config.validate!()
    end

    test "fails when by_label references unknown handle", %{
      workflow_file: workflow_file,
      workflow_root: workflow_root
    } do
      repo_dir = make_git_repo!(workflow_root, "web")

      File.write!(
        workflow_file,
        simple_workflow(
          stacking_enabled: true,
          repositories_default: "web",
          repositories_by_label: %{"repo:web" => "web", "repo:api" => "api"},
          repositories_paths: %{"web" => repo_dir}
        )
      )

      reload_workflow()

      assert {:error, {:stacking_repository_handle_missing, "api"}} = Config.validate!()
    end

    test "fails when configured path is not a git repo", %{
      workflow_file: workflow_file,
      workflow_root: workflow_root
    } do
      empty_dir = Path.join(workflow_root, "not-a-repo")
      File.mkdir_p!(empty_dir)

      File.write!(
        workflow_file,
        simple_workflow(
          stacking_enabled: true,
          repositories_default: "web",
          repositories_by_label: %{"repo:web" => "web"},
          repositories_paths: %{"web" => empty_dir}
        )
      )

      reload_workflow()

      assert {:error, {:stacking_repository_path_invalid, "web", _path}} = Config.validate!()
    end

    test "fails when autonomy labels are equal", %{
      workflow_file: workflow_file,
      workflow_root: workflow_root
    } do
      repo_dir = make_git_repo!(workflow_root, "web")

      File.write!(
        workflow_file,
        simple_workflow(
          stacking_enabled: true,
          repositories_default: "web",
          repositories_by_label: %{"repo:web" => "web"},
          repositories_paths: %{"web" => repo_dir},
          autonomy_dispatchable: "AGENT",
          autonomy_human_only: "AGENT"
        )
      )

      reload_workflow()

      assert {:error, :stacking_autonomy_labels_must_differ} = Config.validate!()
    end

    test "fails when unblock_states references unknown state", %{
      workflow_file: workflow_file,
      workflow_root: workflow_root
    } do
      repo_dir = make_git_repo!(workflow_root, "web")

      File.write!(
        workflow_file,
        simple_workflow(
          stacking_enabled: true,
          repositories_default: "web",
          repositories_by_label: %{"repo:web" => "web"},
          repositories_paths: %{"web" => repo_dir},
          tracker_active_states: ["Todo", "In Progress", "In Review"],
          tracker_terminal_states: ["Done"],
          stacking_unblock_states: ["In Review", "PhantomState"]
        )
      )

      reload_workflow()

      assert {:error, {:stacking_unblock_state_unknown, "PhantomState"}} = Config.validate!()
    end

    test "passes a fully valid stacking config", %{
      workflow_file: workflow_file,
      workflow_root: workflow_root
    } do
      unless System.find_executable("gh") do
        IO.puts(:stderr, "Skipping happy-path test: gh CLI not on PATH")
        :ok
      else
        repo_dir = make_git_repo!(workflow_root, "web")

        File.write!(
          workflow_file,
          simple_workflow(
            stacking_enabled: true,
            repositories_default: "web",
            repositories_by_label: %{"repo:web" => "web"},
            repositories_paths: %{"web" => repo_dir},
            tracker_active_states: ["Todo", "In Progress", "In Review"],
            tracker_terminal_states: ["Done"],
            stacking_unblock_states: ["In Review", "Done"]
          )
        )

        reload_workflow()

        result = Config.validate!()

        case result do
          :ok ->
            assert :ok = result

          {:error, {:stacking_gh_cli_unauthenticated, _}} ->
            IO.puts(:stderr, "Skipping happy-path test: gh CLI not authenticated")
            :ok

          other ->
            flunk("Expected :ok or gh-unauth error, got: #{inspect(other)}")
        end
      end
    end
  end

  defp reload_workflow do
    if Process.whereis(SymphonyElixir.WorkflowStore),
      do: SymphonyElixir.WorkflowStore.force_reload()
  end

  defp make_git_repo!(parent, name) do
    repo_dir = Path.join(parent, name)
    File.mkdir_p!(repo_dir)
    {_out, 0} = System.cmd("git", ["-C", repo_dir, "init", "-b", "main"], stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["-C", repo_dir, "config", "user.name", "Test"])
    {_out, 0} = System.cmd("git", ["-C", repo_dir, "config", "user.email", "test@example.com"])
    File.write!(Path.join(repo_dir, "README.md"), "stub\n")
    {_out, 0} = System.cmd("git", ["-C", repo_dir, "add", "README.md"])
    {_out, 0} = System.cmd("git", ["-C", repo_dir, "commit", "-m", "init"])
    repo_dir
  end

  defp simple_workflow(opts) do
    stacking_enabled = Keyword.get(opts, :stacking_enabled, false)
    default = Keyword.get(opts, :repositories_default)
    by_label = Keyword.get(opts, :repositories_by_label, %{})
    paths = Keyword.get(opts, :repositories_paths, %{})
    autonomy_dispatchable = Keyword.get(opts, :autonomy_dispatchable, "AFK")
    autonomy_human_only = Keyword.get(opts, :autonomy_human_only, "HITL")

    tracker_active = Keyword.get(opts, :tracker_active_states, ["Todo", "In Progress"])
    tracker_terminal = Keyword.get(opts, :tracker_terminal_states, ["Done", "Canceled"])
    stacking_unblock = Keyword.get(opts, :stacking_unblock_states, ["In Review", "Done"])

    """
    ---
    tracker:
      kind: linear
      api_key: token
      project_slug: project
      active_states: #{yaml_list(tracker_active)}
      terminal_states: #{yaml_list(tracker_terminal)}
    polling:
      interval_ms: 30000
    workspace:
      root: #{Path.join(System.tmp_dir!(), "symphony_workspaces")}
    agent:
      max_concurrent_agents: 1
      max_turns: 1
    codex:
      command: codex app-server
    repositories:
      default: #{yaml_or_null(default)}
      by_label:
    #{yaml_indent_map(by_label, 4)}
      paths:
    #{yaml_indent_map(paths, 4)}
    agent_autonomy:
      label_dispatchable: "#{autonomy_dispatchable}"
      label_human_only: "#{autonomy_human_only}"
      default_when_missing: "HITL"
    stacking:
      enabled: #{stacking_enabled}
      unblock_states: #{yaml_list(stacking_unblock)}
    ---
    Prompt body.
    """
  end

  defp yaml_list(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &"\"#{&1}\"") <> "]"
  end

  defp yaml_or_null(nil), do: "null"
  defp yaml_or_null(value), do: "\"#{value}\""

  defp yaml_indent_map(map, spaces) when map == %{} do
    String.duplicate(" ", spaces) <> "{}"
  end

  defp yaml_indent_map(map, spaces) do
    indent = String.duplicate(" ", spaces)

    Enum.map_join(map, "\n", fn {k, v} -> "#{indent}\"#{k}\": \"#{v}\"" end)
  end
end
