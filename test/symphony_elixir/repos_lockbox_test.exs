defmodule SymphonyElixir.Repos.LockboxTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Repos.Lockbox

  # The Lockbox.Supervisor is started by SymphonyElixir.Application.

  test "with_lock runs the function and returns its result" do
    handle = unique_handle()

    assert {:ok, 42} = Lockbox.with_lock(handle, fn -> 42 end)
  end

  test "concurrent callers serialize on the same handle" do
    handle = unique_handle()
    parent = self()

    tasks =
      for i <- 1..50 do
        Task.async(fn ->
          Lockbox.with_lock(handle, fn ->
            send(parent, {:enter, i})
            Process.sleep(1)
            send(parent, {:exit, i})
            i
          end)
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.sort(results) == Enum.sort(for i <- 1..50, do: {:ok, i})

    events = drain_messages([])

    assert serialized?(events),
           "expected enter/exit pairs to be strictly nested, got #{inspect(events)}"
  end

  test "different handles do not block each other" do
    handle_a = unique_handle()
    handle_b = unique_handle()

    # Two locks held simultaneously across different handles must overlap in
    # time. We verify this by having each lock sleep ~30ms; if they
    # serialized, total wall time would exceed 50ms; if concurrent, ~30ms.
    {time_us, [a, b]} =
      :timer.tc(fn ->
        Task.await_many(
          [
            Task.async(fn -> Lockbox.with_lock(handle_a, fn -> Process.sleep(30); :a end) end),
            Task.async(fn -> Lockbox.with_lock(handle_b, fn -> Process.sleep(30); :b end) end)
          ],
          1_000
        )
      end)

    assert a == {:ok, :a}
    assert b == {:ok, :b}
    elapsed_ms = div(time_us, 1_000)
    assert elapsed_ms < 60, "expected concurrent execution (<60ms), got #{elapsed_ms}ms"
  end

  test "raised exception releases the lock and the lockbox stays alive" do
    handle = unique_handle()

    assert {:error, {:exception, %RuntimeError{}}} =
             Lockbox.with_lock(handle, fn -> raise "boom" end)

    # second call should succeed — lock released, lockbox survived.
    assert {:ok, :ok} = Lockbox.with_lock(handle, fn -> :ok end)
  end

  test "throw in the function releases the lock" do
    handle = unique_handle()

    assert {:error, {:exit, _}} =
             Lockbox.with_lock(handle, fn -> exit(:nope) end)

    assert {:ok, :recovered} = Lockbox.with_lock(handle, fn -> :recovered end)
  end

  test "list/0 returns active lockbox handles" do
    handle = unique_handle()
    Lockbox.with_lock(handle, fn -> :ok end)

    handles = Lockbox.list()
    assert handle in handles
  end

  defp unique_handle do
    "test-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp drain_messages(acc) do
    receive do
      {:enter, _i} = msg -> drain_messages([msg | acc])
      {:exit, _i} = msg -> drain_messages([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp serialized?(events) do
    {ok?, _stack} =
      Enum.reduce(events, {true, []}, fn
        _evt, {false, _stack} = state ->
          state

        {:enter, id}, {_ok, stack} ->
          if stack == [] do
            {true, [id]}
          else
            {false, stack}
          end

        {:exit, id}, {_ok, [head | rest]} ->
          {head == id, rest}

        {:exit, _id}, {_ok, []} ->
          {false, []}
      end)

    ok?
  end
end
