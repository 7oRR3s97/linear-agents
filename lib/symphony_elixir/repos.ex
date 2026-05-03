defmodule SymphonyElixir.Repos do
  @moduledoc """
  Pure registry that resolves Linear issues to a configured repository handle.

  Reads the `repositories` block from the parsed `WORKFLOW.md` config. No git,
  GitHub, or Linear I/O happens here — every operation is a deterministic
  function of the inputs.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @label_prefix "repo:"

  @type repo_handle :: String.t()

  @type repositories_config :: %{
          optional(:default) => String.t() | nil,
          optional(:by_label) => %{String.t() => String.t()},
          optional(:paths) => %{String.t() => String.t()},
          optional(:remote) => String.t() | nil,
          optional(:default_base_branch) => String.t() | nil
        }

  @type resolution :: %{
          handle: repo_handle(),
          path: String.t(),
          remote: String.t(),
          default_base: String.t()
        }

  @type for_issue_error ::
          :stacking_disabled | :no_repo | :ambiguous | {:invalid_workflow_config, term()}

  @doc """
  Resolves an issue to a configured repository using the live `WORKFLOW.md` config.
  """
  @spec for_issue(Issue.t()) :: {:ok, resolution()} | {:error, for_issue_error()}
  def for_issue(%Issue{} = issue) do
    case Config.settings() do
      {:ok, settings} -> for_issue(issue, repositories_from_settings(settings))
      {:error, reason} -> {:error, {:invalid_workflow_config, reason}}
    end
  end

  @doc """
  Resolves an issue to a configured repository.

  Looks at every label of the form `repo:*` (case-insensitive). When exactly
  one matches a key in `by_label`, that handle wins. When none match, the
  configured `default` is used. Multiple matches are an error — the operator
  must fix the issue's labels.
  """
  @spec for_issue(Issue.t(), repositories_config() | nil) ::
          {:ok, resolution()} | {:error, for_issue_error()}
  def for_issue(_issue, nil), do: {:error, :stacking_disabled}

  def for_issue(%Issue{labels: labels}, config) when is_map(config) do
    by_label = config_map(config, :by_label)
    matches = matching_handles(labels, by_label)

    case matches do
      [handle] ->
        finalize(handle, config)

      [] ->
        case config_default(config) do
          nil -> {:error, :no_repo}
          handle -> finalize(handle, config)
        end

      _ ->
        {:error, :ambiguous}
    end
  end

  @doc """
  Returns the local filesystem path for a configured handle.
  """
  @spec path(repo_handle(), repositories_config()) :: {:ok, String.t()} | {:error, :no_repo}
  def path(handle, config) when is_binary(handle) and is_map(config) do
    case Map.fetch(config_map(config, :paths), handle) do
      {:ok, path} when is_binary(path) -> {:ok, path}
      _ -> {:error, :no_repo}
    end
  end

  @doc """
  Returns the configured git remote name (defaults to "origin").
  """
  @spec remote(repositories_config()) :: String.t()
  def remote(config) when is_map(config) do
    case Map.get(config, :remote) || Map.get(config, "remote") do
      value when is_binary(value) and value != "" -> value
      _ -> "origin"
    end
  end

  @doc """
  Returns the configured default base branch (defaults to "main").
  """
  @spec default_base(repositories_config()) :: String.t()
  def default_base(config) when is_map(config) do
    case Map.get(config, :default_base_branch) || Map.get(config, "default_base_branch") do
      value when is_binary(value) and value != "" -> value
      _ -> "main"
    end
  end

  defp matching_handles(labels, by_label) when is_list(labels) and is_map(by_label) do
    normalized_by_label =
      Map.new(by_label, fn {label, handle} -> {String.downcase(label), handle} end)

    labels
    |> Enum.filter(&repo_label?/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn label ->
      case Map.get(normalized_by_label, label) do
        nil -> []
        handle -> [handle]
      end
    end)
    |> Enum.uniq()
  end

  defp repo_label?(label) when is_binary(label) do
    label
    |> String.downcase()
    |> String.starts_with?(@label_prefix)
  end

  defp repo_label?(_label), do: false

  defp finalize(handle, config) do
    case path(handle, config) do
      {:ok, path} ->
        {:ok,
         %{
           handle: handle,
           path: path,
           remote: remote(config),
           default_base: default_base(config)
         }}

      {:error, :no_repo} ->
        {:error, :no_repo}
    end
  end

  defp config_map(config, key) do
    case Map.get(config, key) || Map.get(config, to_string(key)) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp config_default(config) do
    case Map.get(config, :default) || Map.get(config, "default") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp repositories_from_settings(%{repositories: repos}) when is_struct(repos) do
    %{
      default: repos.default,
      by_label: repos.by_label || %{},
      paths: repos.paths || %{},
      remote: repos.remote,
      default_base_branch: repos.default_base_branch
    }
  end

  defp repositories_from_settings(_settings), do: nil
end
