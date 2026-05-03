defmodule SymphonyElixir.Repos.WorktreeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitFixture
  alias SymphonyElixir.Repos.Worktree

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    # Each test sets up its own bare + working clone. The "source clone" is
    # the working clone — that's what Symphony's worktrees attach to.
    bare = GitFixture.bare_repo(tmp)
    source = GitFixture.working_clone(bare, tmp, "source")

    # Add a feature branch to the source so worktrees can branch from it.
    {_out, 0} = System.cmd("git", ["-C", source, "checkout", "-b", "feat/A"])
    GitFixture.commit_file(source, "feat-a.txt", "A\n", "feat A")
    {_out, 0} = System.cmd("git", ["-C", source, "push", "-u", "origin", "feat/A"])
    {_out, 0} = System.cmd("git", ["-C", source, "checkout", "main"])

    workspace_root = Path.join(tmp, "workspaces")
    File.mkdir_p!(workspace_root)

    repo_resolution = %{
      handle: "src",
      path: source,
      remote: "origin",
      default_base: "main"
    }

    {:ok,
     bare: bare,
     source: source,
     workspace_root: workspace_root,
     repo: repo_resolution}
  end

  describe "add/4" do
    test "creates a worktree branched from main and checks out a new branch", %{
      repo: repo,
      workspace_root: ws
    } do
      assert {:ok, %{path: path, branch: "feat/X"}} =
               Worktree.add(repo, "PES-1", "main", "feat/X", workspace_root: ws)

      assert File.dir?(path)
      # In a git worktree, `.git` is a regular file (gitlink), not a directory.
      assert File.exists?(Path.join(path, ".git"))
      {current, 0} = System.cmd("git", ["-C", path, "branch", "--show-current"])
      assert String.trim(current) == "feat/X"
    end

    test "branches from a non-main ref", %{repo: repo, workspace_root: ws, source: source} do
      assert {:ok, %{path: path}} =
               Worktree.add(repo, "PES-2", "feat/A", "feat/X-on-A", workspace_root: ws)

      assert File.exists?(Path.join(path, "feat-a.txt"))

      {head, 0} = System.cmd("git", ["-C", path, "rev-parse", "HEAD"])
      {feat_a_sha, 0} = System.cmd("git", ["-C", source, "rev-parse", "feat/A"])

      assert String.trim(head) == String.trim(feat_a_sha)
    end

    test "idempotent: re-adding with the same branch is a no-op", %{repo: repo, workspace_root: ws} do
      assert {:ok, %{path: p1}} = Worktree.add(repo, "PES-3", "main", "feat/Y", workspace_root: ws)
      File.write!(Path.join(p1, "scratch.txt"), "in progress")

      assert {:ok, %{path: ^p1}} = Worktree.add(repo, "PES-3", "main", "feat/Y", workspace_root: ws)
      assert File.read!(Path.join(p1, "scratch.txt")) == "in progress"
    end

    test "errors out cleanly on a missing base ref", %{repo: repo, workspace_root: ws} do
      assert {:error, _reason} =
               Worktree.add(repo, "PES-4", "main", "feat/Z", workspace_root: ws,
                 base_ref_override: "does-not-exist"
               )

      refute File.exists?(Path.join([ws, repo.handle, "PES-4"]))
    end

    test "issue identifier is sanitized in the worktree path", %{repo: repo, workspace_root: ws} do
      assert {:ok, %{path: path}} = Worktree.add(repo, "MT/Bad Ident", "main", "feat/sanitized", workspace_root: ws)
      assert Path.basename(path) == "MT_Bad_Ident"
    end
  end

  describe "list/2" do
    test "reports active worktrees including dirty status", %{repo: repo, workspace_root: ws} do
      {:ok, %{path: p}} = Worktree.add(repo, "PES-LIST", "main", "feat/list", workspace_root: ws)
      File.write!(Path.join(p, "dirty.txt"), "uncommitted")

      assert {:ok, entries} = Worktree.list(repo)
      entry = Enum.find(entries, fn e -> e.branch == "feat/list" end)
      assert entry
      assert entry.dirty == true
      assert is_binary(entry.head)
    end
  end

  describe "remove/3" do
    test "removes the worktree dir and git metadata; source clone unaffected", %{
      repo: repo,
      workspace_root: ws,
      source: source
    } do
      {:ok, %{path: path}} = Worktree.add(repo, "PES-REM", "main", "feat/rm", workspace_root: ws)
      assert File.dir?(path)

      assert :ok = Worktree.remove(repo, "PES-REM", workspace_root: ws)
      refute File.dir?(path)
      assert File.dir?(source)
    end

    test "remove of a missing worktree is a no-op", %{repo: repo, workspace_root: ws} do
      assert :ok = Worktree.remove(repo, "PES-NOPE", workspace_root: ws)
    end
  end

  describe "fetch/1" do
    test "runs git fetch on the source clone", %{repo: repo} do
      assert :ok = Worktree.fetch(repo)
    end
  end

  describe "concurrency" do
    test "10 parallel adds against the same source serialize cleanly", %{
      repo: repo,
      workspace_root: ws
    } do
      results =
        1..10
        |> Enum.map(fn i ->
          Task.async(fn ->
            Worktree.add(repo, "PES-#{i}", "main", "feat/x-#{i}", workspace_root: ws)
          end)
        end)
        |> Task.await_many(15_000)

      assert Enum.all?(results, &match?({:ok, _}, &1)),
             "some adds failed: #{inspect(results)}"
    end
  end
end
