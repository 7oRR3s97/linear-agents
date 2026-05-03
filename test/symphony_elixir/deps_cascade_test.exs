defmodule SymphonyElixir.Deps.CascadeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Deps.Cascade
  alias SymphonyElixir.Linear.Issue

  describe "decide/2" do
    test "Todo dependent: no-op (waits for blocker)" do
      assert {:noop, "PES-2", :already_todo} =
               Cascade.decide(issue("PES-2", "Todo"), blocker("PES-1"))
    end

    test "In Progress dependent: no-op (running agent undisturbed)" do
      assert {:noop, "PES-2", :running_undisturbed} =
               Cascade.decide(issue("PES-2", "In Progress"), blocker("PES-1"))
    end

    test "In Review dependent: rewind with explanatory comment" do
      assert {:rewind, "PES-2", comment} =
               Cascade.decide(issue("PES-2", "In Review"), blocker("PES-1"))

      assert comment =~ "PES-1 returned to `Todo` for rework"
      assert comment =~ "moved back to `Todo`"
    end

    test "Done dependent: no-op (terminal)" do
      assert {:noop, "PES-2", :terminal} =
               Cascade.decide(issue("PES-2", "Done"), blocker("PES-1"))
    end

    test "Canceled / Duplicate / Closed dependents are terminal" do
      for state <- ["Canceled", "Cancelled", "Duplicate", "Closed"] do
        assert {:noop, "PES-2", :terminal} =
                 Cascade.decide(issue("PES-2", state), blocker("PES-1"))
      end
    end

    test "Unknown state: no-op (unknown_state)" do
      assert {:noop, "PES-2", :unknown_state} =
               Cascade.decide(issue("PES-2", "Backlog"), blocker("PES-1"))
    end

    test "case-insensitive state match" do
      assert {:rewind, _, _} = Cascade.decide(issue("PES-2", "in review"), blocker("PES-1"))
      assert {:noop, _, :already_todo} = Cascade.decide(issue("PES-2", "TODO"), blocker("PES-1"))
    end
  end

  describe "apply_cascades/4" do
    test "rewinds an In Review dependent and records calls" do
      events = [{"id-X", "id-A"}]

      issues = %{
        "id-X" => issue("PES-X", "In Review"),
        "id-A" => blocker("PES-A")
      }

      lookup = fn id ->
        case Map.fetch(issues, id) do
          {:ok, i} -> {:ok, i}
          :error -> :error
        end
      end

      parent = self()
      apply_fn = fn ident, state -> send(parent, {:apply, ident, state}); :ok end
      comment_fn = fn ident, body -> send(parent, {:comment, ident, body}); :ok end

      assert [{:rewind, "PES-X", comment}] =
               Cascade.apply_cascades(events, lookup, apply_fn, comment_fn)

      assert_received {:apply, "PES-X", "Todo"}
      assert_received {:comment, "PES-X", ^comment}
    end

    test "skips In Progress dependent (no apply, no comment)" do
      events = [{"id-X", "id-A"}]

      issues = %{
        "id-X" => issue("PES-X", "In Progress"),
        "id-A" => blocker("PES-A")
      }

      lookup = fn id -> {:ok, Map.fetch!(issues, id)} end
      parent = self()

      apply_fn = fn _, _ -> send(parent, :should_not_apply); :ok end
      comment_fn = fn _, _ -> send(parent, :should_not_comment); :ok end

      assert [{:noop, "PES-X", :running_undisturbed}] =
               Cascade.apply_cascades(events, lookup, apply_fn, comment_fn)

      refute_received :should_not_apply
      refute_received :should_not_comment
    end

    test "missing issue lookups are skipped quietly" do
      events = [{"missing-X", "id-A"}]
      lookup = fn _ -> :error end
      apply_fn = fn _, _ -> :ok end
      comment_fn = fn _, _ -> :ok end

      assert [] = Cascade.apply_cascades(events, lookup, apply_fn, comment_fn)
    end
  end

  defp issue(identifier, state) do
    %Issue{
      id: "id-" <> identifier,
      identifier: identifier,
      state: state,
      labels: ["repo:web"]
    }
  end

  defp blocker(identifier) do
    %Issue{
      id: "id-" <> identifier,
      identifier: identifier,
      state: "Todo",
      labels: ["repo:web"]
    }
  end
end
