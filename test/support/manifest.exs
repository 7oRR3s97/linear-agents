defmodule SymphonyElixir.E2EManifest do
  @moduledoc """
  Append-only JSONL audit log for live e2e tests. One record per event.
  Stays valid mid-test; if a run aborts, the operator can `cat` the file
  and see exactly what was created.
  """

  @type event :: map()

  @doc """
  Opens a manifest at `path`. Returns the path. Truncates any prior file.
  """
  @spec open!(Path.t()) :: Path.t()
  def open!(path) when is_binary(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    path
  end

  @doc """
  Appends one event record. Adds an automatic `ts` field if missing.
  """
  @spec append!(Path.t(), event()) :: :ok
  def append!(path, %{} = event) when is_binary(path) do
    enriched = Map.put_new_lazy(event, :ts, fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)
    line = Jason.encode!(enriched) <> "\n"
    File.write!(path, line, [:append])
    :ok
  end

  @doc """
  Reads back the manifest as a list of decoded maps. Useful for assertions.
  """
  @spec read!(Path.t()) :: [event()]
  def read!(path) when is_binary(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
