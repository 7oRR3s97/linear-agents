defmodule SymphonyElixir.Forge.GitHubTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Forge.GitHub
  alias SymphonyElixir.Forge.GitHub.GhClient

  @repo "acme/repo"

  setup do
    tmp = Path.join(System.tmp_dir!(), "gh-stub-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    stub_path = Path.join(tmp, "gh")

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :gh_binary)
      Application.delete_env(:symphony_elixir, :github_forge)
      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp, stub_path: stub_path}
  end

  describe "behaviour wiring" do
    test "delegates to the configured implementation" do
      Process.put({:test_calls, self()}, [])

      defmodule InlineForge do
        @behaviour SymphonyElixir.Forge.GitHub

        @impl true
        def pr_state(repo, branch), do: {:ok, %{number: 1, base: "main", head: branch, state: "OPEN", merged: false, called: {repo, branch}}}

        @impl true
        def pr_for_branch(_, _), do: {:ok, nil}

        @impl true
        def retarget_pr(_, _, _), do: :ok

        @impl true
        def delete_branch(_, _), do: :ok
      end

      Application.put_env(:symphony_elixir, :github_forge, InlineForge)

      assert {:ok, %{base: "main", called: {@repo, "feat/x"}}} = GitHub.pr_state(@repo, "feat/x")
    end
  end

  describe "GhClient.pr_for_branch/2" do
    test "parses gh stdout into a PR summary", %{stub_path: stub_path} do
      install_gh_stub!(stub_path, """
      #!/bin/sh
      cat <<'JSON'
      [{"number": 42, "baseRefName": "main", "headRefName": "feat/x", "state": "OPEN", "mergedAt": null}]
      JSON
      """)

      assert {:ok, %{number: 42, base: "main", head: "feat/x", state: "OPEN", merged: false}} =
               GhClient.pr_for_branch(@repo, "feat/x")
    end

    test "returns nil when gh returns []", %{stub_path: stub_path} do
      install_gh_stub!(stub_path, """
      #!/bin/sh
      echo "[]"
      """)

      assert {:ok, nil} = GhClient.pr_for_branch(@repo, "feat/x")
    end

    test "merged PR returns merged: true", %{stub_path: stub_path} do
      install_gh_stub!(stub_path, """
      #!/bin/sh
      cat <<'JSON'
      [{"number": 42, "baseRefName": "main", "headRefName": "feat/x", "state": "MERGED", "mergedAt": "2026-05-03T00:00:00Z"}]
      JSON
      """)

      assert {:ok, %{merged: true, state: "MERGED"}} = GhClient.pr_for_branch(@repo, "feat/x")
    end
  end

  describe "GhClient.pr_state/2" do
    test "{:error, :not_found} when no PR matches the branch", %{stub_path: stub_path} do
      install_gh_stub!(stub_path, """
      #!/bin/sh
      echo "[]"
      """)

      assert {:error, :not_found} = GhClient.pr_state(@repo, "feat/missing")
    end
  end

  describe "GhClient.retarget_pr/3" do
    test "calls gh pr edit with the right argv", %{stub_path: stub_path} do
      install_gh_stub!(stub_path, """
      #!/bin/sh
      echo "$@" > "#{Path.dirname(stub_path)}/last-args"
      exit 0
      """)

      assert :ok = GhClient.retarget_pr(@repo, 42, "main")

      assert {:ok, args} = File.read(Path.join(Path.dirname(stub_path), "last-args"))
      assert args =~ "pr edit 42 --repo #{@repo} --base main"
    end
  end

  describe "GhClient error classification" do
    test "rate-limit output surfaces as :rate_limited", %{stub_path: stub_path} do
      install_gh_stub!(stub_path, """
      #!/bin/sh
      echo "API rate limit exceeded for ..." >&2
      exit 1
      """)

      assert {:error, :rate_limited} = GhClient.pr_for_branch(@repo, "feat/x")
    end

    test "Not Found surfaces as :not_found", %{stub_path: stub_path} do
      install_gh_stub!(stub_path, """
      #!/bin/sh
      echo "Not Found" >&2
      exit 1
      """)

      assert {:error, :not_found} = GhClient.pr_for_branch(@repo, "feat/x")
    end

    test "missing gh binary surfaces as :gh_cli_missing" do
      Application.put_env(:symphony_elixir, :gh_binary, "/definitely/not/installed/gh-#{System.unique_integer([:positive])}")
      assert {:error, :gh_cli_missing} = GhClient.pr_for_branch(@repo, "feat/x")
    end
  end

  describe "GhClient.delete_branch/2" do
    test "Not Found is treated as success (idempotent delete)", %{stub_path: stub_path} do
      install_gh_stub!(stub_path, """
      #!/bin/sh
      echo "Not Found" >&2
      exit 1
      """)

      assert :ok = GhClient.delete_branch(@repo, "feat/gone")
    end
  end

  defp install_gh_stub!(stub_path, script) do
    File.write!(stub_path, script)
    File.chmod!(stub_path, 0o755)
    Application.put_env(:symphony_elixir, :gh_binary, stub_path)
  end
end
