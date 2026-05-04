defmodule SymphonyElixir.Agent.ClaudeCode.Runner do
  @moduledoc """
  Runs one Claude Code turn against a workspace using `claude --print`.

  In `--print` mode, Claude Code runs autonomously until it produces a
  final answer (potentially using many internal tool calls — Read, Bash,
  Edit, etc.). Each Symphony "turn" is one invocation; the agent's full
  behaviour for the issue typically fits in one invocation.

  Auth flows through the user's Claude subscription (`claude login`). No
  `ANTHROPIC_API_KEY` is needed.
  """

  require Logger

  @type session :: %{workspace: String.t(), issue_id: String.t() | nil, settings: map()}

  @doc """
  Initialises a "session" handle. Symphony passes this around per worker
  run; the actual subprocess is spawned per turn in `run_turn/3`.
  """
  @spec start_session(String.t(), keyword()) :: {:ok, session()}
  def start_session(workspace, opts \\ []) when is_binary(workspace) do
    settings = Keyword.get(opts, :claude_code_settings) || claude_code_settings()
    issue_id = Keyword.get(opts, :issue_id)

    {:ok, %{workspace: workspace, issue_id: issue_id, settings: settings}}
  end

  @doc """
  Stops the session. A no-op for `--print` mode.
  """
  @spec stop_session(session()) :: :ok
  def stop_session(_session), do: :ok

  @doc """
  Runs one turn — invokes `claude --print` with the rendered prompt and the
  workspace as cwd. Captures stdout (the agent's final response) and
  returns it. Returns `{:error, {:claude_failed, code, output}}` on
  non-zero exit.

  `opts`:
  - `:on_message` (default: noop) — called once with the captured output
    so the orchestrator can publish it.
  """
  @spec run_turn(session(), String.t(), keyword()) ::
          {:ok, %{stdout: String.t()}} | {:error, term()}
  def run_turn(%{workspace: workspace, settings: settings} = _session, prompt, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _msg -> :ok end)
    args = build_args(settings, prompt)
    command = settings.command || "claude"

    Logger.info(
      "Spawning #{command} in #{workspace} permission_mode=#{settings.permission_mode}"
    )

    env = forwarded_env()

    try do
      case System.cmd(command, args, cd: workspace, stderr_to_stdout: true, env: env) do
        {output, 0} ->
          on_message.({:assistant_output, output})
          {:ok, %{stdout: output}}

        {output, code} ->
          {:error, {:claude_failed, code, output}}
      end
    rescue
      e -> {:error, {:exception, Exception.message(e)}}
    end
  end

  # Tracing env vars that the Stop hook (`langfuse_hook.py`) reads.
  # Other env (PATH, HOME, …) is inherited by default; this list only adds
  # the tracing-specific names so they reach the subprocess explicitly.
  @forwarded_env_keys ~w(
    TRACE_TO_LANGFUSE
    LANGFUSE_BASE_URL
    LANGFUSE_PUBLIC_KEY
    LANGFUSE_SECRET_KEY
    CC_LANGFUSE_DEBUG
  )

  defp forwarded_env do
    Enum.flat_map(@forwarded_env_keys, fn key ->
      case System.get_env(key) do
        nil -> []
        "" -> []
        value -> [{key, value}]
      end
    end)
  end

  defp build_args(settings, prompt) do
    base = [
      "--print",
      "--permission-mode",
      settings.permission_mode || "bypassPermissions"
    ]

    base ++ List.wrap(settings.extra_args || []) ++ [prompt]
  end

  defp claude_code_settings do
    settings = SymphonyElixir.Config.settings!().claude_code

    %{
      command: settings.command,
      permission_mode: settings.permission_mode,
      turn_timeout_ms: settings.turn_timeout_ms,
      read_timeout_ms: settings.read_timeout_ms,
      stall_timeout_ms: settings.stall_timeout_ms,
      extra_args: settings.extra_args
    }
  end
end
