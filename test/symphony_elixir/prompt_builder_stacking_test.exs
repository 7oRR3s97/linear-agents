defmodule SymphonyElixir.PromptBuilderStackingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PromptBuilder

  test "renders new stacking template variables" do
    template = """
    repo={{ repo }}
    base={{ base_branch }}
    pr_base={{ pr_base_branch }}
    blockers={% for b in blocker_branches %}{{ b }};{% endfor %}
    """

    write_workflow_file!(Workflow.workflow_file_path(), prompt: template)

    issue = %Issue{identifier: "PES-1", title: "x", state: "Todo"}

    prompt =
      PromptBuilder.build_prompt(issue,
        repo: "web",
        base_branch: "feat/A",
        pr_base_branch: "feat/A",
        blocker_branches: ["feat/A", "feat/B"]
      )

    assert prompt =~ "repo=web"
    assert prompt =~ "base=feat/A"
    assert prompt =~ "pr_base=feat/A"
    assert prompt =~ "blockers=feat/A;feat/B;"
  end

  test "integration_conflict renders as nil-equivalent on happy path" do
    template = "{% if integration_conflict %}CONFLICT{% else %}CLEAN{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: template)

    issue = %Issue{identifier: "PES-1", title: "x", state: "Todo"}

    assert PromptBuilder.build_prompt(issue) =~ "CLEAN"
  end

  test "integration_conflict renders structured context when populated" do
    template = """
    {% if integration_conflict %}files={{ integration_conflict.files | join: ',' }}{% endif %}
    """

    write_workflow_file!(Workflow.workflow_file_path(), prompt: template)

    issue = %Issue{identifier: "PES-1", title: "x", state: "Todo"}

    prompt =
      PromptBuilder.build_prompt(issue,
        integration_conflict: %{files: ["a.ex", "b.ex"], blocker_shas: ["abc123", "def456"]}
      )

    assert prompt =~ "files=a.ex,b.ex"
  end

  test "strict variable checking still catches typos" do
    template = "{{ basebranch }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: template)

    issue = %Issue{identifier: "PES-1", title: "x", state: "Todo"}

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue, base_branch: "main")
    end
  end

  test "stacking-disabled template still renders without the new vars" do
    template = "issue={{ issue.identifier }}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: template)

    issue = %Issue{identifier: "PES-1", title: "x", state: "Todo"}

    assert PromptBuilder.build_prompt(issue) =~ "issue=PES-1"
  end
end
