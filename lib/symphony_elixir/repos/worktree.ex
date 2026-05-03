defmodule SymphonyElixir.Repos.Worktree do
  @moduledoc """
  Git worktree CRUD against a configured source clone.

  Replaces the simple `mkdir` workspace creation when stacking is enabled.
  Each per-issue worktree gives the agent an isolated checkout under
  `<workspace.root>/<repo_handle>/<sanitized_issue_id>`, branched from a
  resolved base ref and checked out as the issue's task branch.

  Every git operation flows through `SymphonyElixir.Repos.Lockbox.with_lock/2`
  for the source repo, so concurrent calls against the same source clone
  serialize.
  """

  alias SymphonyElixir.Repos.Lockbox

  @type repo :: %{handle: String.t(), path: String.t(), remote: String.t(), default_base: String.t()}
  @type entry :: %{path: String.t(), branch: String.t() | nil, head: String.t(), dirty: boolean()}

  @sanitize_pattern ~r/[^A-Za-z0-9._-]/

  @doc """
  Creates (or reuses) a worktree for `(repo, issue_id)` branched from
  `base_ref`, then checks out `branch_name`.
  """
  @spec add(repo(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{path: String.t(), branch: String.t()}} | {:error, term()}
  def add(repo, issue_id, base_ref, branch_name, opts \\ []) do
    workspace_root = Keyword.fetch!(opts, :workspace_root)
    fetch? = Keyword.get(opts, :fetch, true)
    base_override = Keyword.get(opts, :base_ref_override)
    actual_base = base_override || base_ref

    path = worktree_path(workspace_root, repo.handle, issue_id)
    File.mkdir_p!(Path.dirname(path))

    Lockbox.with_lock(repo.handle, fn ->
      with :ok <- if(fetch?, do: do_fetch(repo), else: :ok),
           {:ok, _outcome} <- ensure_worktree(repo, path, actual_base, branch_name) do
        {:ok, %{path: path, branch: branch_name}}
      end
    end)
    |> unwrap()
  end

  @doc """
  Removes a worktree for `(repo, issue_id)` if it exists.
  """
  @spec remove(repo(), String.t(), keyword()) :: :ok | {:error, term()}
  def remove(repo, issue_id, opts \\ []) do
    workspace_root = Keyword.fetch!(opts, :workspace_root)
    path = worktree_path(workspace_root, repo.handle, issue_id)

    Lockbox.with_lock(repo.handle, fn ->
      cond do
        not File.exists?(path) ->
          :ok

        true ->
          do_remove(repo, path)
      end
    end)
    |> unwrap()
  end

  @doc """
  Lists active worktrees on the source clone (excluding the source itself),
  with dirty/clean status.
  """
  @spec list(repo()) :: {:ok, [entry()]} | {:error, term()}
  def list(repo) do
    Lockbox.with_lock(repo.handle, fn ->
      case System.cmd("git", ["-C", repo.path, "worktree", "list", "--porcelain"], stderr_to_stdout: true) do
        {output, 0} -> {:ok, parse_worktree_list(output, repo.path)}
        {output, code} -> {:error, {:worktree_list_failed, code, String.trim(output)}}
      end
    end)
    |> unwrap()
  end

  @doc """
  Fetches the source clone's configured remote.
  """
  @spec fetch(repo()) :: :ok | {:error, term()}
  def fetch(repo) do
    Lockbox.with_lock(repo.handle, fn -> do_fetch(repo) end)
    |> unwrap()
  end

  defp do_fetch(repo) do
    case System.cmd("git", ["-C", repo.path, "fetch", repo.remote], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:fetch_failed, code, String.trim(output)}}
    end
  end

  defp ensure_worktree(repo, path, base_ref, branch_name) do
    case existing_worktree_branch(repo, path) do
      {:ok, ^branch_name} ->
        {:ok, :reused}

      {:ok, other} when is_binary(other) ->
        {:error, {:worktree_branch_mismatch, path, other, branch_name}}

      {:ok, nil} ->
        create_worktree(repo, path, base_ref, branch_name)

      {:error, _} ->
        create_worktree(repo, path, base_ref, branch_name)
    end
  end

  defp existing_worktree_branch(repo, path) do
    case System.cmd("git", ["-C", repo.path, "worktree", "list", "--porcelain"], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, find_branch_in_listing(output, path)}

      {output, code} ->
        {:error, {:worktree_list_failed, code, String.trim(output)}}
    end
  end

  defp find_branch_in_listing(output, target_path) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.find_value(fn block ->
      lines = String.split(block, "\n", trim: true)
      worktree_line = Enum.find(lines, &String.starts_with?(&1, "worktree "))

      if worktree_line && String.trim_leading(worktree_line, "worktree ") == target_path do
        branch_line = Enum.find(lines, &String.starts_with?(&1, "branch "))

        case branch_line do
          nil -> nil
          line -> line |> String.trim_leading("branch refs/heads/") |> String.trim_leading("branch ")
        end
      end
    end)
  end

  defp create_worktree(repo, path, base_ref, branch_name) do
    File.mkdir_p!(Path.dirname(path))

    args = [
      "-C",
      repo.path,
      "worktree",
      "add",
      "-b",
      branch_name,
      path,
      base_ref
    ]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, :created}

      {output, code} ->
        File.rm_rf(path)
        {:error, {:worktree_add_failed, code, String.trim(output)}}
    end
  end

  defp do_remove(repo, path) do
    case System.cmd("git", ["-C", repo.path, "worktree", "remove", "--force", path], stderr_to_stdout: true) do
      {_output, 0} ->
        File.rm_rf(path)
        :ok

      {output, code} ->
        if File.exists?(path) do
          File.rm_rf(path)
        end

        if String.contains?(output, "is not a working tree") do
          :ok
        else
          {:error, {:worktree_remove_failed, code, String.trim(output)}}
        end
    end
  end

  defp parse_worktree_list(output, source_path) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      lines = String.split(block, "\n", trim: true)
      data = Enum.into(lines, %{}, &parse_listing_line/1)

      worktree_path = Map.get(data, "worktree")

      cond do
        is_nil(worktree_path) -> []
        worktree_path == source_path -> []
        true -> [build_entry(worktree_path, data)]
      end
    end)
  end

  defp parse_listing_line("worktree " <> path), do: {"worktree", path}
  defp parse_listing_line("HEAD " <> sha), do: {"head", sha}
  defp parse_listing_line("branch " <> ref), do: {"branch", strip_ref(ref)}
  defp parse_listing_line(other), do: {other, true}

  defp strip_ref("refs/heads/" <> name), do: name
  defp strip_ref(other), do: other

  defp build_entry(path, data) do
    %{
      path: path,
      branch: Map.get(data, "branch"),
      head: Map.get(data, "head", ""),
      dirty: dirty?(path)
    }
  end

  defp dirty?(path) do
    case System.cmd("git", ["-C", path, "status", "--porcelain"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _ -> false
    end
  end

  defp worktree_path(workspace_root, handle, issue_id) do
    Path.join([workspace_root, handle, sanitize_id(issue_id)])
  end

  defp sanitize_id(id) when is_binary(id) do
    Regex.replace(@sanitize_pattern, id, "_")
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, {:exception, %{} = ex}}), do: {:error, {:exception, ex}}
  defp unwrap({:error, {:exit, reason}}), do: {:error, {:exit, reason}}
  defp unwrap(other), do: other
end
