defmodule SymphonyElixir.Feedback.Detector do
  @moduledoc """
  Detects fresh human feedback on `In Review` Linear issues.

  An issue's workpad comment (the one whose body starts with the configured
  `workpad_marker`) doubles as a "last agent action" timestamp via its
  `updated_at`. Any *other* comment whose `created_at` is later than that
  timestamp is treated as feedback that the agent hasn't yet seen.

  Pure logic. No side effects.
  """

  alias SymphonyElixir.Linear.Issue

  @type result ::
          :no_feedback
          | {:feedback, [comment_summary()]}
          | :no_workpad_yet

  @type comment_summary :: %{
          id: String.t() | nil,
          body: String.t() | nil,
          author: String.t() | nil,
          created_at: DateTime.t() | nil
        }

  @default_marker "## Agent Workpad"

  @doc """
  Returns:

  - `:no_feedback` — no comments newer than the workpad's `updated_at`.
  - `:no_workpad_yet` — no workpad comment found at all (the agent hasn't
    bootstrapped one yet; treat as nothing-to-rework).
  - `{:feedback, [comment_summary]}` — one or more newer non-workpad
    comments. Caller should react (typically: move issue to `Todo`).
  """
  @spec evaluate(Issue.t(), keyword()) :: result()
  def evaluate(%Issue{comments: comments}, opts \\ []) when is_list(comments) do
    marker = Keyword.get(opts, :workpad_marker, @default_marker)

    case find_workpad(comments, marker) do
      nil ->
        :no_workpad_yet

      workpad ->
        baseline =
          workpad.updated_at || workpad.created_at || epoch()

        feedback =
          comments
          |> Enum.reject(&workpad?(&1, marker))
          |> Enum.filter(&newer_than?(&1, baseline))
          |> Enum.map(&summarize/1)

        case feedback do
          [] -> :no_feedback
          list -> {:feedback, list}
        end
    end
  end

  defp find_workpad(comments, marker) do
    Enum.find(comments, &workpad?(&1, marker))
  end

  defp workpad?(%{body: body}, marker) when is_binary(body) and is_binary(marker) do
    String.starts_with?(String.trim_leading(body), marker)
  end

  defp workpad?(_, _), do: false

  defp newer_than?(%{created_at: %DateTime{} = at}, %DateTime{} = baseline) do
    DateTime.compare(at, baseline) == :gt
  end

  defp newer_than?(_, _), do: false

  defp summarize(comment) do
    %{
      id: comment.id,
      body: comment.body,
      author: comment.user_name,
      created_at: comment.created_at
    }
  end

  defp epoch, do: ~U[1970-01-01 00:00:00Z]
end
