defmodule SymphonyElixir.LinearNormalizationTest do
  @moduledoc """
  Locks the A2 contract: every Linear issue normalization round-trip carries
  `branch_name` and the blocker `state` so that `BaseResolver` (C1) and
  `DispatchGuard` (C2) can decide eligibility without an extra Linear fetch.
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Client

  test "branch_name and blocker state survive normalization" do
    raw = %{
      "id" => "abc-123",
      "identifier" => "PES-99",
      "title" => "Stack-aware dispatch",
      "description" => "Body.",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "ana/pes-99-stack-aware-dispatch",
      "url" => "https://example.com/issue/PES-99",
      "assignee" => %{"id" => "user-1"},
      "labels" => %{"nodes" => [%{"name" => "linear-agent"}, %{"name" => "AFK"}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{"id" => "blk-1", "identifier" => "PES-50", "state" => %{"name" => "In Review"}}
          },
          %{
            "type" => "blocks",
            "issue" => %{"id" => "blk-2", "identifier" => "PES-51", "state" => %{"name" => "Done"}}
          },
          %{
            "type" => "duplicates",
            "issue" => %{"id" => "noise", "identifier" => "PES-X", "state" => %{"name" => "Backlog"}}
          }
        ]
      },
      "createdAt" => "2026-05-01T00:00:00Z",
      "updatedAt" => "2026-05-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw)

    assert issue.branch_name == "ana/pes-99-stack-aware-dispatch"

    assert issue.blocked_by == [
             %{id: "blk-1", identifier: "PES-50", state: "In Review"},
             %{id: "blk-2", identifier: "PES-51", state: "Done"}
           ]
  end

  test "missing branchName decodes to nil rather than crashing" do
    raw = %{
      "id" => "abc-123",
      "identifier" => "PES-100",
      "title" => "No branch metadata yet",
      "state" => %{"name" => "Todo"},
      "labels" => %{"nodes" => []},
      "inverseRelations" => %{"nodes" => []}
    }

    issue = Client.normalize_issue_for_test(raw)

    assert issue.branch_name == nil
    assert issue.blocked_by == []
  end

  test "blocker state defaults to nil when payload omits it" do
    raw = %{
      "id" => "abc-123",
      "identifier" => "PES-101",
      "title" => "Edge case",
      "state" => %{"name" => "Todo"},
      "labels" => %{"nodes" => []},
      "branchName" => "x",
      "inverseRelations" => %{
        "nodes" => [
          %{"type" => "blocks", "issue" => %{"id" => "blk", "identifier" => "PES-X"}}
        ]
      }
    }

    issue = Client.normalize_issue_for_test(raw)

    assert [%{id: "blk", identifier: "PES-X", state: nil}] = issue.blocked_by
  end
end
