defmodule SymphonyElixir.Branches.IntegrationBuilderTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Branches.IntegrationBuilder
  alias SymphonyElixir.GitFixture

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    bare = GitFixture.bare_repo(tmp)
    source = GitFixture.working_clone(bare, tmp, "src")

    repo = %{handle: "src", path: source, remote: "origin", default_base: "main"}
    {:ok, bare: bare, source: source, repo: repo}
  end

  describe "rebuild/4" do
    test "merges two non-conflicting blockers and force-pushes the integration branch", %{
      repo: repo,
      bare: bare
    } do
      push_branch_with_file(repo.path, "feat/A", "a.txt", "from A\n")
      push_branch_with_file(repo.path, "feat/B", "b.txt", "from B\n")

      assert {:ok, sha} = IntegrationBuilder.rebuild(repo, "symphony/integration/x", ["feat/A", "feat/B"])
      assert is_binary(sha)
      assert byte_size(sha) >= 7

      check_dir = Path.join(Path.dirname(repo.path), "check")
      {_out, 0} = System.cmd("git", ["clone", "--branch", "symphony/integration/x", bare, check_dir], stderr_to_stdout: true)

      assert File.exists?(Path.join(check_dir, "a.txt"))
      assert File.exists?(Path.join(check_dir, "b.txt"))
    end

    test "three blockers integrate sequentially", %{repo: repo, bare: bare} do
      push_branch_with_file(repo.path, "feat/A", "a.txt", "A\n")
      push_branch_with_file(repo.path, "feat/B", "b.txt", "B\n")
      push_branch_with_file(repo.path, "feat/C", "c.txt", "C\n")

      assert {:ok, _sha} =
               IntegrationBuilder.rebuild(repo, "symphony/integration/x", ["feat/A", "feat/B", "feat/C"])

      check_dir = Path.join(Path.dirname(repo.path), "check3")
      {_out, 0} = System.cmd("git", ["clone", "--branch", "symphony/integration/x", bare, check_dir], stderr_to_stdout: true)

      assert File.exists?(Path.join(check_dir, "a.txt"))
      assert File.exists?(Path.join(check_dir, "b.txt"))
      assert File.exists?(Path.join(check_dir, "c.txt"))
    end

    test "returns {:conflict, files} when two blockers touch the same file", %{
      repo: repo,
      source: source
    } do
      push_branch_with_file(repo.path, "feat/A", "shared.txt", "lineA\n")
      push_branch_with_file(repo.path, "feat/B", "shared.txt", "lineB\n")

      assert {:conflict, files} =
               IntegrationBuilder.rebuild(repo, "symphony/integration/x", ["feat/A", "feat/B"])

      assert "shared.txt" in files

      # Integration branch is NOT created on origin when conflicts occur.
      {_out, code} =
        System.cmd(
          "git",
          ["-C", source, "ls-remote", "--exit-code", "origin", "symphony/integration/x"],
          stderr_to_stdout: true
        )

      assert code != 0
    end

    test "rebuilding with same blockers produces a content-equivalent tree", %{
      repo: repo,
      bare: bare
    } do
      push_branch_with_file(repo.path, "feat/A", "a.txt", "A\n")
      push_branch_with_file(repo.path, "feat/B", "b.txt", "B\n")

      assert {:ok, _sha1} = IntegrationBuilder.rebuild(repo, "symphony/integration/x", ["feat/A", "feat/B"])
      tree1 = remote_tree_id(bare, "symphony/integration/x")

      assert {:ok, _sha2} = IntegrationBuilder.rebuild(repo, "symphony/integration/x", ["feat/A", "feat/B"])
      tree2 = remote_tree_id(bare, "symphony/integration/x")

      # Tree IDs are content hashes. Two builds with the same inputs must have
      # the same tree ID — only the merge commit timestamps differ.
      assert tree1 == tree2
    end

    test "blocker order doesn't change merge result (sorted internally)", %{
      repo: repo,
      bare: bare
    } do
      push_branch_with_file(repo.path, "feat/A", "a.txt", "A\n")
      push_branch_with_file(repo.path, "feat/B", "b.txt", "B\n")

      assert {:ok, _} = IntegrationBuilder.rebuild(repo, "symphony/integration/x", ["feat/A", "feat/B"])
      tree_ab = remote_tree_id(bare, "symphony/integration/x")

      assert {:ok, _} = IntegrationBuilder.rebuild(repo, "symphony/integration/x", ["feat/B", "feat/A"])
      tree_ba = remote_tree_id(bare, "symphony/integration/x")

      assert tree_ab == tree_ba
    end

    test "leaves source clone on its original branch after a build", %{repo: repo} do
      {start_branch, 0} = System.cmd("git", ["-C", repo.path, "branch", "--show-current"])
      start_branch = String.trim(start_branch)

      push_branch_with_file(repo.path, "feat/A", "a.txt", "A\n")
      assert {:ok, _} = IntegrationBuilder.rebuild(repo, "symphony/integration/x", ["feat/A"])

      {after_branch, 0} = System.cmd("git", ["-C", repo.path, "branch", "--show-current"])
      assert String.trim(after_branch) == start_branch
    end
  end

  defp remote_tree_id(bare, branch) do
    {sha, 0} =
      System.cmd("git", ["-C", bare, "rev-parse", branch <> "^{tree}"], stderr_to_stdout: true)

    String.trim(sha)
  end

  defp push_branch_with_file(source, branch, filename, contents) do
    {_out, 0} = System.cmd("git", ["-C", source, "checkout", "main"], stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["-C", source, "checkout", "-b", branch], stderr_to_stdout: true)

    GitFixture.commit_file(source, filename, contents, "add #{filename} on #{branch}")
    {_out, 0} = System.cmd("git", ["-C", source, "push", "-u", "origin", branch], stderr_to_stdout: true)
    {_out, 0} = System.cmd("git", ["-C", source, "checkout", "main"], stderr_to_stdout: true)
  end
end
