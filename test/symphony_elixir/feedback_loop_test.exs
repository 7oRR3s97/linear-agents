defmodule SymphonyElixir.Feedback.LoopTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Feedback.Loop
  alias SymphonyElixir.Linear.Issue

  describe "run/3 with feedback disabled" do
    test "is a no-op" do
      issue = issue_with_feedback("PES-1")
      settings = settings(enabled: false)

      assert {:ok, %{rewound: [], skipped: []}} = Loop.run([issue], settings)
    end
  end

  describe "run/3 with feedback enabled" do
    test "rewinds an issue with fresh feedback comments" do
      issue = issue_with_feedback("PES-1")
      parent = self()
      apply_fn = fn id, state -> send(parent, {:moved, id, state}); :ok end

      assert {:ok, %{rewound: ["PES-1"], skipped: []}} =
               Loop.run([issue], settings(), apply_state_change: apply_fn)

      assert_received {:moved, "id-PES-1", "Todo"}
    end

    test "respects a custom rework_state" do
      issue = issue_with_feedback("PES-2")
      parent = self()
      apply_fn = fn _, state -> send(parent, {:state, state}); :ok end

      Loop.run([issue], settings(rework_state: "Rework"), apply_state_change: apply_fn)

      assert_received {:state, "Rework"}
    end

    test "skips issues without fresh feedback" do
      issue = issue_with_only_workpad("PES-3")
      apply_fn = fn _, _ -> flunk("should not move state") end

      assert {:ok, %{rewound: [], skipped: [{"PES-3", :no_feedback}]}} =
               Loop.run([issue], settings(), apply_state_change: apply_fn)
    end

    test "skips issues without a workpad comment" do
      issue = issue_no_workpad("PES-4")
      apply_fn = fn _, _ -> flunk("should not move state") end

      assert {:ok, %{rewound: [], skipped: [{"PES-4", :no_workpad_yet}]}} =
               Loop.run([issue], settings(), apply_state_change: apply_fn)
    end

    test "records adapter errors in skipped without crashing" do
      issue = issue_with_feedback("PES-5")
      apply_fn = fn _, _ -> {:error, :linear_api_request} end

      assert {:ok, %{rewound: [], skipped: [{"PES-5", {:error, :linear_api_request}}]}} =
               Loop.run([issue], settings(), apply_state_change: apply_fn)
    end

    test "processes a mix of issues in a single tick" do
      a = issue_with_feedback("PES-A")
      b = issue_with_only_workpad("PES-B")
      c = issue_no_workpad("PES-C")
      apply_fn = fn _, _ -> :ok end

      {:ok, result} = Loop.run([a, b, c], settings(), apply_state_change: apply_fn)

      assert "PES-A" in result.rewound
      assert {"PES-B", :no_feedback} in result.skipped
      assert {"PES-C", :no_workpad_yet} in result.skipped
    end
  end

  defp issue_with_feedback(identifier) do
    %Issue{
      id: "id-" <> identifier,
      identifier: identifier,
      state: "In Review",
      labels: ["repo:web", "AFK"],
      comments: [
        %{
          id: "wp",
          body: "## Agent Workpad\nstuff",
          created_at: ~U[2026-05-04 08:00:00Z],
          updated_at: ~U[2026-05-04 12:00:00Z],
          user_id: "u",
          user_name: "Agent"
        },
        %{
          id: "c1",
          body: "Please fix the bug on line 42",
          created_at: ~U[2026-05-04 13:00:00Z],
          updated_at: ~U[2026-05-04 13:00:00Z],
          user_id: "human",
          user_name: "Reviewer"
        }
      ]
    }
  end

  defp issue_with_only_workpad(identifier) do
    %Issue{
      id: "id-" <> identifier,
      identifier: identifier,
      state: "In Review",
      labels: ["repo:web", "AFK"],
      comments: [
        %{
          id: "wp",
          body: "## Agent Workpad",
          created_at: ~U[2026-05-04 08:00:00Z],
          updated_at: ~U[2026-05-04 12:00:00Z],
          user_id: "u",
          user_name: "Agent"
        }
      ]
    }
  end

  defp issue_no_workpad(identifier) do
    %Issue{
      id: "id-" <> identifier,
      identifier: identifier,
      state: "In Review",
      labels: ["repo:web", "AFK"],
      comments: []
    }
  end

  defp settings(opts \\ []) do
    %{
      feedback: %{
        enabled: Keyword.get(opts, :enabled, true),
        rework_state: Keyword.get(opts, :rework_state, "Todo"),
        workpad_marker: Keyword.get(opts, :workpad_marker, "## Agent Workpad")
      }
    }
  end
end
