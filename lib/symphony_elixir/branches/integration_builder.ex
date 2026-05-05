defmodule SymphonyElixir.Branches.IntegrationBuilder do
  @moduledoc """
  Builds and force-pushes synthetic `symphony/integration/<id>` branches by
  sequentially merging blocker branches on top of the configured base
  (default `main`).

  The build runs inside a temporary worktree on the source clone so the
  source's main checkout isn't disturbed. Conflicts are surfaced as
  `{:conflict, [files]}` — E1's fallback path consumes that signal and
  delegates conflict resolution to the agent.

  All git operations serialize through `Repos.Lockbox`. Force pushes use
  `--force-with-lease` only.
  """

  alias SymphonyElixir.Repos.Lockbox

  @type repo :: %{handle: String.t(), path: String.t(), remote: String.t(), default_base: String.t()}

  @type result :: {:ok, String.t()} | {:conflict, [String.t()]} | {:error, term()}

  @doc """
  Rebuilds the integration branch by sequentially merging `blocker_branches`
  onto `base_branch` (default `main`). Force-pushes the result to
  `<remote>/<integration_branch_name>` on success.
  """
  @spec rebuild(repo(), String.t(), [String.t()], String.t()) :: result()
  def rebuild(repo, integration_branch_name, blocker_branches, base_branch \\ "main") do
    sorted_blockers = blocker_branches |> Enum.sort() |> Enum.uniq()

    cond do
      MapSet.member?(protected_branches(repo, base_branch), integration_branch_name) ->
        {:error, {:rejected_protected_branch, integration_branch_name}}

      true ->
        Lockbox.with_lock(repo.handle, fn ->
          do_rebuild(repo, integration_branch_name, sorted_blockers, base_branch)
        end)
        |> unwrap()
    end
  end

  # Refuse to push the "integration" branch to a protected base — landing
  # on main is a human-only action.
  defp protected_branches(repo, base_branch) do
    base = repo[:default_base] || base_branch || "main"
    MapSet.new([base, "main", "master", "trunk", "develop"])
  end

  defp do_rebuild(repo, integration_branch_name, blockers, base_branch) do
    with :ok <- fetch(repo),
         {:ok, build_dir} <- prepare_build_dir(repo, integration_branch_name),
         result <- merge_blockers(repo, build_dir, integration_branch_name, blockers, base_branch),
         _ <- cleanup_build_dir(repo, integration_branch_name, build_dir) do
      result
    end
  end

  defp fetch(repo) do
    case System.cmd("git", ["-C", repo.path, "fetch", repo.remote], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:fetch_failed, code, String.trim(out)}}
    end
  end

  defp prepare_build_dir(repo, integration_branch_name) do
    build_dir = build_dir_path(repo, integration_branch_name)
    tmp_branch = tmp_branch_name(integration_branch_name)
    base = "#{repo.remote}/main"

    # Always start from a clean state — clear any leftovers from prior runs.
    cleanup_build_dir(repo, integration_branch_name, build_dir)

    args = ["-C", repo.path, "worktree", "add", "-B", tmp_branch, build_dir, base]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_out, 0} ->
        {:ok, build_dir}

      {out, code} ->
        {:error, {:worktree_add_failed, code, String.trim(out)}}
    end
  end

  defp merge_blockers(repo, build_dir, integration_branch_name, blockers, base_branch) do
    # Reset the build branch to the base ref. (Worktree was created from
    # remote/main; if the caller passes a different base_branch, switch.)
    if base_branch != "main" do
      base = "#{repo.remote}/#{base_branch}"
      System.cmd("git", ["-C", build_dir, "reset", "--hard", base], stderr_to_stdout: true)
    end

    Enum.reduce_while(blockers, {:ok, []}, fn branch, {:ok, _acc} ->
      remote_ref = "#{repo.remote}/#{branch}"

      case System.cmd("git", ["-C", build_dir, "merge", "--no-ff", "-m", "merge #{branch}", remote_ref],
             stderr_to_stdout: true
           ) do
        {_out, 0} ->
          {:cont, {:ok, []}}

        {_out, _code} ->
          conflicts = unmerged_files(build_dir)
          System.cmd("git", ["-C", build_dir, "merge", "--abort"], stderr_to_stdout: true)
          {:halt, {:conflict, conflicts}}
      end
    end)
    |> case do
      {:ok, _} ->
        force_push(repo, build_dir, integration_branch_name)

      {:conflict, files} ->
        {:conflict, files}
    end
  end

  defp force_push(repo, build_dir, integration_branch_name) do
    {sha, 0} = System.cmd("git", ["-C", build_dir, "rev-parse", "HEAD"], stderr_to_stdout: true)
    sha = String.trim(sha)

    refspec = "HEAD:refs/heads/#{integration_branch_name}"

    case System.cmd("git", ["-C", build_dir, "push", "--force-with-lease", repo.remote, refspec],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        {:ok, short_sha(sha)}

      {out, code} ->
        {:error, {:push_failed, code, String.trim(out)}}
    end
  end

  defp unmerged_files(build_dir) do
    case System.cmd("git", ["-C", build_dir, "diff", "--name-only", "--diff-filter=U"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp cleanup_build_dir(repo, integration_branch_name, build_dir) do
    if File.exists?(build_dir) do
      System.cmd("git", ["-C", repo.path, "worktree", "remove", "--force", build_dir], stderr_to_stdout: true)
      File.rm_rf(build_dir)
    end

    tmp = tmp_branch_name(integration_branch_name)
    System.cmd("git", ["-C", repo.path, "branch", "-D", tmp], stderr_to_stdout: true)
    :ok
  end

  defp build_dir_path(repo, integration_branch_name) do
    sanitized = String.replace(integration_branch_name, ~r/[^A-Za-z0-9._-]/, "_")
    Path.join([Path.dirname(repo.path), "_symphony_int_" <> sanitized])
  end

  defp tmp_branch_name(integration_branch_name) do
    sanitized = String.replace(integration_branch_name, ~r/[^A-Za-z0-9._-]/, "_")
    "_symphony_int_tmp_" <> sanitized
  end

  defp short_sha(sha) when is_binary(sha) do
    String.slice(sha, 0, 7)
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap(other), do: other
end
