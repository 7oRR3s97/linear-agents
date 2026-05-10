# Testing the Stacking Pipeline Locally

This repo ships two layers of tests for the multi-repo + dependency
stacking pipeline. Use this guide to pick the right one for what you're
verifying.

## Layer 1: plumbing (fast, deterministic)

`test/symphony_elixir/stacking_pipeline_test.exs` covers all the routing,
base-resolution, integration-build, conflict-fallback, cascade, feedback,
and post-deploy-mediation logic against local bare repos and an
in-memory forge stub. No real Linear, no real GitHub.

```bash
mix test test/symphony_elixir/stacking_pipeline_test.exs
```

Run this every time you touch `BaseResolver`, `DispatchGuard`,
`IntegrationBuilder`, `ConflictFallback`, `Reconciler`, `Rebaser`,
`PR.Router`, `Cascade`, or `Feedback.Detector`.

## Layer 2: live Linear + local git (slow, real Linear, deterministic agent)

`test/symphony_elixir/live_stacking_e2e_test.exs` creates a real Linear
project + four issues, provisions local bare/working git repos,
substitutes a deterministic `MockAgent` for the real LLM agent, and
scripts reviewer actions through Linear's real GraphQL API.

### Required env

| Variable | Purpose |
| --- | --- |
| `SYMPHONY_RUN_LIVE_STACKING_E2E=1` | Opt in. Default `mix test` skips the test. |
| `LINEAR_API_KEY` | Linear personal API key. Same one the orchestrator uses. |
| `SYMPHONY_LIVE_LINEAR_TEAM_KEY` (optional) | Default `SYME2E`. Override if your test team uses a different key. |

### Run

```bash
SYMPHONY_RUN_LIVE_STACKING_E2E=1 \
  LINEAR_API_KEY=lin_api_… \
  mix test test/symphony_elixir/live_stacking_e2e_test.exs
```

The test takes ~30–60 seconds. Most of that is sequential Linear API
roundtrips.

### What it creates in your Linear workspace

- One project named `Symphony Stacking E2E <run-id>`.
- Four issues in that project: `…-A`, `…-B`, `…-X`, `…-Y` with stacking
  relationships (`X.blockedBy = [A, B]`, `Y.blockedBy = [A]`).

The test cleans up by moving the project to a `completed`-type status in
its `after` block. Issues stay attached to the project but won't show up
in active-state queries because the project itself is completed.

If the test crashes mid-run, complete the project manually in the Linear
UI to stop it cluttering candidate fetches.

### The manifest

Every artifact the test creates is recorded in
`<tmp_dir>/LIVE_STACKING_E2E_MANIFEST.jsonl`. The path is logged at the
end of the test (Logger.info "manifest path: …"). Each line is one
event:

```jsonl
{"event":"setup","linear":{"team_id":"…","project_id":"…","project_url":"…"},"issues":{…},"repo":{…},"ts":"…"}
{"event":"agent_dispatch","issue":"SYME2E-101","branch":"feat/stacking-a","base":"main","head_sha":"abc1234","pr_number":1042,"ts":"…"}
{"event":"human_merge","issue":"SYME2E-101","branch":"feat/stacking-a","ts":"…"}
…
```

Read it to deduce exactly what the test touched. Useful when:
- Linear has unexpected residue and you want to clean up by hand.
- Debugging a flaky scenario — the manifest shows the order of operations.
- Verifying the test exercised every scenario you cared about.

### Adding scenarios

`MockAgent.dispatch!/4` is the place to add new agent-side behaviors.
`FakeHuman` is the place to add new reviewer actions. Both write to
the manifest when given `manifest_path:` so the audit log stays
complete. New scenarios should append assertions inside the same
`test "..."` function so they share the live Linear project.
