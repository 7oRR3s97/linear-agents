defmodule SymphonyElixir.Repos.Lockbox do
  @moduledoc """
  Per-source-repo serializer for git operations.

  Every git operation that touches a source clone or its `.git` directory
  flows through `with_lock/2`, which routes to a `GenServer` keyed by repo
  handle and registered under `Symphony.Repos.LockboxRegistry`. The lockbox
  starts lazily — the first `with_lock/2` call for a handle creates it.

  The lockbox is **not** re-entrant. Calling `with_lock/2` from within an
  already-held lock for the same handle will deadlock the caller. Operations
  must be flat.

  If the function raises or throws, the lock is released and the lockbox
  process stays alive — subsequent callers see a clean state.
  """

  use GenServer

  @type handle :: String.t()
  @type result :: {:ok, term()} | {:error, {:exception, Exception.t()} | {:exit, term()}}

  @registry SymphonyElixir.Repos.LockboxRegistry
  @supervisor SymphonyElixir.Repos.LockboxSupervisor

  @doc """
  Acquires the lock for `handle`, runs `fun.()` while holding it, releases the
  lock, and returns the result.

  Successful execution returns `{:ok, value}`. Exceptions and exits inside
  `fun` are caught, the lock released, and the failure surfaced as
  `{:error, {:exception, ex}}` or `{:error, {:exit, reason}}`.
  """
  @spec with_lock(handle(), (-> term()), keyword()) :: result()
  def with_lock(handle, fun, opts \\ []) when is_binary(handle) and is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    pid = ensure_started!(handle)
    GenServer.call(pid, {:run, fun}, timeout)
  end

  @doc """
  Returns the list of repo handles that currently have a lockbox process.
  """
  @spec list() :: [handle()]
  def list do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc false
  @spec ensure_started!(handle()) :: pid()
  def ensure_started!(handle) when is_binary(handle) do
    case Registry.lookup(@registry, handle) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, handle}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
          {:error, reason} -> raise "failed to start lockbox for #{handle}: #{inspect(reason)}"
        end
    end
  end

  @doc false
  @spec child_spec(handle()) :: Supervisor.child_spec()
  def child_spec(handle) when is_binary(handle) do
    %{
      id: {__MODULE__, handle},
      start: {__MODULE__, :start_link, [handle]},
      restart: :transient,
      type: :worker
    }
  end

  @doc false
  @spec start_link(handle()) :: GenServer.on_start()
  def start_link(handle) when is_binary(handle) do
    GenServer.start_link(__MODULE__, handle, name: via(handle))
  end

  @impl true
  def init(handle) do
    {:ok, %{handle: handle}}
  end

  @impl true
  def handle_call({:run, fun}, _from, state) do
    result =
      try do
        {:ok, fun.()}
      rescue
        exception -> {:error, {:exception, exception}}
      catch
        :exit, reason -> {:error, {:exit, reason}}
        :throw, value -> {:error, {:exit, {:throw, value}}}
      end

    {:reply, result, state}
  end

  defp via(handle) do
    {:via, Registry, {@registry, handle}}
  end

  defmodule Supervisor do
    @moduledoc false

    use Elixir.Supervisor

    @registry SymphonyElixir.Repos.LockboxRegistry
    @dynamic_supervisor SymphonyElixir.Repos.LockboxSupervisor

    @spec start_link(keyword()) :: Elixir.Supervisor.on_start()
    def start_link(opts \\ []) do
      Elixir.Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl true
    def init(_opts) do
      children = [
        {Registry, keys: :unique, name: @registry},
        {DynamicSupervisor, name: @dynamic_supervisor, strategy: :one_for_one}
      ]

      Elixir.Supervisor.init(children, strategy: :one_for_all)
    end
  end
end
