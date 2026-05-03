defmodule SymphonyElixir.Branches.ConflictFallback do
  @moduledoc """
  Conflict-fallback workspace preparation for integration-build conflicts.

  When `IntegrationBuilder.rebuild/4` returns `{:conflict, files}`, the
  Reconciler stores a `:integration_conflict` marker for the issue. On the
  next dispatch, instead of attaching to the synthetic integration branch,
  we prepare the worktree from `main` and let the merge happen *inside* the
  worktree — the agent then sees and resolves the conflict in working tree.

  Context returned to the prompt as `{{ integration_conflict }}`:

      %{
        files:           ["a.ex", "b.ex"],
        blocker_branches: ["feat/A", "feat/B"],
        blocker_shas:    %{"feat/A" => "abc1234", "feat/B" => "def4567"}
      }

  PR base for this attempt is `main` (overrides `BaseResolver`'s integration
  result). After the agent resolves and pushes, normal flow resumes on
  subsequent ticks.
  """

  @table :symphony_branches_conflict_fallback

  @type conflict_context :: %{
          files: [String.t()],
          blocker_branches: [String.t()],
          blocker_shas: %{String.t() => String.t()}
        }

  @doc "Idempotently ensures the ETS table exists."
  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ref ->
        :ok
    end
  end

  @doc """
  Records that `issue_id` is in a conflict-fallback state with the given
  `context`. Returns `:new` the first time the same conflict signature is
  recorded, `:duplicate` thereafter (so callers can post a Linear comment
  exactly once per signature).
  """
  @spec mark_conflict(String.t(), conflict_context()) :: :new | :duplicate
  def mark_conflict(issue_id, %{} = context) when is_binary(issue_id) do
    ensure_table()
    signature = signature_for(context)

    case :ets.lookup(@table, {:conflict, issue_id}) do
      [{_, ^signature, _ctx}] ->
        :duplicate

      _ ->
        :ets.insert(@table, {{:conflict, issue_id}, signature, context})
        :new
    end
  end

  @doc """
  Returns the active conflict context for `issue_id`, or nil.
  """
  @spec active(String.t()) :: conflict_context() | nil
  def active(issue_id) when is_binary(issue_id) do
    ensure_table()

    case :ets.lookup(@table, {:conflict, issue_id}) do
      [{_, _sig, ctx}] -> ctx
      [] -> nil
    end
  end

  @doc """
  Clears the conflict-fallback state for `issue_id` once normal flow resumes
  (typically once a successful integration build runs).
  """
  @spec clear(String.t()) :: :ok
  def clear(issue_id) when is_binary(issue_id) do
    ensure_table()
    :ets.delete(@table, {:conflict, issue_id})
    :ok
  end

  @doc """
  Prepares the worktree for an issue marked with a conflict context.

  Creates a worktree from `default_base`, then attempts `git merge --no-ff`
  for each blocker branch. Stops at the first conflict and leaves the
  worktree dirty so the agent sees `git status` reporting the unresolved
  files.

  Returns `{:ok, %{path: path, blocker_shas: %{branch => sha}}}` on success
  (with the conflict still in the worktree as expected) or `{:error, _}` if
  the worktree itself couldn't be created.
  """
  @spec prepare_worktree(map(), String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, %{path: String.t(), blocker_shas: %{String.t() => String.t()}}}
          | {:error, term()}
  def prepare_worktree(repo, issue_identifier, branch_name, blocker_branches, opts) do
    workspace_root = Keyword.fetch!(opts, :workspace_root)
    default_base = Keyword.get(opts, :default_base, repo.default_base || "main")

    case SymphonyElixir.Repos.Worktree.add(repo, issue_identifier, default_base, branch_name,
           workspace_root: workspace_root,
           fetch: Keyword.get(opts, :fetch, true)
         ) do
      {:ok, %{path: path}} ->
        shas = merge_blockers_inplace(path, repo.remote, blocker_branches)
        {:ok, %{path: path, blocker_shas: shas}}

      {:error, _} = err ->
        err
    end
  end

  defp merge_blockers_inplace(path, remote, blocker_branches) do
    sorted = blocker_branches |> Enum.sort() |> Enum.uniq()

    Enum.reduce_while(sorted, %{}, fn branch, acc ->
      remote_ref = "#{remote}/#{branch}"

      sha =
        case System.cmd("git", ["-C", path, "rev-parse", remote_ref], stderr_to_stdout: true) do
          {out, 0} -> String.trim(out) |> String.slice(0, 7)
          _ -> ""
        end

      case System.cmd(
             "git",
             ["-C", path, "merge", "--no-ff", "-m", "merge #{branch}", remote_ref],
             stderr_to_stdout: true
           ) do
        {_out, 0} ->
          {:cont, Map.put(acc, branch, sha)}

        {_out, _code} ->
          # Conflict: stop here, leave the worktree in conflict state for
          # the agent to resolve.
          {:halt, Map.put(acc, branch, sha)}
      end
    end)
  end

  defp signature_for(%{} = context) do
    %{
      files: context |> Map.get(:files, []) |> Enum.sort(),
      blocker_shas: context |> Map.get(:blocker_shas, %{})
    }
  end
end
