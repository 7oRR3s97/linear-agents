defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings(),
         :ok <- validate_semantics(settings) do
      validate_stacking(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end

  defp validate_stacking(%{stacking: %{enabled: true}} = settings) do
    with :ok <- validate_repositories(settings),
         :ok <- validate_agent_autonomy(settings),
         :ok <- validate_unblock_states(settings),
         :ok <- validate_gh_cli() do
      :ok
    end
  end

  defp validate_stacking(_settings), do: :ok

  defp validate_repositories(%{repositories: repos}) do
    paths = repos.paths || %{}
    by_label_handles = repos.by_label |> Map.values()
    default_handles = if is_binary(repos.default), do: [repos.default], else: []

    referenced = (by_label_handles ++ default_handles) |> Enum.uniq()

    cond do
      Enum.empty?(paths) ->
        {:error, :stacking_repositories_paths_missing}

      missing = Enum.find(referenced, fn handle -> not Map.has_key?(paths, handle) end) ->
        {:error, {:stacking_repository_handle_missing, missing}}

      bad =
            Enum.find(paths, fn {_handle, path} ->
              not (is_binary(path) and File.dir?(path) and File.dir?(Path.join(path, ".git")))
            end) ->
        {handle, path} = bad
        {:error, {:stacking_repository_path_invalid, handle, path}}

      true ->
        :ok
    end
  end

  defp validate_agent_autonomy(%{agent_autonomy: autonomy}) do
    cond do
      not is_binary(autonomy.label_dispatchable) or autonomy.label_dispatchable == "" ->
        {:error, :stacking_label_dispatchable_required}

      not is_binary(autonomy.label_human_only) or autonomy.label_human_only == "" ->
        {:error, :stacking_label_human_only_required}

      autonomy.label_dispatchable == autonomy.label_human_only ->
        {:error, :stacking_autonomy_labels_must_differ}

      true ->
        :ok
    end
  end

  defp validate_unblock_states(%{stacking: stacking, tracker: tracker}) do
    permitted =
      MapSet.new((tracker.active_states || []) ++ (tracker.terminal_states || []))

    case Enum.find(stacking.unblock_states || [], fn state -> not MapSet.member?(permitted, state) end) do
      nil -> :ok
      bad -> {:error, {:stacking_unblock_state_unknown, bad}}
    end
  end

  defp validate_gh_cli do
    case System.find_executable("gh") do
      nil ->
        {:error, :stacking_gh_cli_missing}

      _ ->
        case System.cmd("gh", ["auth", "status"], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, _code} -> {:error, {:stacking_gh_cli_unauthenticated, String.trim(output)}}
        end
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
