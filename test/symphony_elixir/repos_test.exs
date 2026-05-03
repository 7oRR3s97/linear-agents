defmodule SymphonyElixir.ReposTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Repos

  describe "for_issue/2" do
    test "resolves single repo:* label to a configured handle" do
      config = repositories_config()

      issue = %Issue{identifier: "PES-1", labels: ["repo:web", "priority:high"]}

      assert {:ok,
              %{
                handle: "web",
                path: "/tmp/web",
                remote: "origin",
                default_base: "main"
              }} = Repos.for_issue(issue, config)
    end

    test "matches labels case-insensitively against by_label keys" do
      config = repositories_config()

      issue = %Issue{identifier: "PES-2", labels: ["REPO:WEB"]}

      assert {:ok, %{handle: "web"}} = Repos.for_issue(issue, config)
    end

    test "returns :ambiguous when multiple repo:* labels match" do
      config = repositories_config()

      issue = %Issue{identifier: "PES-3", labels: ["repo:web", "repo:api"]}

      assert {:error, :ambiguous} = Repos.for_issue(issue, config)
    end

    test "falls through to default when no repo:* label matches" do
      config = repositories_config()

      issue = %Issue{identifier: "PES-4", labels: ["priority:high"]}

      assert {:ok, %{handle: "web"}} = Repos.for_issue(issue, config)
    end

    test "returns :no_repo when no match and no default configured" do
      config = repositories_config(default: nil)

      issue = %Issue{identifier: "PES-5", labels: []}

      assert {:error, :no_repo} = Repos.for_issue(issue, config)
    end

    test "returns :no_repo when matched handle is not in paths" do
      config =
        repositories_config(
          by_label: %{"repo:legacy" => "legacy"},
          paths: %{"web" => "/tmp/web", "api" => "/tmp/api"},
          default: "web"
        )

      issue = %Issue{identifier: "PES-6", labels: ["repo:legacy"]}

      assert {:error, :no_repo} = Repos.for_issue(issue, config)
    end

    test "returns :no_repo when default handle is not in paths" do
      config = repositories_config(default: "nonexistent")

      issue = %Issue{identifier: "PES-7", labels: []}

      assert {:error, :no_repo} = Repos.for_issue(issue, config)
    end

    test "returns :stacking_disabled when repositories config is absent" do
      issue = %Issue{identifier: "PES-8", labels: ["repo:web"]}

      assert {:error, :stacking_disabled} = Repos.for_issue(issue, nil)
    end

    test "ignores non repo:* labels in match decision" do
      config = repositories_config()

      issue = %Issue{identifier: "PES-9", labels: ["urgent", "team:platform", "repo:api"]}

      assert {:ok, %{handle: "api"}} = Repos.for_issue(issue, config)
    end
  end

  describe "path/2" do
    test "returns the path for a configured handle" do
      config = repositories_config()
      assert {:ok, "/tmp/web"} = Repos.path("web", config)
      assert {:ok, "/tmp/api"} = Repos.path("api", config)
    end

    test "returns :no_repo for an unknown handle" do
      config = repositories_config()
      assert {:error, :no_repo} = Repos.path("unknown", config)
    end
  end

  describe "remote/2 and default_base/2" do
    test "default_base defaults to main when not set" do
      config = repositories_config(default_base_branch: nil)
      assert "main" == Repos.default_base(config)
    end

    test "remote defaults to origin" do
      config = repositories_config(remote: nil)
      assert "origin" == Repos.remote(config)
    end

    test "respects configured remote and default_base" do
      config = repositories_config(remote: "upstream", default_base_branch: "trunk")
      assert "upstream" == Repos.remote(config)
      assert "trunk" == Repos.default_base(config)
    end
  end

  defp repositories_config(overrides \\ []) do
    base = %{
      default: "web",
      by_label: %{
        "repo:web" => "web",
        "repo:api" => "api"
      },
      paths: %{
        "web" => "/tmp/web",
        "api" => "/tmp/api"
      },
      remote: "origin",
      default_base_branch: "main"
    }

    Enum.reduce(overrides, base, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end
end
