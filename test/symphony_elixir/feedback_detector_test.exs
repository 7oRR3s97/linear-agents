defmodule SymphonyElixir.Feedback.DetectorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Feedback.Detector
  alias SymphonyElixir.Linear.Issue

  describe "evaluate/2" do
    test "returns :no_workpad_yet when no workpad comment exists" do
      issue =
        issue([
          comment("c1", "First reviewer comment", at: ~U[2026-05-04 00:00:00Z])
        ])

      assert :no_workpad_yet = Detector.evaluate(issue)
    end

    test "returns :no_feedback when only the workpad comment is present" do
      issue =
        issue([
          comment("wp", "## Agent Workpad\n\nstuff", at: ~U[2026-05-04 00:00:00Z])
        ])

      assert :no_feedback = Detector.evaluate(issue)
    end

    test "returns :no_feedback when newer comment is the workpad itself" do
      issue =
        issue([
          comment("wp", "## Agent Workpad\nv1", at: ~U[2026-05-04 00:00:00Z],
                       updated: ~U[2026-05-04 12:00:00Z])
        ])

      assert :no_feedback = Detector.evaluate(issue)
    end

    test "returns :no_feedback when reviewer comment predates the workpad's updated_at" do
      issue =
        issue([
          comment("c1", "early review", at: ~U[2026-05-04 09:00:00Z]),
          comment("wp", "## Agent Workpad", at: ~U[2026-05-04 08:00:00Z],
                       updated: ~U[2026-05-04 12:00:00Z])
        ])

      assert :no_feedback = Detector.evaluate(issue)
    end

    test "returns {:feedback, …} when reviewer comment is newer than workpad updated_at" do
      issue =
        issue([
          comment("wp", "## Agent Workpad", at: ~U[2026-05-04 08:00:00Z],
                       updated: ~U[2026-05-04 12:00:00Z]),
          comment("c1", "please fix the typo", at: ~U[2026-05-04 13:00:00Z],
                       user: "Reviewer")
        ])

      assert {:feedback, [%{id: "c1", body: "please fix the typo", author: "Reviewer"}]} =
               Detector.evaluate(issue)
    end

    test "lists multiple newer comments in the order they arrived" do
      issue =
        issue([
          comment("wp", "## Agent Workpad", at: ~U[2026-05-04 08:00:00Z],
                       updated: ~U[2026-05-04 12:00:00Z]),
          comment("c1", "first feedback", at: ~U[2026-05-04 13:00:00Z]),
          comment("c2", "second feedback", at: ~U[2026-05-04 14:00:00Z])
        ])

      assert {:feedback, [%{id: "c1"}, %{id: "c2"}]} = Detector.evaluate(issue)
    end

    test "honours a custom workpad_marker option" do
      issue =
        issue([
          comment("wp", "## Custom Marker\nbody", at: ~U[2026-05-04 08:00:00Z],
                       updated: ~U[2026-05-04 09:00:00Z]),
          comment("c1", "feedback", at: ~U[2026-05-04 10:00:00Z])
        ])

      assert {:feedback, _} = Detector.evaluate(issue, workpad_marker: "## Custom Marker")
    end

    test "ignores comments missing created_at" do
      issue =
        issue([
          comment("wp", "## Agent Workpad", at: ~U[2026-05-04 08:00:00Z]),
          %{id: "c-broken", body: "no timestamp", created_at: nil, user_id: nil, user_name: nil}
        ])

      assert :no_feedback = Detector.evaluate(issue)
    end
  end

  defp issue(comments) do
    %Issue{
      id: "id-x",
      identifier: "PES-1",
      state: "In Review",
      labels: ["repo:web", "AFK"],
      comments: comments
    }
  end

  defp comment(id, body, opts) do
    %{
      id: id,
      body: body,
      created_at: Keyword.fetch!(opts, :at),
      updated_at: Keyword.get(opts, :updated, Keyword.fetch!(opts, :at)),
      user_id: "user-1",
      user_name: Keyword.get(opts, :user, "Agent")
    }
  end
end
