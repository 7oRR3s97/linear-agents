defmodule SymphonyElixir.Agent.ClaudeCodeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Agent.ClaudeCode

  describe "parse_event/1" do
    test "session start" do
      line = ~s({"type":"system","subtype":"init","session_id":"abc-123"})
      assert {:event, :session_started, %{"session_id" => "abc-123"}} = ClaudeCode.parse_event(line)
    end

    test "assistant message" do
      line = ~s({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}})
      assert {:event, :assistant_message, %{"type" => "assistant"}} = ClaudeCode.parse_event(line)
    end

    test "tool_result inside user message" do
      line =
        ~s({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}})

      assert {:event, :tool_result, _} = ClaudeCode.parse_event(line)
    end

    test "non-tool_result user message classifies as other" do
      line =
        ~s({"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}})

      assert {:event, :other_message, _} = ClaudeCode.parse_event(line)
    end

    test "successful result with usage" do
      line =
        ~s({"type":"result","subtype":"success","usage":{"input_tokens":42,"output_tokens":17,"total_tokens":59},"result":"done"})

      assert {:event, :turn_completed, decoded} = ClaudeCode.parse_event(line)

      assert ClaudeCode.extract_usage(decoded) ==
               %{input_tokens: 42, output_tokens: 17, total_tokens: 59}
    end

    test "error result classifies as turn_failed" do
      line = ~s({"type":"result","subtype":"error_max_turns","is_error":true})
      assert {:event, :turn_failed, _} = ClaudeCode.parse_event(line)
    end

    test "malformed json reports the raw line" do
      assert {:malformed, "not json"} = ClaudeCode.parse_event("not json")
    end

    test "empty line is benign" do
      assert {:event, :other_message, %{}} = ClaudeCode.parse_event("")
    end
  end

  describe "build_user_message/2" do
    test "encodes text into the expected stream-json shape" do
      json = ClaudeCode.build_user_message("hello world")
      decoded = Jason.decode!(json)

      assert decoded == %{
               "type" => "user",
               "message" => %{
                 "role" => "user",
                 "content" => [%{"type" => "text", "text" => "hello world"}]
               }
             }
    end

    test "includes session_id when provided" do
      json = ClaudeCode.build_user_message("hi", session_id: "session-7")
      decoded = Jason.decode!(json)
      assert decoded["session_id"] == "session-7"
    end
  end

  describe "spawn_args/2" do
    test "returns the expected argv with default permission_mode" do
      args = ClaudeCode.spawn_args(%{}, session_id: "s-1")
      assert "--print" in args
      assert "stream-json" in args
      assert "--session-id" in args
      assert "s-1" in args
      assert Enum.member?(args, "bypassPermissions")
    end

    test "honors a custom permission_mode and extra_args" do
      args = ClaudeCode.spawn_args(%{permission_mode: "acceptEdits", extra_args: ["--debug"]},
               session_id: "s-2"
             )

      assert "acceptEdits" in args
      assert "--debug" in args
    end
  end

  describe "extract_usage/1" do
    test "missing usage returns zeros" do
      assert ClaudeCode.extract_usage(%{}) == %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
    end

    test "computes total when only input/output provided" do
      assert ClaudeCode.extract_usage(%{"usage" => %{"input_tokens" => 10, "output_tokens" => 5}}) ==
               %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
    end
  end
end
