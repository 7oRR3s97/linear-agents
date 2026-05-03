defmodule SymphonyElixir.Deps.Cascade do
  @moduledoc """
  Applies cascade rewinds when a blocker transitions `In Review → Todo`.

  Consumes the cascade events the Reconciler stages via
  `Branches.Reconciler.drain_cascades/0`, then for each dependent decides:

  - `Todo` → no-op (will become dispatchable when blocker re-reaches In Review).
  - `In Progress` → leave the running agent alone; the Reconciler will defer
    any rebase target to agent exit.
  - `In Review` → move the dependent back to `Todo` and post a Linear comment
    explaining the rewind. This applies uniformly to hard-dep (same-repo) and
    soft-dep (cross-repo) dependents.
  - terminal states (`Done`, `Canceled`, `Duplicate`) → no-op.

  Idempotent. If the same `(dependent, blocker)` pair flips repeatedly, the
  cascade event is only delivered once per `In Review → Todo` transition (the
  Reconciler tracks previous-state).
  """

  alias SymphonyElixir.Linear.Issue

  @type apply_action ::
          {:rewind, dependent_identifier :: String.t(), comment :: String.t()}
          | {:noop, dependent_identifier :: String.t(), reason :: atom()}

  @typedoc "A pure transition decision; consumers turn these into Linear writes."
  @type decision :: apply_action()

  @doc """
  Pure decision: given a dependent issue and the blocker that just rewound,
  returns the action to take.
  """
  @spec decide(Issue.t(), Issue.t()) :: decision()
  def decide(%Issue{} = dependent, %Issue{} = blocker) do
    case normalize_state(dependent.state) do
      "todo" ->
        {:noop, dependent.identifier, :already_todo}

      "in progress" ->
        {:noop, dependent.identifier, :running_undisturbed}

      "in review" ->
        comment =
          "Blocker #{blocker.identifier} returned to `Todo` for rework. " <>
            "This task moved back to `Todo` to re-stack on the updated blocker."

        {:rewind, dependent.identifier, comment}

      terminal when terminal in ["done", "canceled", "cancelled", "duplicate", "closed"] ->
        {:noop, dependent.identifier, :terminal}

      _ ->
        {:noop, dependent.identifier, :unknown_state}
    end
  end

  @doc """
  Applies a list of cascade events. Each event is `{dependent_id,
  blocker_id}` from `Reconciler.drain_cascades/0`.

  `apply_fn` and `comment_fn` are injected so callers (orchestrator, tests)
  control the side effects:

  - `apply_fn.(dependent_id, "Todo")` performs the state transition.
  - `comment_fn.(dependent_id, body)` posts the explanation comment.

  Issues are looked up via `lookup_fn.(id)` returning `{:ok, %Issue{}}` or
  `:error`.

  Returns `[decision()]` for inspection / logging.
  """
  @spec apply_cascades(
          [{String.t(), String.t()}],
          (String.t() -> {:ok, Issue.t()} | :error),
          (String.t(), String.t() -> :ok | {:error, term()}),
          (String.t(), String.t() -> :ok | {:error, term()})
        ) :: [decision()]
  def apply_cascades(events, lookup_fn, apply_fn, comment_fn) do
    Enum.flat_map(events, fn {dependent_id, blocker_id} ->
      with {:ok, dependent} <- lookup_fn.(dependent_id),
           {:ok, blocker} <- lookup_fn.(blocker_id) do
        decision = decide(dependent, blocker)
        execute(decision, apply_fn, comment_fn)
        [decision]
      else
        _ -> []
      end
    end)
  end

  defp execute({:rewind, dependent_identifier, comment}, apply_fn, comment_fn) do
    apply_fn.(dependent_identifier, "Todo")
    comment_fn.(dependent_identifier, comment)
    :ok
  end

  defp execute({:noop, _, _}, _apply_fn, _comment_fn), do: :ok

  defp normalize_state(nil), do: ""
  defp normalize_state(s) when is_binary(s), do: s |> String.trim() |> String.downcase()
end
