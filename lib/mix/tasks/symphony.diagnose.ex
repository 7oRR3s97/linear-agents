defmodule Mix.Tasks.Symphony.Diagnose do
  @moduledoc """
  Print what `BaseResolver` and `DispatchGuard` would produce for a given
  Linear issue right now.

      mix symphony.diagnose PES-118

  Read-only — never writes to Linear, GitHub, or local git state.
  """

  @shortdoc "Diagnose stacking decisions for a Linear issue"

  use Mix.Task

  alias SymphonyElixir.Config
  alias SymphonyElixir.Diagnose
  alias SymphonyElixir.Forge.GitHub
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Repos

  @impl true
  def run(argv) do
    case argv do
      [identifier] when is_binary(identifier) ->
        Mix.Task.run("app.start")
        do_run(identifier)

      _ ->
        Mix.shell().error("Usage: mix symphony.diagnose <issue-identifier>")
        Mix.raise("missing argument")
    end
  end

  defp do_run(identifier) do
    settings = Config.settings!()
    settings_map = settings_to_map(settings)

    case fetch_issue_by_identifier(identifier) do
      {:ok, issue} ->
        blockers = fetch_blockers(issue)

        pr =
          case lookup_pr(issue, settings_map) do
            {:ok, pr} -> pr
            {:error, reason} -> {:error, reason}
            other -> other
          end

        report =
          Diagnose.render(%{
            issue: issue,
            blockers: blockers,
            settings: settings_map,
            pr: pr
          })

        Mix.shell().info(report)

      {:error, :not_found} ->
        Mix.shell().error("Issue #{identifier} not found in active states.")
        Mix.shell().error("(diagnose currently fetches via the active-states query;")
        Mix.shell().error(" issues in `Backlog` or terminal states are not visible.)")

      {:error, reason} ->
        Mix.shell().error("Failed to fetch issue: #{inspect(reason)}")
    end
  end

  defp fetch_issue_by_identifier(identifier) do
    case Client.fetch_candidate_issues() do
      {:ok, issues} ->
        case Enum.find(issues, fn i -> i.identifier == identifier end) do
          nil -> {:error, :not_found}
          issue -> {:ok, issue}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_blockers(issue) do
    blocker_ids = for b <- issue.blocked_by || [], is_binary(b.id), do: b.id

    case Client.fetch_issue_states_by_ids(blocker_ids) do
      {:ok, blockers} -> blockers
      {:error, _reason} -> []
    end
  end

  defp lookup_pr(issue, settings_map) do
    repos_config = settings_map.repositories

    with {:ok, %{path: path}} <- Repos.for_issue(issue, repos_config),
         branch when is_binary(branch) and branch != "" <- issue.branch_name,
         {:ok, slug} <- gh_slug_for(path) do
      GitHub.pr_for_branch(slug, branch)
    else
      {:error, reason} -> {:error, reason}
      _ -> nil
    end
  end

  defp gh_slug_for(path) do
    case System.cmd("git", ["-C", path, "remote", "get-url", "origin"], stderr_to_stdout: true) do
      {url, 0} ->
        case parse_slug(String.trim(url)) do
          slug when is_binary(slug) -> {:ok, slug}
          _ -> {:error, {:slug_parse_failed, String.trim(url)}}
        end

      {output, code} ->
        {:error, {:remote_url_failed, code, String.trim(output)}}
    end
  end

  # Accepts the standard `github.com` host as well as `~/.ssh/config`
  # aliases like `github.com-work` so multi-account setups still resolve
  # the `owner/repo` slug from `git remote get-url origin`.
  @doc false
  @spec parse_slug(String.t()) :: String.t() | nil
  def parse_slug(url) do
    cond do
      Regex.match?(~r{github\.com[\w.-]*[/:]([^/]+)/([^/.]+)(?:\.git)?$}, url) ->
        case Regex.run(~r{github\.com[\w.-]*[/:]([^/]+)/([^/.]+?)(?:\.git)?$}, url) do
          [_, owner, name] -> "#{owner}/#{name}"
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp settings_to_map(settings) do
    %{
      stacking: settings.stacking |> Map.from_struct(),
      agent_autonomy: settings.agent_autonomy |> Map.from_struct(),
      tracker:
        settings.tracker
        |> Map.from_struct()
        |> Map.take([:active_states, :terminal_states]),
      repositories: settings.repositories |> Map.from_struct()
    }
  end
end
