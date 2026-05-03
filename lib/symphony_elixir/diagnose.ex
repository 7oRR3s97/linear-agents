defmodule SymphonyElixir.Diagnose do
  @moduledoc """
  Pure rendering for `mix symphony.diagnose`.

  The mix task is a thin shell that fetches inputs (issue, blockers, PR
  state) and hands them to `render/1`. Keeping the formatting pure makes it
  easy to unit-test the output shape without touching Linear or GitHub.
  """

  alias SymphonyElixir.Branches.BaseResolver
  alias SymphonyElixir.Deps.DispatchGuard
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Repos

  @type pr_summary :: %{number: pos_integer(), base: String.t(), head: String.t(), state: String.t()}

  @type input :: %{
          required(:issue) => Issue.t(),
          required(:blockers) => [Issue.t()],
          required(:settings) => map(),
          required(:pr) => pr_summary() | nil | {:error, term()}
        }

  @doc """
  Renders the diagnostic report as a single string suitable for stdout.
  """
  @spec render(input()) :: String.t()
  def render(%{issue: issue, blockers: blockers, settings: settings, pr: pr}) do
    repos_config = repos_config_from_settings(settings)

    repo_section =
      case Repos.for_issue(issue, repos_config) do
        {:ok, %{handle: handle, path: path, remote: remote, default_base: base}} ->
          [
            "  handle:        #{handle}",
            "  path:          #{path}",
            "  remote:        #{remote}",
            "  default_base:  #{base}"
          ]

        {:error, reason} ->
          ["  error:         #{inspect(reason)}"]
      end

    snapshot = %{
      blockers_by_id: Map.new(blockers, fn b -> {b.id, b} end),
      branch_exists?: fn _handle, _branch -> true end
    }

    dispatch_result = DispatchGuard.evaluate(issue, snapshot, settings)
    base_result = BaseResolver.resolve(issue, blockers, settings)

    [
      "# Symphony Diagnose: #{issue.identifier || "<unknown>"}",
      "",
      "## Issue",
      "  identifier:    #{issue.identifier}",
      "  state:         #{issue.state}",
      "  branch_name:   #{issue.branch_name || "<none>"}",
      "  labels:        #{format_labels(issue.labels)}",
      "",
      "## Repo Routing"
    ] ++
      repo_section ++
      [
        "",
        "## Blockers (#{length(blockers)})"
      ] ++
      blocker_lines(blockers, repos_config, issue) ++
      [
        "",
        "## DispatchGuard",
        "  result:        #{format_eval(dispatch_result)}",
        "",
        "## BaseResolver",
        "  result:        #{format_base(base_result)}",
        "",
        "## PR",
        format_pr(pr),
        ""
      ]
      |> Enum.join("\n")
  end

  defp repos_config_from_settings(%{repositories: repos}) when is_map(repos) do
    case repos do
      %_{} = struct -> Map.from_struct(struct)
      other -> other
    end
  end

  defp repos_config_from_settings(_), do: %{}

  defp blocker_lines([], _repos, _issue), do: ["  (none)"]

  defp blocker_lines(blockers, repos_config, issue) do
    issue_handle =
      case Repos.for_issue(issue, repos_config) do
        {:ok, %{handle: h}} -> h
        _ -> nil
      end

    blockers
    |> Enum.sort_by(& &1.identifier)
    |> Enum.flat_map(fn blocker ->
      classification =
        case Repos.for_issue(blocker, repos_config) do
          {:ok, %{handle: ^issue_handle}} when not is_nil(issue_handle) -> "hard (same repo)"
          {:ok, %{handle: other}} -> "soft (cross-repo: #{other})"
          _ -> "unresolvable"
        end

      [
        "  - #{blocker.identifier}",
        "      id:           #{blocker.id}",
        "      state:        #{blocker.state}",
        "      branch_name:  #{blocker.branch_name || "<none>"}",
        "      classify:     #{classification}"
      ]
    end)
  end

  defp format_labels(labels) when is_list(labels) and labels != [], do: Enum.join(labels, ", ")
  defp format_labels(_), do: "<none>"

  defp format_eval(:ok), do: ":ok"
  defp format_eval({:skip, reason}), do: "{:skip, #{inspect(reason)}}"
  defp format_eval(other), do: inspect(other)

  defp format_base({:ok, {:main, branch}}), do: "{:main, #{inspect(branch)}}"
  defp format_base({:ok, {:single_blocker, branch}}), do: "{:single_blocker, #{inspect(branch)}}"
  defp format_base({:ok, {:integration, branch}}), do: "{:integration, #{inspect(branch)}}"
  defp format_base({:error, reason}), do: "{:error, #{inspect(reason)}}"
  defp format_base(other), do: inspect(other)

  defp format_pr(nil), do: "  (no PR yet)"

  defp format_pr({:error, reason}), do: "  error: #{inspect(reason)}"

  defp format_pr(%{} = pr) do
    [
      "  number:        ##{pr.number}",
      "  base:          #{pr.base}",
      "  head:          #{pr.head}",
      "  state:         #{pr.state}"
    ]
    |> Enum.join("\n")
  end
end
