defmodule SymphonyElixir.Branches.Rebaser do
  @moduledoc """
  Rebases a dependent branch onto a fresh target ref and force-pushes the
  result. Used for post-deploy mediation: when a hard-dep blocker merges
  to `main`, the dependent's branch needs to drop the blocker's commits
  (now in main) and replay only the dependent's own commits.

  All git operations serialize through `Repos.Lockbox`. The rebase runs
  in a temp worktree so the source clone's checkout isn't disturbed.
  Force pushes use `--force-with-lease` only.

  ## Concurrency

  Callers MUST ensure the dependent isn't currently `In Progress` (i.e.,
  no agent is editing its workspace) before invoking. The Reconciler
  enforces this by deferring the rebase to agent exit when a worker is
  active on the branch.
  """

  alias SymphonyElixir.Repos.Lockbox

  @type repo :: %{handle: String.t(), path: String.t(), remote: String.t(), default_base: String.t()}

  @type result ::
          {:ok, %{from: String.t(), to: String.t()}}
          | {:noop, :already_up_to_date | :branch_missing}
          | {:conflict, [String.t()]}
          | {:error, term()}

  @doc """
  Rebases `branch` onto `<remote>/<target>` and force-pushes the result.

  Returns:
  - `{:ok, %{from, to}}` — rebase succeeded; `from`/`to` are short SHAs.
  - `{:noop, :already_up_to_date}` — branch already contains target's tip.
  - `{:noop, :branch_missing}` — branch doesn't exist on the remote.
  - `{:conflict, [files]}` — rebase aborted on conflict; nothing pushed.
  - `{:error, reason}` — git/transport failure.
  """
  @spec rebase_onto(repo(), String.t(), String.t(), keyword()) :: result()
  def rebase_onto(repo, branch, target, opts \\ [])
      when is_binary(branch) and is_binary(target) do
    fetch? = Keyword.get(opts, :fetch, true)
    protected = protected_branches(repo)

    cond do
      MapSet.member?(protected, branch) ->
        {:error, {:rejected_protected_branch, branch}}

      true ->
        Lockbox.with_lock(repo.handle, fn ->
          with :ok <- maybe_fetch(repo, fetch?),
               :exists <- branch_status(repo, branch),
               {:ok, build_dir} <- prepare_build_dir(repo, branch, target) do
            result = do_rebase(repo, build_dir, branch, target)
            cleanup_build_dir(repo, build_dir)
            result
          else
            :missing -> {:noop, :branch_missing}
            {:error, _} = err -> err
          end
        end)
        |> unwrap()
    end
  end

  # Branches the orchestrator MUST NEVER push to — landing on main is
  # 100% a human responsibility. Includes the configured default base
  # plus the canonical names so a misconfigured `default_base` ("master",
  # "trunk", etc.) doesn't open a hole.
  defp protected_branches(repo) do
    base = repo[:default_base] || "main"
    MapSet.new([base, "main", "master", "trunk", "develop"])
  end

  defp maybe_fetch(_repo, false), do: :ok

  defp maybe_fetch(repo, true) do
    case System.cmd("git", ["-C", repo.path, "fetch", repo.remote], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:fetch_failed, code, String.trim(out)}}
    end
  end

  defp branch_status(repo, branch) do
    case System.cmd("git", ["-C", repo.path, "ls-remote", "--exit-code", repo.remote, "refs/heads/" <> branch],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> :exists
      _ -> :missing
    end
  end

  defp prepare_build_dir(repo, branch, _target) do
    sanitized = String.replace(branch, ~r/[^A-Za-z0-9._-]/, "_")
    build_dir = Path.join(Path.dirname(repo.path), "_symphony_rebase_" <> sanitized)
    tmp_branch = "_symphony_rebase_tmp_" <> sanitized

    cleanup_build_dir(repo, build_dir)

    args = [
      "-C",
      repo.path,
      "worktree",
      "add",
      "-B",
      tmp_branch,
      build_dir,
      "#{repo.remote}/#{branch}"
    ]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_out, 0} -> {:ok, build_dir}
      {out, code} -> {:error, {:worktree_add_failed, code, String.trim(out)}}
    end
  end

  defp do_rebase(repo, build_dir, branch, target) do
    target_ref = "#{repo.remote}/#{target}"

    {from_sha, 0} =
      System.cmd("git", ["-C", build_dir, "rev-parse", "--short", "HEAD"], stderr_to_stdout: true)

    from_sha = String.trim(from_sha)

    case System.cmd("git", ["-C", build_dir, "rebase", target_ref], stderr_to_stdout: true) do
      {_out, 0} ->
        {to_sha, 0} =
          System.cmd("git", ["-C", build_dir, "rev-parse", "--short", "HEAD"], stderr_to_stdout: true)

        to_sha = String.trim(to_sha)

        if to_sha == from_sha do
          {:noop, :already_up_to_date}
        else
          force_push(repo, build_dir, branch, from_sha, to_sha)
        end

      {_out, _code} ->
        files = unmerged_files(build_dir)
        System.cmd("git", ["-C", build_dir, "rebase", "--abort"], stderr_to_stdout: true)
        {:conflict, files}
    end
  end

  defp force_push(repo, build_dir, branch, from_sha, to_sha) do
    refspec = "HEAD:refs/heads/#{branch}"

    case System.cmd(
           "git",
           ["-C", build_dir, "push", "--force-with-lease", repo.remote, refspec],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> {:ok, %{from: from_sha, to: to_sha}}
      {out, code} -> {:error, {:push_failed, code, String.trim(out)}}
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

  defp cleanup_build_dir(repo, build_dir) do
    if File.exists?(build_dir) do
      System.cmd("git", ["-C", repo.path, "worktree", "remove", "--force", build_dir], stderr_to_stdout: true)
      File.rm_rf(build_dir)
    end

    sanitized = build_dir |> Path.basename() |> String.replace_prefix("_symphony_rebase_", "")
    tmp_branch = "_symphony_rebase_tmp_" <> sanitized
    System.cmd("git", ["-C", repo.path, "branch", "-D", tmp_branch], stderr_to_stdout: true)
    :ok
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap(other), do: other
end
