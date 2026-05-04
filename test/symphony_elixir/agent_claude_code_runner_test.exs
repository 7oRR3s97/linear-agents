defmodule SymphonyElixir.Agent.ClaudeCode.RunnerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Agent.ClaudeCode.Runner

  @moduletag :tmp_dir

  describe "run_turn/3 with a stub claude binary" do
    test "captures stdout on success", %{tmp_dir: tmp} do
      stub = install_stub!(tmp, """
      #!/bin/sh
      echo "Hello from stub claude"
      exit 0
      """)

      session = %{
        workspace: tmp,
        issue_id: "id-1",
        settings: %{
          command: stub,
          permission_mode: "bypassPermissions",
          extra_args: []
        }
      }

      assert {:ok, %{stdout: output}} = Runner.run_turn(session, "do work")
      assert output =~ "Hello from stub claude"
    end

    test "non-zero exit returns {:error, {:claude_failed, ...}}", %{tmp_dir: tmp} do
      stub = install_stub!(tmp, """
      #!/bin/sh
      echo "boom" >&2
      exit 7
      """)

      session = %{
        workspace: tmp,
        issue_id: "id-1",
        settings: %{
          command: stub,
          permission_mode: "bypassPermissions",
          extra_args: []
        }
      }

      assert {:error, {:claude_failed, 7, _output}} = Runner.run_turn(session, "do work")
    end

    test "passes extra_args before the prompt", %{tmp_dir: tmp} do
      stub = install_stub!(tmp, """
      #!/bin/sh
      echo "$@"
      """)

      session = %{
        workspace: tmp,
        issue_id: "id-1",
        settings: %{
          command: stub,
          permission_mode: "bypassPermissions",
          extra_args: ["--verbose"]
        }
      }

      assert {:ok, %{stdout: output}} = Runner.run_turn(session, "say hi")

      assert output =~ "--print"
      assert output =~ "--permission-mode"
      assert output =~ "bypassPermissions"
      assert output =~ "--verbose"
      assert output =~ "say hi"
    end

    test "forwards LANGFUSE_* env vars to the subprocess", %{tmp_dir: tmp} do
      stub = install_stub!(tmp, """
      #!/bin/sh
      env | grep -E "^(TRACE_TO_LANGFUSE|LANGFUSE_PUBLIC_KEY|LANGFUSE_BASE_URL|CC_LANGFUSE_DEBUG)="
      """)

      System.put_env("TRACE_TO_LANGFUSE", "true")
      System.put_env("LANGFUSE_PUBLIC_KEY", "pk-test")
      System.put_env("LANGFUSE_BASE_URL", "http://localhost:3000")

      on_exit(fn ->
        System.delete_env("TRACE_TO_LANGFUSE")
        System.delete_env("LANGFUSE_PUBLIC_KEY")
        System.delete_env("LANGFUSE_BASE_URL")
      end)

      session = %{
        workspace: tmp,
        issue_id: "id-1",
        settings: %{
          command: stub,
          permission_mode: "bypassPermissions",
          extra_args: []
        }
      }

      assert {:ok, %{stdout: output}} = Runner.run_turn(session, "go")

      assert output =~ "TRACE_TO_LANGFUSE=true"
      assert output =~ "LANGFUSE_PUBLIC_KEY=pk-test"
      assert output =~ "LANGFUSE_BASE_URL=http://localhost:3000"
    end

    test "calls on_message with the captured assistant output", %{tmp_dir: tmp} do
      stub = install_stub!(tmp, """
      #!/bin/sh
      echo "agent output"
      exit 0
      """)

      session = %{
        workspace: tmp,
        issue_id: "id-1",
        settings: %{
          command: stub,
          permission_mode: "bypassPermissions",
          extra_args: []
        }
      }

      parent = self()
      on_message = fn msg -> send(parent, msg) end

      Runner.run_turn(session, "go", on_message: on_message)

      assert_received {:assistant_output, body}
      assert body =~ "agent output"
    end
  end

  defp install_stub!(tmp, script) do
    path = Path.join(tmp, "claude-stub")
    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end
end
