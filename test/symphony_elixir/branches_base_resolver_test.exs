defmodule SymphonyElixir.Branches.BaseResolverTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Branches.BaseResolver
  alias SymphonyElixir.Linear.Issue

  describe "resolve/3" do
    test "no blockers: branches from main" do
      assert {:ok, {:main, "main"}} = BaseResolver.resolve(issue("PES-1", "web"), [], settings())
    end

    test "no blockers: respects custom default base branch" do
      cfg = settings(default_base: "trunk")
      assert {:ok, {:main, "trunk"}} = BaseResolver.resolve(issue("PES-1", "web"), [], cfg)
    end

    test "single same-repo hard-dep blocker: stacks on its branch" do
      x = issue("PES-2", "web")
      a = blocker_issue("PES-1", "web", "ana/pes-1-feat-a")

      assert {:ok, {:single_blocker, "ana/pes-1-feat-a"}} =
               BaseResolver.resolve(x, [a], settings())
    end

    test "two same-repo blockers: integration branch from template" do
      x = issue("pes-7", "web")
      a = blocker_issue("PES-1", "web", "br-a")
      b = blocker_issue("PES-2", "web", "br-b")

      assert {:ok, {:integration, "symphony/integration/pes-7"}} =
               BaseResolver.resolve(x, [a, b], settings())
    end

    test "three same-repo blockers: still integration" do
      x = issue("PES-7", "web")

      blockers = [
        blocker_issue("PES-1", "web", "br-a"),
        blocker_issue("PES-2", "web", "br-b"),
        blocker_issue("PES-3", "web", "br-c")
      ]

      assert {:ok, {:integration, "symphony/integration/pes-7"}} =
               BaseResolver.resolve(x, blockers, settings())
    end

    test "cross-repo blocker is filtered (treated as soft dep, not in base ref)" do
      x = issue("PES-7", "web")
      api_blocker = blocker_issue("PES-1", "api", "br-api-a")

      assert {:ok, {:main, "main"}} = BaseResolver.resolve(x, [api_blocker], settings())
    end

    test "mix of one same-repo and one cross-repo blocker: single_blocker on the same-repo one" do
      x = issue("PES-7", "web")
      same_repo = blocker_issue("PES-1", "web", "br-web")
      cross_repo = blocker_issue("PES-2", "api", "br-api")

      assert {:ok, {:single_blocker, "br-web"}} =
               BaseResolver.resolve(x, [same_repo, cross_repo], settings())
    end

    test "blockers sorted by identifier for deterministic output" do
      x = issue("PES-7", "web")
      a = blocker_issue("PES-30", "web", "br-30")
      b = blocker_issue("PES-2", "web", "br-2")
      c = blocker_issue("PES-100", "web", "br-100")

      # the integration branch name is template-driven so order doesn't change
      # the *result*, but if we ever exposed a list of contributing blockers
      # they should be PES-100, PES-2, PES-30 (string ascii-sort), or numeric
      # — we pick string sort for portability and lock it in.
      assert {:ok, {:integration, "symphony/integration/pes-7"}} =
               BaseResolver.resolve(x, [a, b, c], settings())
    end

    test "hard-dep blocker without branch_name returns error" do
      x = issue("PES-7", "web")
      a = %{blocker_issue("PES-1", "web", "br-a") | branch_name: nil}

      assert {:error, {:blocker_branch_missing, "PES-1"}} =
               BaseResolver.resolve(x, [a], settings())
    end

    test "issue without resolvable repo returns error" do
      orphan = %Issue{identifier: "X-1", labels: []}
      cfg = settings(default: nil, by_label: %{}, paths: %{})

      assert {:error, :issue_repo_unresolvable} =
               BaseResolver.resolve(orphan, [], cfg)
    end

    test "integration branch template uses downcase filter on identifier" do
      x = issue("PES-Mixed", "web")
      blockers = [blocker_issue("PES-1", "web", "br-a"), blocker_issue("PES-2", "web", "br-b")]

      assert {:ok, {:integration, "symphony/integration/pes-mixed"}} =
               BaseResolver.resolve(x, blockers, settings())
    end

    test "integration template can be customized via stacking config" do
      cfg =
        settings(
          integration_branch_template: "stacks/{{ issue.identifier | downcase }}-int"
        )

      x = issue("PES-7", "web")
      blockers = [blocker_issue("PES-1", "web", "br-a"), blocker_issue("PES-2", "web", "br-b")]

      assert {:ok, {:integration, "stacks/pes-7-int"}} = BaseResolver.resolve(x, blockers, cfg)
    end
  end

  defp issue(identifier, repo_handle) do
    %Issue{
      id: "id-" <> identifier,
      identifier: identifier,
      labels: ["repo:" <> repo_handle],
      state: "Todo"
    }
  end

  defp blocker_issue(identifier, repo_handle, branch_name) do
    %Issue{
      id: "id-" <> identifier,
      identifier: identifier,
      labels: ["repo:" <> repo_handle],
      branch_name: branch_name,
      state: "In Review"
    }
  end

  defp settings(opts \\ []) do
    %{
      repositories: %{
        default: Keyword.get(opts, :default, "web"),
        by_label: Keyword.get(opts, :by_label, %{"repo:web" => "web", "repo:api" => "api"}),
        paths: Keyword.get(opts, :paths, %{"web" => "/tmp/web", "api" => "/tmp/api"}),
        remote: "origin",
        default_base_branch: Keyword.get(opts, :default_base, "main")
      },
      stacking: %{
        enabled: true,
        branch_template: "{{ issue.branchName }}",
        integration_branch_template:
          Keyword.get(
            opts,
            :integration_branch_template,
            "symphony/integration/{{ issue.identifier | downcase }}"
          ),
        unblock_states: ["In Review", "Done"],
        rework_state: "Todo"
      }
    }
  end
end
