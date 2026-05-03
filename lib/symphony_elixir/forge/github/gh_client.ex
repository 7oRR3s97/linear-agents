defmodule SymphonyElixir.Forge.GitHub.GhClient do
  @moduledoc """
  `gh` CLI implementation of `SymphonyElixir.Forge.GitHub`.

  Each call shells out to `gh` with `--json` / `--jq` flags so the parser
  works against stable output. Tests can override the binary via
  `Application.put_env(:symphony_elixir, :gh_binary, "/path/to/stub")`.
  """

  @behaviour SymphonyElixir.Forge.GitHub

  @impl true
  def pr_state(repo, branch) do
    case pr_for_branch(repo, branch) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %{} = pr} -> {:ok, pr}
      {:error, _} = err -> err
    end
  end

  @impl true
  def pr_for_branch(repo, branch) do
    args = [
      "pr",
      "list",
      "--repo",
      repo,
      "--head",
      branch,
      "--state",
      "all",
      "--json",
      "number,baseRefName,headRefName,state,mergedAt",
      "--limit",
      "1"
    ]

    case run(args) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, []} ->
            {:ok, nil}

          {:ok, [pr | _]} ->
            {:ok,
             %{
               number: pr["number"],
               base: pr["baseRefName"],
               head: pr["headRefName"],
               state: pr["state"],
               merged: pr["state"] == "MERGED" or pr["mergedAt"] not in [nil, ""]
             }}

          {:error, reason} ->
            {:error, {:malformed_response, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def retarget_pr(repo, pr_number, new_base)
      when is_binary(repo) and is_integer(pr_number) and is_binary(new_base) do
    args = ["pr", "edit", to_string(pr_number), "--repo", repo, "--base", new_base]

    case run(args) do
      {:ok, _output} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def delete_branch(repo, branch) when is_binary(repo) and is_binary(branch) do
    args = [
      "api",
      "-X",
      "DELETE",
      "repos/#{repo}/git/refs/heads/#{branch}"
    ]

    case run(args) do
      {:ok, _output} -> :ok
      {:error, :not_found} -> :ok
      {:error, _} = err -> err
    end
  end

  defp run(args) do
    binary = Application.get_env(:symphony_elixir, :gh_binary, "gh")

    case System.find_executable(binary) do
      nil ->
        {:error, :gh_cli_missing}

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {output, 0} ->
            {:ok, output}

          {output, _code} ->
            {:error, classify_error(output)}
        end
    end
  end

  defp classify_error(output) when is_binary(output) do
    cond do
      output =~ "rate limit" -> :rate_limited
      output =~ "API rate limit exceeded" -> :rate_limited
      output =~ "HTTP 429" -> :rate_limited
      output =~ "HTTP 403" -> :rate_limited
      output =~ "Not Found" -> :not_found
      output =~ "no pull requests" -> :not_found
      true -> {:gh, String.trim(output)}
    end
  end
end
