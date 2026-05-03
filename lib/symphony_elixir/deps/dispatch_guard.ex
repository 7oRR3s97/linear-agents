defmodule SymphonyElixir.Deps.DispatchGuard do
  @moduledoc """
  Eligibility filter for dispatch when stacking is enabled.

  Extends the orchestrator's existing candidate selection with three
  additional gates:

  1. The Agent Autonomy label (`AFK` / `HITL`).
  2. Repository routing — issues must resolve to a single configured handle.
  3. Blocker state and (for hard deps) blocker branch presence.

  When `stacking.enabled = false`, `evaluate/3` is a no-op that returns
  `:ok` so the existing orchestrator logic is unchanged.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Repos

  @type snapshot :: %{
          required(:blockers_by_id) => %{String.t() => Issue.t()},
          required(:branch_exists?) => (String.t(), String.t() -> boolean())
        }

  @type skip_reason ::
          :hitl
          | :repo_routing_failed
          | :repo_routing_ambiguous
          | {:blocker_not_in_unblock_states, String.t()}
          | {:blocker_branch_missing, String.t()}

  @type settings :: map()

  @type result :: :ok | {:skip, skip_reason()}

  @doc """
  Returns `:ok` if `issue` is dispatchable under the current stacking rules,
  or `{:skip, reason}` otherwise. When `stacking.enabled = false`, always
  returns `:ok`.
  """
  @spec evaluate(Issue.t(), snapshot(), settings()) :: result()
  def evaluate(%Issue{} = issue, %{} = snapshot, %{} = settings) do
    if stacking_enabled?(settings) do
      with :ok <- check_repo_routing(issue, settings),
           :ok <- check_autonomy(issue, settings) do
        check_blockers(issue, snapshot, settings)
      end
    else
      :ok
    end
  end

  defp stacking_enabled?(settings) do
    case get_in(settings, [:stacking, :enabled]) do
      true -> true
      _ -> false
    end
  end

  defp check_repo_routing(issue, settings) do
    repos = Map.get(settings, :repositories) || %{}

    case Repos.for_issue(issue, repos) do
      {:ok, _resolution} -> :ok
      {:error, :ambiguous} -> {:skip, :repo_routing_ambiguous}
      {:error, _other} -> {:skip, :repo_routing_failed}
    end
  end

  defp check_autonomy(%Issue{labels: labels}, settings) do
    autonomy = Map.get(settings, :agent_autonomy) || %{}
    dispatchable = autonomy_value(autonomy, :label_dispatchable, "AFK")
    human_only = autonomy_value(autonomy, :label_human_only, "HITL")
    default = autonomy_value(autonomy, :default_when_missing, "HITL")

    label_set = labels |> List.wrap() |> Enum.map(&downcase_or_nil/1) |> MapSet.new()

    cond do
      MapSet.member?(label_set, String.downcase(human_only)) ->
        {:skip, :hitl}

      MapSet.member?(label_set, String.downcase(dispatchable)) ->
        :ok

      String.downcase(default) == String.downcase(human_only) ->
        {:skip, :hitl}

      true ->
        :ok
    end
  end

  defp autonomy_value(autonomy, key, fallback) do
    case Map.get(autonomy, key) || Map.get(autonomy, to_string(key)) do
      v when is_binary(v) and v != "" -> v
      _ -> fallback
    end
  end

  defp downcase_or_nil(value) when is_binary(value), do: String.downcase(value)
  defp downcase_or_nil(_), do: ""

  defp check_blockers(%Issue{} = issue, snapshot, settings) do
    repos = Map.get(settings, :repositories) || %{}
    unblock_states = unblock_state_set(settings)

    {:ok, %{handle: issue_handle}} = Repos.for_issue(issue, repos)

    Enum.reduce_while(issue.blocked_by || [], :ok, fn blocker_ref, _acc ->
      blocker_id = Map.get(blocker_ref, :id) || Map.get(blocker_ref, "id")
      blocker_identifier = Map.get(blocker_ref, :identifier) || Map.get(blocker_ref, "identifier")
      blocker_state_from_ref = Map.get(blocker_ref, :state) || Map.get(blocker_ref, "state")

      blocker = Map.get(snapshot.blockers_by_id, blocker_id) || synthetic_blocker(blocker_ref)

      with :ok <- check_blocker_state(blocker, blocker_state_from_ref, blocker_identifier, unblock_states) do
        check_blocker_branch(blocker, issue_handle, blocker_identifier, snapshot, repos)
      end
      |> case do
        :ok -> {:cont, :ok}
        {:skip, _} = halt -> {:halt, halt}
      end
    end)
  end

  defp synthetic_blocker(ref) do
    %Issue{
      id: Map.get(ref, :id) || Map.get(ref, "id"),
      identifier: Map.get(ref, :identifier) || Map.get(ref, "identifier"),
      state: Map.get(ref, :state) || Map.get(ref, "state"),
      labels: [],
      branch_name: nil
    }
  end

  defp check_blocker_state(_blocker, blocker_state, blocker_identifier, unblock_states) do
    state_norm = downcase_or_nil(blocker_state || "")

    if MapSet.member?(unblock_states, state_norm) do
      :ok
    else
      {:skip, {:blocker_not_in_unblock_states, blocker_identifier}}
    end
  end

  defp check_blocker_branch(%Issue{} = blocker, issue_handle, blocker_identifier, snapshot, repos) do
    case Repos.for_issue(blocker, repos) do
      {:ok, %{handle: ^issue_handle}} ->
        case blocker.branch_name do
          name when is_binary(name) and name != "" ->
            if snapshot.branch_exists?.(issue_handle, name) do
              :ok
            else
              {:skip, {:blocker_branch_missing, blocker_identifier}}
            end

          _ ->
            {:skip, {:blocker_branch_missing, blocker_identifier}}
        end

      _other_repo_or_unresolvable ->
        # Cross-repo: no branch check.
        :ok
    end
  end

  defp unblock_state_set(settings) do
    states = get_in(settings, [:stacking, :unblock_states]) || []
    states |> Enum.map(&downcase_or_nil/1) |> MapSet.new()
  end
end
