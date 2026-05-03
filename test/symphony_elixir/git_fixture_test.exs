defmodule SymphonyElixir.GitFixtureTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitFixture

  @moduletag :tmp_dir

  test "bare_repo creates a bare git repository", %{tmp_dir: tmp} do
    bare = GitFixture.bare_repo(tmp)

    assert File.dir?(bare)
    assert File.exists?(Path.join(bare, "HEAD"))
    refute File.exists?(Path.join(bare, ".git"))
    assert {_out, 0} = System.cmd("git", ["-C", bare, "rev-parse", "--is-bare-repository"], stderr_to_stdout: true)
  end

  test "working_clone produces a checked-out tree on main", %{tmp_dir: tmp} do
    bare = GitFixture.bare_repo(tmp)
    work = GitFixture.working_clone(bare, tmp)

    assert File.dir?(Path.join(work, ".git"))
    assert "main" in GitFixture.list_branches(work)
    assert is_binary(GitFixture.head_sha(work))
  end

  test "commit_file stages, commits, and returns short SHA", %{tmp_dir: tmp} do
    bare = GitFixture.bare_repo(tmp)
    work = GitFixture.working_clone(bare, tmp)

    sha = GitFixture.commit_file(work, "hello.txt", "world\n", "add hello")

    assert byte_size(sha) >= 7
    assert File.read!(Path.join(work, "hello.txt")) == "world\n"
  end

  test "branch creates and checks out a new branch from main", %{tmp_dir: tmp} do
    bare = GitFixture.bare_repo(tmp)
    work = GitFixture.working_clone(bare, tmp)

    :ok = GitFixture.branch(work, "feat/x")

    branches = GitFixture.list_branches(work)
    assert "main" in branches
    assert "feat/x" in branches

    {current, 0} = System.cmd("git", ["-C", work, "branch", "--show-current"], stderr_to_stdout: true)
    assert String.trim(current) == "feat/x"
  end

  test "two tests with separate tmp_dirs do not collide", %{tmp_dir: tmp} do
    bare_a = GitFixture.bare_repo(tmp, "a.git")
    bare_b = GitFixture.bare_repo(tmp, "b.git")

    work_a = GitFixture.working_clone(bare_a, tmp, "work-a")
    work_b = GitFixture.working_clone(bare_b, tmp, "work-b")

    sha_a = GitFixture.commit_file(work_a, "in-a.txt", "a", "a")
    sha_b = GitFixture.commit_file(work_b, "in-b.txt", "b", "b")

    refute sha_a == sha_b
    refute File.exists?(Path.join(work_b, "in-a.txt"))
    refute File.exists?(Path.join(work_a, "in-b.txt"))
  end
end
