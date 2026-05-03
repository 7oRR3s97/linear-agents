defmodule SymphonyElixir.GitFixture do
  @moduledoc """
  Throwaway git fixtures for Layer-2 tests.

  Each test gets its own `tmp_dir` (via `@tag :tmp_dir`), so async tests run
  in parallel without colliding. All operations are local — no network, no
  global state.

  ## Example

      defmodule MyWorktreeTest do
        use ExUnit.Case, async: true
        @moduletag :tmp_dir
        alias SymphonyElixir.GitFixture, as: Git

        test "stages a clean checkout", %{tmp_dir: tmp} do
          bare = Git.bare_repo(tmp)
          work = Git.working_clone(bare, tmp)
          sha = Git.commit_file(work, "README.md", "hi", "init")
          assert byte_size(sha) >= 7
        end
      end
  """

  @type path :: Path.t()

  @doc """
  Initializes a `--bare` git repository under `tmp_dir`. Returns the absolute
  path to the bare repo. Creates the parent directory as needed.
  """
  @spec bare_repo(path(), String.t()) :: path()
  def bare_repo(tmp_dir, name \\ "origin.git") do
    bare = Path.join(tmp_dir, name)
    File.mkdir_p!(Path.dirname(bare))
    {_out, 0} = run!(["init", "--bare", "-b", "main", bare], cd: nil)
    bare
  end

  @doc """
  Clones `bare_path` into `<tmp_dir>/<name>`, configures a deterministic git
  identity, and creates an initial commit on `main` so the branch exists. The
  returned path is the working tree.
  """
  @spec working_clone(path(), path(), String.t()) :: path()
  def working_clone(bare_path, tmp_dir, name \\ "work") do
    work = Path.join(tmp_dir, name)
    File.mkdir_p!(tmp_dir)
    {_out, 0} = run!(["clone", bare_path, work], cd: nil)

    {_out, 0} = run!(["config", "user.name", "Test User"], cd: work)
    {_out, 0} = run!(["config", "user.email", "test@example.com"], cd: work)

    if list_branches(work) == [] do
      {_out, 0} = run!(["checkout", "-b", "main"], cd: work)
      _ = commit_file(work, ".keep", "", "initial commit")
      {_out, 0} = run!(["push", "-u", "origin", "main"], cd: work)
    end

    work
  end

  @doc """
  Writes `contents` to `<repo>/<file>`, stages, commits with `message`, and
  returns the abbreviated SHA.
  """
  @spec commit_file(path(), Path.t(), String.t(), String.t()) :: String.t()
  def commit_file(repo, file, contents, message) do
    full_path = Path.join(repo, file)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, contents)

    {_out, 0} = run!(["add", file], cd: repo)
    {_out, 0} = run!(["commit", "-m", message], cd: repo)

    {sha, 0} = run!(["rev-parse", "--short", "HEAD"], cd: repo)
    String.trim(sha)
  end

  @doc """
  Creates a branch named `name` off `from` and checks it out.
  """
  @spec branch(path(), String.t(), String.t()) :: :ok
  def branch(repo, name, from \\ "main") do
    {_out, 0} = run!(["checkout", from], cd: repo)
    {_out, 0} = run!(["checkout", "-b", name], cd: repo)
    :ok
  end

  @doc """
  Returns the abbreviated SHA of the current HEAD.
  """
  @spec head_sha(path()) :: String.t()
  def head_sha(repo) do
    {sha, 0} = run!(["rev-parse", "--short", "HEAD"], cd: repo)
    String.trim(sha)
  end

  @doc """
  Returns the list of local branches in the working clone.
  """
  @spec list_branches(path()) :: [String.t()]
  def list_branches(repo) do
    case System.cmd("git", ["branch", "--format=%(refname:short)"], cd: repo, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp run!(args, opts) when is_list(args) do
    cmd_opts = if opts[:cd], do: [cd: opts[:cd], stderr_to_stdout: true], else: [stderr_to_stdout: true]

    case System.cmd("git", args, cmd_opts) do
      {_output, 0} = ok ->
        ok

      {output, code} ->
        raise """
        git #{Enum.join(args, " ")} failed with exit code #{code}
        cwd: #{inspect(opts[:cd])}
        output: #{output}
        """
    end
  end
end
