defmodule SymphonyElixir.Branches.Reconciler do
  @moduledoc """
  Background poll-tick reconciliation for stacked PRs.

  For every issue in `In Progress` or `In Review`, the reconciler:

  1. Refreshes blocker SHAs (cheap fetch via the relevant `Lockbox`).
  2. Reads each blocker's current state from a tracker snapshot the
     orchestrator already has — no extra Linear roundtrip.
  3. If a blocker SHA changed and X is hard-dep:
     - 2+ same-repo blockers → calls `IntegrationBuilder.rebuild/4`.
     - 1 same-repo blocker → records a `:rebase_target` so B2's next
       worktree-add picks up the new base. Running tasks are not disturbed.
  4. If a blocker reached `Done` → calls `PR.Router.ensure_pr_base_correct/4`.
  5. If a blocker transitioned `In Review → Todo` → emits a cascade event
     (consumed by E2).

  ## State

  Maintains an ETS-backed cache:

  - `{:blocker_sha, repo_handle, branch_name}` → last-seen SHA.
  - `{:rebase_target, issue_id}` → desired base ref.
  - `{:cascade_pending, issue_id, blocker_id}` → :pending.

  `DispatchGuard` (C2) reads from `:blocker_sha` to satisfy its
  `branch_exists?` predicate.

  ## When stacking is disabled

  `run/2` is a no-op. The orchestrator can call it unconditionally.
  """

  alias SymphonyElixir.Branches.IntegrationBuilder
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PR.Router
  alias SymphonyElixir.Repos
  alias SymphonyElixir.Repos.Lockbox

  @table :symphony_branches_reconciler

  @doc """
  Idempotently ensures the ETS table exists. Safe to call from any process.
  """
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
  Runs one reconciliation pass. Returns `:ok` and a list of side-effect
  events for tests to assert on.
  """
  @spec run([Issue.t()], [Issue.t()], map(), keyword()) :: {:ok, [event()]}
  def run(active_issues, blocker_issues, settings, opts \\ []) do
    if stacking_enabled?(settings) do
      ensure_table()
      blockers_by_id = Map.new(blocker_issues, fn b -> {b.id, b} end)
      do_run(active_issues, blockers_by_id, settings, opts)
    else
      {:ok, []}
    end
  end

  @doc """
  Looks up the desired base ref captured by a previous reconciliation. The
  worktree creator can read this on each attempt to pick up a fresh base.
  """
  @spec rebase_target(String.t()) :: String.t() | nil
  def rebase_target(issue_id) when is_binary(issue_id) do
    ensure_table()

    case :ets.lookup(@table, {:rebase_target, issue_id}) do
      [{_, ref}] -> ref
      [] -> nil
    end
  end

  @doc """
  Returns the cached SHA for `(repo_handle, branch_name)`, or nil.
  """
  @spec branch_sha(String.t(), String.t()) :: String.t() | nil
  def branch_sha(repo_handle, branch_name) when is_binary(repo_handle) and is_binary(branch_name) do
    ensure_table()

    case :ets.lookup(@table, {:blocker_sha, repo_handle, branch_name}) do
      [{_, sha}] -> sha
      [] -> nil
    end
  end

  @doc """
  Returns whether the cached SHA exists for `(repo_handle, branch_name)`.
  Used by `DispatchGuard` as the `branch_exists?` predicate.
  """
  @spec branch_exists?(String.t(), String.t()) :: boolean()
  def branch_exists?(repo_handle, branch_name) do
    branch_sha(repo_handle, branch_name) != nil
  end

  @doc """
  Drains and returns pending cascade events for `issue_id`. Each call
  removes the entries it returns; consumers (E2) call this once per tick.
  """
  @spec drain_cascades() :: [{String.t(), String.t()}]
  def drain_cascades do
    ensure_table()
    pattern = {{:cascade_pending, :"$1", :"$2"}, :_}

    cascades =
      :ets.match_object(@table, pattern)
      |> Enum.map(fn {{:cascade_pending, issue_id, blocker_id}, _} ->
        {issue_id, blocker_id}
      end)

    Enum.each(cascades, fn {issue_id, blocker_id} ->
      :ets.delete(@table, {:cascade_pending, issue_id, blocker_id})
    end)

    cascades
  end

  @type event ::
          {:integration_rebuilt, String.t(), {:ok, String.t()} | {:conflict, [String.t()]}}
          | {:rebase_scheduled, String.t(), String.t()}
          | {:pr_routed, String.t(), Router.result()}
          | {:cascade_pending, String.t(), String.t()}

  defp stacking_enabled?(settings) do
    case get_in(settings, [:stacking, :enabled]) do
      true -> true
      _ -> false
    end
  end

  defp do_run(issues, blockers_by_id, settings, opts) do
    repos_config = repositories_config(settings)
    forge_repos = Keyword.get(opts, :forge_repos, %{})
    builder = Keyword.get(opts, :integration_builder, &IntegrationBuilder.rebuild/4)

    events =
      Enum.flat_map(issues, fn issue ->
        reconcile_one(issue, blockers_by_id, settings, repos_config, forge_repos, builder)
      end)

    {:ok, events}
  end

  defp reconcile_one(issue, blockers_by_id, settings, repos_config, forge_repos, builder) do
    case Repos.for_issue(issue, repos_config) do
      {:ok, %{handle: handle, path: path} = repo_resolution} ->
        blockers = resolve_full_blockers(issue, blockers_by_id)
        unblock_states = unblock_state_set(settings)

        # Side-effect 1: refresh same-repo blocker SHAs into the cache.
        same_repo = Enum.filter(blockers, &same_repo?(&1, repos_config, handle))
        refresh_blocker_shas(repo_resolution, same_repo)

        # Side-effect 2: detect cascade events.
        cascade_events = detect_cascades(issue, blockers, unblock_states)

        # Side-effect 3: integration rebuild or rebase target.
        active_blockers = Enum.filter(same_repo, &state_in?(&1, unblock_states))
        integration_event = maybe_rebuild_integration(issue, settings, repo_resolution, active_blockers, builder)
        rebase_event = maybe_schedule_rebase(issue, active_blockers)

        # Side-effect 4: PR retarget on Done.
        pr_event = maybe_route_pr(issue, blockers, settings, forge_repos, path)

        Enum.reject([integration_event, rebase_event] ++ cascade_events ++ [pr_event], &is_nil/1)

      {:error, _reason} ->
        []
    end
  end

  defp resolve_full_blockers(%Issue{blocked_by: refs}, blockers_by_id) do
    Enum.flat_map(refs || [], fn ref ->
      id = Map.get(ref, :id) || Map.get(ref, "id")

      case Map.get(blockers_by_id, id) do
        nil -> []
        blocker -> [blocker]
      end
    end)
  end

  defp same_repo?(blocker, repos_config, issue_handle) do
    case Repos.for_issue(blocker, repos_config) do
      {:ok, %{handle: ^issue_handle}} -> true
      _ -> false
    end
  end

  defp state_in?(%Issue{state: state}, set) when is_binary(state) do
    MapSet.member?(set, String.downcase(state))
  end

  defp state_in?(_, _), do: false

  defp unblock_state_set(settings) do
    states = get_in(settings, [:stacking, :unblock_states]) || []
    states |> Enum.map(&String.downcase/1) |> MapSet.new()
  end

  defp refresh_blocker_shas(repo_resolution, blockers) do
    Lockbox.with_lock(repo_resolution.handle, fn ->
      Enum.each(blockers, fn blocker ->
        with name when is_binary(name) and name != "" <- blocker.branch_name,
             {sha, 0} <-
               System.cmd(
                 "git",
                 ["-C", repo_resolution.path, "rev-parse", "#{repo_resolution.remote}/#{name}"],
                 stderr_to_stdout: true
               ) do
          :ets.insert(@table, {{:blocker_sha, repo_resolution.handle, name}, String.trim(sha)})
        else
          _ -> :ok
        end
      end)
    end)
  end

  defp detect_cascades(%Issue{id: issue_id}, blockers, unblock_states) do
    Enum.flat_map(blockers, fn blocker ->
      cond do
        not is_binary(blocker.state) ->
          []

        String.downcase(blocker.state) == "todo" ->
          # Possibly a rework rewind. We can only flag it; E2 decides scope.
          previous = previous_state(issue_id, blocker.id)

          if previous != nil and MapSet.member?(unblock_states, previous) do
            :ets.insert(@table, {{:cascade_pending, issue_id, blocker.id}, :pending})
            store_previous_state(issue_id, blocker.id, "todo")
            [{:cascade_pending, issue_id, blocker.id}]
          else
            store_previous_state(issue_id, blocker.id, "todo")
            []
          end

        true ->
          store_previous_state(issue_id, blocker.id, String.downcase(blocker.state))
          []
      end
    end)
  end

  defp previous_state(issue_id, blocker_id) do
    case :ets.lookup(@table, {:prev_blocker_state, issue_id, blocker_id}) do
      [{_, state}] -> state
      [] -> nil
    end
  end

  defp store_previous_state(issue_id, blocker_id, state) do
    :ets.insert(@table, {{:prev_blocker_state, issue_id, blocker_id}, state})
  end

  defp maybe_rebuild_integration(%Issue{} = issue, settings, repo_resolution, active_blockers, builder)
       when length(active_blockers) >= 2 do
    integration_branch = render_integration_branch_name(issue, settings)
    blocker_branches = active_blockers |> Enum.map(& &1.branch_name) |> Enum.reject(&is_nil/1)

    result = builder.(repo_resolution, integration_branch, blocker_branches, repo_resolution.default_base)
    {:integration_rebuilt, issue.identifier, result}
  end

  defp maybe_rebuild_integration(_, _, _, _, _), do: nil

  defp maybe_schedule_rebase(%Issue{} = issue, [single_blocker]) when not is_nil(single_blocker) do
    case single_blocker.branch_name do
      name when is_binary(name) and name != "" ->
        :ets.insert(@table, {{:rebase_target, issue.id}, name})
        {:rebase_scheduled, issue.identifier, name}

      _ ->
        nil
    end
  end

  defp maybe_schedule_rebase(_, _), do: nil

  defp maybe_route_pr(%Issue{} = issue, blockers, settings, forge_repos, _path) do
    repos_config = repositories_config(settings)

    case Repos.for_issue(issue, repos_config) do
      {:ok, %{handle: handle}} ->
        active = filter_blockers_for_router(blockers, repos_config, handle, settings)
        gh_repo = Map.get(forge_repos, handle)

        if is_binary(gh_repo) and is_binary(issue.branch_name) do
          result = Router.ensure_pr_base_correct(issue, active, settings, gh_repo: gh_repo)
          {:pr_routed, issue.identifier, result}
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp filter_blockers_for_router(blockers, repos_config, handle, settings) do
    unblock = unblock_state_set(settings)

    Enum.filter(blockers, fn b ->
      case Repos.for_issue(b, repos_config) do
        {:ok, %{handle: ^handle}} ->
          state = b.state || ""
          # Drop merged-to-main blockers (Done) — Router sees only "still
          # contributing" hard deps.
          MapSet.member?(unblock, String.downcase(state)) and String.downcase(state) != "done"

        _ ->
          false
      end
    end)
  end

  defp render_integration_branch_name(%Issue{} = issue, settings) do
    template =
      get_in(settings, [:stacking, :integration_branch_template]) ||
        "symphony/integration/{{ issue.identifier | downcase }}"

    parsed = Solid.parse!(template)

    Solid.render!(parsed, %{"issue" => %{"identifier" => issue.identifier}}, strict_variables: true)
    |> IO.iodata_to_binary()
    |> String.trim()
  end

  defp repositories_config(settings) do
    case Map.get(settings, :repositories) do
      %_{} = struct -> Map.from_struct(struct)
      other when is_map(other) -> other
      _ -> %{}
    end
  end
end
