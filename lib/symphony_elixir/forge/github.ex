defmodule SymphonyElixir.Forge.GitHub do
  @moduledoc """
  Behaviour for GitHub forge operations needed by the stacked-PR pipeline.

  The default implementation (`SymphonyElixir.Forge.GitHub.GhClient`) shells
  out to the `gh` CLI in the operator's `$PATH`. Tests can substitute a stub
  via:

      Application.put_env(:symphony_elixir, :github_forge, MyTestStub)

  ## Repo argument

  `repo` is a `"owner/name"` string, e.g. `"7oRR3s97/linear-agents"`.

  ## Error normalization

  All callbacks return either `{:ok, value}` / `:ok` or `{:error, reason}`
  where `reason` is either an atom (`:not_found`, `:rate_limited`,
  `:forge_unavailable`) or a `{:gh, output}` tuple for unexpected failures.
  """

  @type repo :: String.t()
  @type branch :: String.t()
  @type pr_number :: pos_integer()

  @type pr_summary :: %{
          number: pos_integer(),
          base: String.t(),
          head: String.t(),
          state: String.t(),
          merged: boolean()
        }

  @callback pr_state(repo(), branch()) :: {:ok, pr_summary()} | {:error, term()}
  @callback pr_for_branch(repo(), branch()) :: {:ok, pr_summary() | nil} | {:error, term()}
  @callback retarget_pr(repo(), pr_number(), String.t()) :: :ok | {:error, term()}
  @callback delete_branch(repo(), branch()) :: :ok | {:error, term()}

  @doc "Returns the configured implementation, defaulting to the gh CLI client."
  @spec impl() :: module()
  def impl do
    Application.get_env(:symphony_elixir, :github_forge, __MODULE__.GhClient)
  end

  @spec pr_state(repo(), branch()) :: {:ok, pr_summary()} | {:error, term()}
  def pr_state(repo, branch), do: impl().pr_state(repo, branch)

  @spec pr_for_branch(repo(), branch()) :: {:ok, pr_summary() | nil} | {:error, term()}
  def pr_for_branch(repo, branch), do: impl().pr_for_branch(repo, branch)

  @spec retarget_pr(repo(), pr_number(), String.t()) :: :ok | {:error, term()}
  def retarget_pr(repo, pr_number, new_base), do: impl().retarget_pr(repo, pr_number, new_base)

  @spec delete_branch(repo(), branch()) :: :ok | {:error, term()}
  def delete_branch(repo, branch), do: impl().delete_branch(repo, branch)
end
