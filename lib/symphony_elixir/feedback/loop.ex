defmodule SymphonyElixir.Feedback.Loop do
  @moduledoc """
  Per-poll-tick scan that converts fresh human comments on `In Review`
  Linear issues into automatic rework — i.e. moves the issue back to
  `Todo` so the existing rework path picks it up on the next dispatch.

  Runs only when `feedback.enabled = true` in `WORKFLOW.md`. Otherwise
  `run/2` is a no-op so single-repo / unattended-only deployments stay
  exactly as they were.

  ## Idempotency

  Detection uses the workpad comment's `updated_at` as the "last agent
  action" timestamp. Once the agent rewrites the workpad on the next
  rework cycle, that timestamp advances past the previously-detected
  feedback comments and the loop quietly stops re-triggering until a
  *new* human comment arrives.
  """

  require Logger

  alias SymphonyElixir.Feedback.Detector
  alias SymphonyElixir.Linear.Issue

  @type result :: %{
          rewound: [String.t()],
          skipped: [{String.t(), atom()}]
        }

  @doc """
  Inspect a snapshot of `In Review` issues and rewind any that received
  fresh human feedback. Returns a small report for logging / tests.
  """
  @spec run([Issue.t()], map(), keyword()) :: {:ok, result()}
  def run(in_review_issues, settings, opts \\ []) when is_list(in_review_issues) do
    if feedback_enabled?(settings) do
      apply_state_change = Keyword.get(opts, :apply_state_change, &default_apply/2)
      marker = workpad_marker(settings)
      target_state = rework_state(settings)

      result =
        Enum.reduce(in_review_issues, %{rewound: [], skipped: []}, fn issue, acc ->
          handle(issue, acc, apply_state_change, marker, target_state)
        end)

      {:ok, %{rewound: Enum.reverse(result.rewound), skipped: Enum.reverse(result.skipped)}}
    else
      {:ok, %{rewound: [], skipped: []}}
    end
  end

  defp handle(%Issue{id: id, identifier: identifier} = issue, acc, apply_fn, marker, target_state) do
    case Detector.evaluate(issue, workpad_marker: marker) do
      :no_feedback ->
        %{acc | skipped: [{identifier, :no_feedback} | acc.skipped]}

      :no_workpad_yet ->
        %{acc | skipped: [{identifier, :no_workpad_yet} | acc.skipped]}

      {:feedback, comments} ->
        Logger.info(
          "Feedback detected on #{identifier} (#{length(comments)} comment(s)); rewinding to #{target_state}"
        )

        case apply_fn.(id, target_state) do
          :ok -> %{acc | rewound: [identifier | acc.rewound]}
          {:error, reason} ->
            Logger.warning("Failed to rewind #{identifier}: #{inspect(reason)}")
            %{acc | skipped: [{identifier, {:error, reason}} | acc.skipped]}
        end
    end
  end

  defp feedback_enabled?(settings) do
    case get_in(settings, [Access.key(:feedback, %{}), Access.key(:enabled, false)]) do
      true -> true
      _ -> false
    end
  end

  defp workpad_marker(settings) do
    case get_in(settings, [Access.key(:feedback, %{}), Access.key(:workpad_marker)]) do
      v when is_binary(v) and v != "" -> v
      _ -> "## Agent Workpad"
    end
  end

  defp rework_state(settings) do
    case get_in(settings, [Access.key(:feedback, %{}), Access.key(:rework_state)]) do
      v when is_binary(v) and v != "" -> v
      _ -> "Todo"
    end
  end

  defp default_apply(issue_id, state_name) do
    SymphonyElixir.Linear.Adapter.update_issue_state(issue_id, state_name)
  end
end
