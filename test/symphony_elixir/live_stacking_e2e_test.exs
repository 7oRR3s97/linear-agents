defmodule SymphonyElixir.LiveStackingE2ETest do
  @moduledoc """
  Live end-to-end test for the multi-repo + dependency-stacking pipeline.

  - Real Linear: creates a project + four issues, drives state transitions
    via the real GraphQL API.
  - Local Git only: bare + working clones in tmp_dir act as origin.
  - Forge.GitHubStub stands in for the GitHub PR API.
  - SymphonyElixir.MockAgent plays the agent's role (deterministic commits).
  - SymphonyElixir.FakeHuman plays the reviewer.

  Gated behind SYMPHONY_RUN_LIVE_STACKING_E2E=1. Default `mix test` skips it.
  """

  use ExUnit.Case, async: false

  require Logger

  # Aliases below are commented out in this skeleton (Task 2.4) to keep
  # `--warnings-as-errors` clean. Subsequent tasks (2.5+) re-enable them as
  # the scenarios that use each module land.
  # alias SymphonyElixir.Branches.{BaseResolver, ConflictFallback, IntegrationBuilder, Reconciler}
  # alias SymphonyElixir.Deps.Cascade
  alias SymphonyElixir.E2EManifest
  # alias SymphonyElixir.FakeHuman
  alias SymphonyElixir.Forge.GitHubStub
  alias SymphonyElixir.GitFixture
  # alias SymphonyElixir.Linear.Client
  # alias SymphonyElixir.Linear.Issue
  # alias SymphonyElixir.MockAgent

  @moduletag :live_stacking_e2e
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  # @default_team_key reused once Linear provisioning lands in Task 2.5.
  # @default_team_key "SYME2E"
  @gh_slug "acme/src"

  @skip_reason if(System.get_env("SYMPHONY_RUN_LIVE_STACKING_E2E") != "1",
                  do: "set SYMPHONY_RUN_LIVE_STACKING_E2E=1 to enable live Linear + local-Git stacking e2e")

  setup %{tmp_dir: tmp} do
    if @skip_reason, do: :ok, else: setup_live(tmp)
  end

  defp setup_live(tmp) do
    cleanup_stub = GitHubStub.install()
    manifest_path = Path.join(tmp, "LIVE_STACKING_E2E_MANIFEST.jsonl")
    E2EManifest.open!(manifest_path)

    bare = GitFixture.bare_repo(tmp, "src.git")
    work = GitFixture.working_clone(bare, tmp, "src")

    repo = %{
      path: work,
      bare_path: bare,
      gh_slug: @gh_slug,
      handle: "src",
      remote: "origin",
      default_base: "main"
    }

    on_exit(fn ->
      cleanup_stub.()
      Logger.info("LIVE_STACKING_E2E manifest: #{manifest_path}")
    end)

    {:ok, tmp: tmp, manifest_path: manifest_path, repo: repo}
  end

  @tag skip: @skip_reason
  test "live stacking pipeline against real Linear and local Git", %{
    tmp: tmp,
    manifest_path: manifest_path,
    repo: repo
  } do
    # This skeleton just confirms setup runs. Scenarios A–E land in subsequent tasks.
    assert is_binary(manifest_path)
    assert File.exists?(manifest_path)
    assert File.exists?(repo.path)
    assert File.exists?(repo.bare_path)
    _ = tmp
    :ok
  end
end
