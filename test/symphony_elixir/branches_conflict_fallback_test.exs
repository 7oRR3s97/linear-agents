defmodule SymphonyElixir.Branches.ConflictFallbackTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Branches.ConflictFallback
  alias SymphonyElixir.GitFixture

  @moduletag :tmp_dir

  setup do
    on_exit(fn ->
      if :ets.whereis(:symphony_branches_conflict_fallback) != :undefined do
        :ets.delete_all_objects(:symphony_branches_conflict_fallback)
      end
    end)

    :ok
  end

  describe "mark_conflict/2 + active/1" do
    test "records context the first time, reports duplicate on identical signature" do
      ctx = %{
        files: ["a.ex"],
        blocker_branches: ["feat/A", "feat/B"],
        blocker_shas: %{"feat/A" => "abc1234", "feat/B" => "def5678"}
      }

      assert :new = ConflictFallback.mark_conflict("issue-1", ctx)
      assert ConflictFallback.active("issue-1") == ctx

      assert :duplicate = ConflictFallback.mark_conflict("issue-1", ctx)
    end

    test "different signature marks as new again" do
      ctx1 = %{files: ["a.ex"], blocker_branches: ["feat/A"], blocker_shas: %{"feat/A" => "abc1234"}}
      ctx2 = %{files: ["a.ex"], blocker_branches: ["feat/A"], blocker_shas: %{"feat/A" => "def5678"}}

      assert :new = ConflictFallback.mark_conflict("issue-2", ctx1)
      assert :new = ConflictFallback.mark_conflict("issue-2", ctx2)
    end

    test "clear/1 removes the entry" do
      ctx = %{files: ["a.ex"], blocker_branches: ["feat/A"], blocker_shas: %{}}
      ConflictFallback.mark_conflict("issue-3", ctx)

      assert :ok = ConflictFallback.clear("issue-3")
      assert ConflictFallback.active("issue-3") == nil
    end

    test "active/1 returns nil for unknown issue" do
      assert ConflictFallback.active("never-marked") == nil
    end
  end

  describe "prepare_worktree/5" do
    test "creates a worktree from main and merges blocker branches in working tree", %{tmp_dir: tmp} do
      bare = GitFixture.bare_repo(tmp)
      source = GitFixture.working_clone(bare, tmp, "src")

      push_branch(source, "feat/A", "shared.txt", "lineA\n")
      push_branch(source, "feat/B", "shared.txt", "lineB\n")

      repo = %{handle: "src", path: source, remote: "origin", default_base: "main"}
      ws = Path.join(tmp, "ws")
      File.mkdir_p!(ws)

      assert {:ok, %{path: path, blocker_shas: shas}} =
               ConflictFallback.prepare_worktree(repo, "PES-X", "feat/x", ["feat/A", "feat/B"],
                 workspace_root: ws,
                 fetch: false
               )

      assert File.dir?(path)
      assert byte_size(shas["feat/A"]) >= 7
      assert byte_size(shas["feat/B"]) >= 7

      # The worktree should have unresolved conflicts on the shared file.
      {status, 0} = System.cmd("git", ["-C", path, "status", "--porcelain"], stderr_to_stdout: true)
      assert status =~ "shared.txt"
      assert status =~ ~r/^(UU|AA|U[ADU]|D[AU])/m, "expected merge conflict, got #{inspect(status)}"
    end
  end

  defp push_branch(source, branch, filename, contents) do
    {_out, 0} = System.cmd("git", ["-C", source, "checkout", "main"], stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["-C", source, "checkout", "-b", branch], stderr_to_stdout: true)
    GitFixture.commit_file(source, filename, contents, "add #{filename} on #{branch}")
    {_out, 0} = System.cmd("git", ["-C", source, "push", "-u", "origin", branch], stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["-C", source, "checkout", "main"], stderr_to_stdout: true)
  end
end
