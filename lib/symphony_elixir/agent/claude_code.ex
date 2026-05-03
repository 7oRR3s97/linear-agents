defmodule SymphonyElixir.Agent.ClaudeCode do
  @moduledoc """
  Claude Code stream-json runtime adapter.

  Runs the operator's local `claude` CLI in non-interactive `stream-json`
  mode so Symphony can drive it as a subprocess: feed user messages over
  stdin (one JSON line each), read normalized events from stdout.

  Authentication flows through the user's Claude subscription via
  `claude login`. No `ANTHROPIC_API_KEY` is required.

  ## What's in this PR

  This is a focused first slice: the **stream-json parser** and small
  helpers, plus the config plumbing (`agent.runtime: "claude_code"` and the
  `claude_code` config block). The full subprocess wiring inside
  `AgentRunner` is a separate follow-up — keeping the codex path live until
  the swap is fully integration-tested with a live `claude`.

  ## Stream-JSON shapes

  Outbound (sent on stdin):

      {"type":"user","message":{"role":"user","content":[{"type":"text","text":"…"}]}}

  Inbound (parsed from stdout, one JSON object per line):

  - `{"type":"system","subtype":"init", ...}` → `:session_started`
  - `{"type":"assistant","message":{...}}` → `:assistant_message`
  - `{"type":"user","message":{...}}` → `:tool_result`
  - `{"type":"result","subtype":"success","usage":{…}, ...}` → `:turn_completed`
  - `{"type":"result","subtype":"error_max_turns", ...}` → `:turn_failed`
  - anything else → `:other_message`
  - unparseable line → `:malformed`
  """

  @doc "Parses one stdout line into a normalized event tuple."
  @spec parse_event(String.t() | binary()) ::
          {:event, atom(), map()}
          | {:malformed, String.t()}
  def parse_event(line) when is_binary(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      {:event, :other_message, %{}}
    else
      case Jason.decode(trimmed) do
        {:ok, %{} = decoded} -> {:event, classify(decoded), decoded}
        {:error, _reason} -> {:malformed, trimmed}
      end
    end
  end

  defp classify(%{"type" => "system", "subtype" => "init"}), do: :session_started
  defp classify(%{"type" => "assistant"}), do: :assistant_message
  defp classify(%{"type" => "user", "message" => %{"content" => content}}) when is_list(content) do
    if Enum.any?(content, fn c -> Map.get(c, "type") == "tool_result" end) do
      :tool_result
    else
      :other_message
    end
  end

  defp classify(%{"type" => "result", "subtype" => "success"}), do: :turn_completed
  defp classify(%{"type" => "result", "subtype" => "error_max_turns"}), do: :turn_failed
  defp classify(%{"type" => "result"}), do: :turn_failed
  defp classify(_), do: :other_message

  @doc """
  Renders a user message as a single-line JSON string suitable for piping to
  Claude Code's stdin in `stream-json` input mode.
  """
  @spec build_user_message(String.t(), keyword()) :: String.t()
  def build_user_message(text, opts \\ []) when is_binary(text) do
    payload = %{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => [%{"type" => "text", "text" => text}]
      }
    }

    payload =
      case Keyword.get(opts, :session_id) do
        sid when is_binary(sid) and sid != "" -> Map.put(payload, "session_id", sid)
        _ -> payload
      end

    Jason.encode!(payload)
  end

  @doc """
  Builds the argv for spawning the `claude` CLI. Tests use this; the actual
  Port.open call lives outside this module so it can be unit-tested without
  shelling out.
  """
  @spec spawn_args(map(), keyword()) :: [String.t()]
  def spawn_args(claude_code_settings, opts \\ []) do
    session_id = Keyword.fetch!(opts, :session_id)
    permission = Map.get(claude_code_settings, :permission_mode) || "bypassPermissions"

    [
      "--print",
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
      "--verbose",
      "--permission-mode",
      permission,
      "--session-id",
      session_id
    ] ++ List.wrap(Map.get(claude_code_settings, :extra_args) || [])
  end

  @doc """
  Extracts token usage from a `:turn_completed` event payload, if present.
  Returns a map of `%{input_tokens, output_tokens, total_tokens}`.
  """
  @spec extract_usage(map()) :: %{input_tokens: integer(), output_tokens: integer(), total_tokens: integer()}
  def extract_usage(%{"usage" => usage}) when is_map(usage) do
    input = Map.get(usage, "input_tokens", 0)
    output = Map.get(usage, "output_tokens", 0)
    total = Map.get(usage, "total_tokens", input + output)

    %{
      input_tokens: to_int(input),
      output_tokens: to_int(output),
      total_tokens: to_int(total)
    }
  end

  def extract_usage(_), do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  defp to_int(v) when is_integer(v), do: v
  defp to_int(_), do: 0
end
