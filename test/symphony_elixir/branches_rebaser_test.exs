defmodule SymphonyElixir.Branches.RebaserTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Branches.Rebaser
  alias SymphonyElixir.GitFixture

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    bare = GitFixture.bare_repo(tmp)
    source = GitFixture.working_clone(bare, tmp, "src")

    repo = %{handle: "src", path: source, remote: "origin", default_base: "main"}
    {:ok, bare: bare, source: source, repo: repo}
  end

  describe "rebase_onto/4" do
    test "drops merged blocker commits and force-pushes the dependent", %{repo: repo, bare: bare} do
      # Set up: A's branch (added a.txt), then X's branch off A (added x.txt).
      # Then A merges to main. We want X's branch rebased onto main, dropping
      # A's commits (now in main) and keeping only X's.
      push_branch(repo.path, "feat/A", "a.txt", "from A\n")

      # Make X branch from feat/A's tip.
      System.cmd("git", ["-C", repo.path, "checkout", "feat/A"], stderr_to_stdout: true)
      System.cmd("git", ["-C", repo.path, "checkout", "-b", "feat/X"], stderr_to_stdout: true)
      GitFixture.commit_file(repo.path, "x.txt", "from X\n", "X work")
      System.cmd("git", ["-C", repo.path, "push", "-u", "origin", "feat/X"], stderr_to_stdout: true)

      # Simulate A merging: fast-forward main to include feat/A, push.
      System.cmd("git", ["-C", repo.path, "checkout", "main"], stderr_to_stdout: true)
      System.cmd("git", ["-C", repo.path, "merge", "feat/A", "--no-ff", "-m", "merge A"], stderr_to_stdout: true)
      System.cmd("git", ["-C", repo.path, "push", "origin", "main"], stderr_to_stdout: true)

      # Rebaser runs.
      assert {:ok, %{from: from, to: to}} = Rebaser.rebase_onto(repo, "feat/X", "main", fetch: false)
      assert is_binary(from) and is_binary(to)
      refute from == to

      # The remote feat/X now contains a.txt (from main) AND x.txt.
      check = Path.join(Path.dirname(repo.path), "verify")
      System.cmd("git", ["clone", bare, check], stderr_to_stdout: true)
      System.cmd("git", ["-C", check, "checkout", "feat/X"], stderr_to_stdout: true)
      assert File.exists?(Path.join(check, "a.txt"))
      assert File.exists?(Path.join(check, "x.txt"))

      # feat/X's diff against main contains only X's commits — A's commits
      # are now in main and have been dropped from feat/X.
      {only_x, 0} =
        System.cmd("git", ["-C", check, "log", "--format=%s", "origin/main..HEAD"], stderr_to_stdout: true)

      assert only_x =~ "X work"
      refute only_x =~ "merge A"
    end

    test "is a no-op when the branch is already up to date with target", %{repo: repo} do
      push_branch(repo.path, "feat/up-to-date", "f.txt", "x")
      # No new commits on main.

      assert {:noop, :already_up_to_date} =
               Rebaser.rebase_onto(repo, "feat/up-to-date", "main", fetch: false)
    end

    test "returns :branch_missing when the dependent branch isn't on origin", %{repo: repo} do
      assert {:noop, :branch_missing} =
               Rebaser.rebase_onto(repo, "feat/never-pushed", "main", fetch: false)
    end

    test "surfaces conflicts cleanly without force-pushing", %{repo: repo, bare: bare} do
      # X edits shared.txt before main does.
      push_branch(repo.path, "feat/X", "shared.txt", "X version\n")

      # main also edits shared.txt — divergent change.
      System.cmd("git", ["-C", repo.path, "checkout", "main"], stderr_to_stdout: true)
      GitFixture.commit_file(repo.path, "shared.txt", "main version\n", "main change")
      System.cmd("git", ["-C", repo.path, "push", "origin", "main"], stderr_to_stdout: true)

      assert {:conflict, files} = Rebaser.rebase_onto(repo, "feat/X", "main", fetch: false)
      assert "shared.txt" in files

      # Original feat/X tip is unchanged on origin (no force-push happened).
      {head_before, 0} =
        System.cmd("git", ["-C", bare, "rev-parse", "feat/X"], stderr_to_stdout: true)

      head_before = String.trim(head_before)

      # Re-running yields the same conflict (idempotent failure).
      assert {:conflict, _} = Rebaser.rebase_onto(repo, "feat/X", "main", fetch: false)

      {head_after, 0} =
        System.cmd("git", ["-C", bare, "rev-parse", "feat/X"], stderr_to_stdout: true)

      assert String.trim(head_after) == head_before
    end

    test "refuses to rebase a protected base branch (main)", %{repo: repo} do
      assert {:error, {:rejected_protected_branch, "main"}} =
               Rebaser.rebase_onto(repo, "main", "main", fetch: false)
    end

    test "refuses to rebase common protected names regardless of repo's default_base", %{repo: repo} do
      for name <- ["main", "master", "trunk", "develop"] do
        assert {:error, {:rejected_protected_branch, ^name}} =
                 Rebaser.rebase_onto(repo, name, "main", fetch: false)
      end
    end

    test "refuses to rebase the configured default_base when it's non-standard" do
      custom_repo = %{
        handle: "weird",
        path: "/tmp/weird",
        remote: "origin",
        default_base: "production"
      }

      assert {:error, {:rejected_protected_branch, "production"}} =
               Rebaser.rebase_onto(custom_repo, "production", "main", fetch: false)
    end

    test "does not disturb the source clone's checkout", %{repo: repo} do
      push_branch(repo.path, "feat/A", "a.txt", "a\n")
      push_branch(repo.path, "feat/X", "x.txt", "x\n")

      System.cmd("git", ["-C", repo.path, "checkout", "main"], stderr_to_stdout: true)
      {start_branch, 0} = System.cmd("git", ["-C", repo.path, "branch", "--show-current"])
      start_branch = String.trim(start_branch)

      Rebaser.rebase_onto(repo, "feat/X", "main", fetch: false)

      {after_branch, 0} = System.cmd("git", ["-C", repo.path, "branch", "--show-current"])
      assert String.trim(after_branch) == start_branch
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
