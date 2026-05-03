defmodule SymphonyElixir.PR.Router do
  @moduledoc """
  Keeps an issue's PR base correct as its blockers move through `In Review`
  → `Done`.

  Composes `BaseResolver` (the desired base) with `Forge.GitHub` (the actual
  GitHub state). Idempotent — calling twice with the same state is a no-op.

  The Reconciler (D4) is the typical caller and passes the GitHub
  `owner/name` slug explicitly. Callers must filter `blockers` to "still
  contributing" before invoking — i.e. drop already-merged blockers from the
  list. `BaseResolver` then sees an accurate hard-dep count.
  """

  alias SymphonyElixir.Branches.BaseResolver
  alias SymphonyElixir.Forge.GitHub
  alias SymphonyElixir.Linear.Issue

  @type result :: :ok | {:noop, :pr_not_open} | {:error, term()}

  @doc """
  Ensures the PR for `issue.branch_name` targets the base implied by the
  current `blockers` snapshot.
  """
  @spec ensure_pr_base_correct(Issue.t(), [Issue.t()], map(), keyword()) :: result()
  def ensure_pr_base_correct(%Issue{} = issue, blockers, settings, opts \\ []) do
    gh_repo = Keyword.fetch!(opts, :gh_repo)
    branch_name = Keyword.get(opts, :branch_name, issue.branch_name)

    with {:ok, base_decision} <- BaseResolver.resolve(issue, blockers, settings),
         {:ok, branch} <- ensure_branch(branch_name),
         {:ok, current_pr} <- GitHub.pr_for_branch(gh_repo, branch) do
      apply_decision(current_pr, base_decision, gh_repo)
    end
  end

  defp ensure_branch(name) when is_binary(name) and name != "", do: {:ok, name}
  defp ensure_branch(_), do: {:error, :missing_branch_name}

  defp apply_decision(nil, _decision, _gh_repo), do: {:noop, :pr_not_open}

  defp apply_decision(%{base: current_base} = pr, decision, gh_repo) do
    desired_base = base_of(decision)

    cond do
      desired_base == current_base ->
        :ok

      true ->
        with :ok <- GitHub.retarget_pr(gh_repo, pr.number, desired_base) do
          maybe_delete_old_integration_branch(gh_repo, current_base, desired_base)
        end
    end
  end

  defp base_of({:main, branch}), do: branch
  defp base_of({:single_blocker, branch}), do: branch
  defp base_of({:integration, branch}), do: branch

  defp maybe_delete_old_integration_branch(gh_repo, old_base, new_base) do
    if old_base != new_base and integration_branch?(old_base) do
      _ = GitHub.delete_branch(gh_repo, old_base)
    end

    :ok
  end

  defp integration_branch?(name) when is_binary(name) do
    String.starts_with?(name, "symphony/integration/")
  end

  defp integration_branch?(_), do: false
end
