defmodule SymphonyElixir.Forge.GitHubStub do
  @moduledoc """
  In-memory `SymphonyElixir.Forge.GitHub` implementation for tests.

  Backed by the calling process's `:erlang.process_info(:dictionary)`, so each
  test sees its own isolated state and `async: true` is safe.

  ## Setup in a test

      setup do
        SymphonyElixir.Forge.GitHubStub.install()
        :ok
      end

  ## Drive PR state

      SymphonyElixir.Forge.GitHubStub.set_pr({"acme/repo", "feat/x"}, %{
        number: 42, base: "main", head: "feat/x", state: "OPEN", merged: false
      })

  ## Inspect calls

      SymphonyElixir.Forge.GitHubStub.calls(:retarget_pr)
  """

  @behaviour SymphonyElixir.Forge.GitHub

  @key {__MODULE__, :state}

  @doc """
  Configures the stub as the active forge implementation. Returns an `on_exit`-
  ready cleanup function.
  """
  @spec install() :: (-> :ok)
  def install do
    previous = Application.get_env(:symphony_elixir, :github_forge)
    Application.put_env(:symphony_elixir, :github_forge, __MODULE__)
    Process.put(@key, %{prs: %{}, calls: []})

    fn ->
      case previous do
        nil -> Application.delete_env(:symphony_elixir, :github_forge)
        mod -> Application.put_env(:symphony_elixir, :github_forge, mod)
      end
    end
  end

  @spec set_pr({String.t(), String.t()}, map() | nil) :: :ok
  def set_pr({repo, branch}, pr_or_nil) do
    update(fn s -> Map.update!(s, :prs, &Map.put(&1, {repo, branch}, pr_or_nil)) end)
  end

  @spec calls(atom() | :all) :: [tuple()]
  def calls(filter \\ :all) do
    state = Process.get(@key, %{calls: []})

    case filter do
      :all -> Enum.reverse(state.calls)
      kind -> state.calls |> Enum.reverse() |> Enum.filter(&match?({^kind, _}, &1))
    end
  end

  @impl true
  def pr_state(repo, branch) do
    record({:pr_state, {repo, branch}})

    case fetch({repo, branch}) do
      nil -> {:error, :not_found}
      pr -> {:ok, pr}
    end
  end

  @impl true
  def pr_for_branch(repo, branch) do
    record({:pr_for_branch, {repo, branch}})
    {:ok, fetch({repo, branch})}
  end

  @impl true
  def retarget_pr(repo, pr_number, new_base) do
    record({:retarget_pr, {repo, pr_number, new_base}})
    :ok
  end

  @impl true
  def delete_branch(repo, branch) do
    record({:delete_branch, {repo, branch}})
    :ok
  end

  defp fetch(key) do
    state = Process.get(@key, %{prs: %{}})
    Map.get(state.prs, key)
  end

  defp record(call) do
    update(fn s -> Map.update!(s, :calls, &[call | &1]) end)
  end

  defp update(fun) do
    state = Process.get(@key, %{prs: %{}, calls: []})
    Process.put(@key, fun.(state))
    :ok
  end
end
