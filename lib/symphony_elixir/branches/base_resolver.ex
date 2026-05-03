defmodule SymphonyElixir.Branches.BaseResolver do
  @moduledoc """
  Pure logic that, given an issue and its blocker snapshot, returns the base
  ref the worktree should branch from (and the PR base, which is the same).

  No git, GitHub, or Linear I/O.

  Cross-repo blockers are filtered out: their gating is enforced by
  `Symphony.Deps.DispatchGuard` (C2), not the base ref. Only same-repo
  blockers — hard deps — contribute to the result.

  ## Result table

  | Open hard-dep blockers | Result |
  | --- | --- |
  | 0 | `{:main, default_base_branch}` |
  | 1 | `{:single_blocker, blocker.branch_name}` |
  | 2+ | `{:integration, rendered_template}` |

  The integration branch name is rendered from
  `stacking.integration_branch_template` (Liquid) with the dependent issue as
  the only template variable.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Repos

  @type result ::
          {:ok, {:main, String.t()}}
          | {:ok, {:single_blocker, String.t()}}
          | {:ok, {:integration, String.t()}}
          | {:error, error_reason()}

  @type error_reason ::
          :issue_repo_unresolvable
          | {:blocker_branch_missing, String.t()}
          | {:integration_template_invalid, term()}

  @type settings :: %{
          required(:repositories) => map(),
          required(:stacking) => map()
        }

  @doc """
  Resolves the base ref for `issue` given its full blocker issues.
  """
  @spec resolve(Issue.t(), [Issue.t()], settings()) :: result()
  def resolve(%Issue{} = issue, blockers, settings) when is_list(blockers) and is_map(settings) do
    repos_config = repositories_config(settings)

    with {:ok, issue_resolution} <- resolve_issue_repo(issue, repos_config),
         {:ok, hard_blockers} <- classify_blockers(blockers, issue_resolution.handle, repos_config) do
      decide_base(hard_blockers, issue, issue_resolution, settings)
    end
  end

  defp repositories_config(settings) do
    repos = Map.get(settings, :repositories) || %{}
    Map.new(repos)
  end

  defp resolve_issue_repo(issue, repos_config) do
    case Repos.for_issue(issue, repos_config) do
      {:ok, resolution} -> {:ok, resolution}
      {:error, _reason} -> {:error, :issue_repo_unresolvable}
    end
  end

  defp classify_blockers(blockers, issue_handle, repos_config) do
    sorted = Enum.sort_by(blockers, & &1.identifier)

    Enum.reduce_while(sorted, {:ok, []}, fn blocker, {:ok, hard_acc} ->
      case Repos.for_issue(blocker, repos_config) do
        {:ok, %{handle: ^issue_handle}} ->
          if is_binary(blocker.branch_name) and blocker.branch_name != "" do
            {:cont, {:ok, [blocker | hard_acc]}}
          else
            {:halt, {:error, {:blocker_branch_missing, blocker.identifier}}}
          end

        _other_repo_or_unresolvable ->
          {:cont, {:ok, hard_acc}}
      end
    end)
    |> case do
      {:ok, hard_acc} -> {:ok, Enum.reverse(hard_acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decide_base([], _issue, issue_resolution, _settings) do
    {:ok, {:main, issue_resolution.default_base}}
  end

  defp decide_base([%Issue{branch_name: branch}], _issue, _resolution, _settings) do
    {:ok, {:single_blocker, branch}}
  end

  defp decide_base(blockers, issue, _resolution, settings) when length(blockers) >= 2 do
    template = get_in(settings, [:stacking, :integration_branch_template])

    case render_integration_template(template, issue) do
      {:ok, name} -> {:ok, {:integration, name}}
      {:error, reason} -> {:error, {:integration_template_invalid, reason}}
    end
  end

  defp render_integration_template(template, issue) when is_binary(template) do
    try do
      parsed = Solid.parse!(template)
      vars = %{"issue" => issue_template_vars(issue)}
      rendered = Solid.render!(parsed, vars, strict_variables: true, strict_filters: true)
      {:ok, rendered |> IO.iodata_to_binary() |> String.trim()}
    rescue
      e -> {:error, e}
    end
  end

  defp render_integration_template(_template, _issue) do
    {:error, :template_missing}
  end

  defp issue_template_vars(%Issue{} = issue) do
    %{
      "id" => issue.id,
      "identifier" => issue.identifier,
      "title" => issue.title,
      "branchName" => issue.branch_name,
      "branch_name" => issue.branch_name,
      "state" => issue.state,
      "url" => issue.url
    }
  end
end
