# Langfuse tracing for the linear-agents orchestrator (optional)

> **Tracing is optional.** Symphony picks up Linear issues, dispatches Claude
> Code, and ships PRs whether Langfuse is running or not. Add this when you
> want to *see* what the agents did — turn-by-turn input/output, every tool
> call, token spend, latency, and a searchable history. If you skip this
> directory entirely, nothing in the agent flow changes.

## Is this for you?

Set up Langfuse if you want any of:

- A timeline of every Claude Code turn dispatched on each Linear issue.
- Per-tool spans (every Read/Edit/Bash/MCP invocation on its own row).
- Token + cost accounting per trace, per session, aggregated across runs.
- The ability to bookmark, tag, score, or annotate runs after the fact.
- A persistent log that survives `iex` restarts and workspace cleanup.

Skip it if:

- You're smoke-testing Symphony for the first time and just want to see one
  PR get opened.
- You're running on a low-resource machine (the stack is ~1.5 GB RAM
  steady-state across 6 containers).
- You already pipe `claude` output to your own observability tooling.

## What you get when it's wired

```
Linear issue picked up
        │
        ▼
 Symphony dispatches `claude --print …`
        │
        ▼
 Claude Code runs autonomously, calls tools
        │
        ▼ (Stop hook fires after the response)
 langfuse_hook.py reads the JSONL transcript
        │
        ▼
 ─────────────────────────────────────────
 Langfuse trace = one issue's turn
   ├─ generation span: assistant message + tokens + cost
   └─ tool spans:    every Read/Edit/Bash/MCP call
 ─────────────────────────────────────────
        │
        ▼
http://localhost:3100/project/linear-agents/traces
```

---

## Prerequisites

| Tool | Why | Install |
| --- | --- | --- |
| Container runtime (Docker Desktop / **Colima** / OrbStack / podman) | Hosts the Langfuse stack. | Colima recommended on macOS: `brew install colima docker docker-compose && colima start --cpu 4 --memory 8` |
| `uv` (Astral's Python package manager) | The Stop hook is a `uv run`-managed Python script. | `brew install uv` |
| `claude` CLI authenticated | The agent runtime. Runs whether tracing is on or off. | `claude login` (via the Claude Code app or CLI) |
| `jq` | One-liner that merges the hook into `~/.claude/settings.json`. | `brew install jq` |

---

## Setup runbook

A clean install end to end. Run from the repo root.

### 1. Pick a port for the Langfuse UI

The committed override remaps the host port to `3100` because `:3000` is
commonly taken by other dev servers. If `3100` is also occupied on your
machine, edit `langfuse/docker-compose.override.yml` and `langfuse/.env`
to a free port (and remember to keep `NEXTAUTH_URL` consistent).

### 2. Configure secrets

```sh
cd langfuse
cp .env.example .env
$EDITOR .env
```

You **must** change at least these two lines before bringing the stack
up — they default to placeholders by design:

```env
LANGFUSE_INIT_USER_PASSWORD=CHANGE-ME-strong-passphrase
LANGFUSE_INIT_PROJECT_SECRET_KEY=sk-lf-symphony-local-dev-CHANGE-ME
```

Pick a real password (you'll log into the Langfuse UI with this) and a
real secret key (this is what your agents authenticate with — treat it
like an API key, ~32 chars random is fine).

If this stack will ever be exposed beyond `localhost`, also rotate
`ENCRYPTION_KEY`, `NEXTAUTH_SECRET`, and `SALT`. Commands at the top of
`.env.example`.

### 3. Bring the stack up

```sh
docker compose up -d
docker compose logs -f langfuse-web | head -40   # ~30–60s for the migrations + first boot
```

When the UI loads at http://localhost:3100, log in with the
`LANGFUSE_INIT_USER_EMAIL` + `LANGFUSE_INIT_USER_PASSWORD` you set. The
`linear-agents` project is already created for you.

### 4. Install the Claude Code Stop hook

The hook is what actually sends data to Langfuse. It runs after every
`claude` turn (interactive or `--print`) and reads the transcript file
Claude Code writes.

```sh
# from the linear-agents repo root
mkdir -p ~/.claude/hooks/langfuse-claudecode
cp third_party/langfuse-claudecode/langfuse_hook.py ~/.claude/hooks/langfuse-claudecode/
curl -fsSL https://raw.githubusercontent.com/douinc/langfuse-claudecode/main/pyproject.toml \
  -o ~/.claude/hooks/langfuse-claudecode/pyproject.toml

# Pin Langfuse SDK to 3.x — the hook calls `start_as_current_span`,
# which 4.x removed. Without this pin the hook errors silently.
sed -i '' 's/"langfuse>=3.14.4"/"langfuse>=3.14.4,<4"/' \
  ~/.claude/hooks/langfuse-claudecode/pyproject.toml

(cd ~/.claude/hooks/langfuse-claudecode && uv sync)

# Append to the global Stop hooks array (preserves any existing hooks).
HOOK_CMD="uv run --project ${HOME}/.claude/hooks/langfuse-claudecode ${HOME}/.claude/hooks/langfuse-claudecode/langfuse_hook.py"
cp ~/.claude/settings.json ~/.claude/settings.json.bak.$(date +%s)
jq --arg cmd "$HOOK_CMD" \
  '.hooks.Stop += [{"hooks":[{"type":"command","command":$cmd}]}]' \
  ~/.claude/settings.json > ~/.claude/settings.json.new \
  && mv ~/.claude/settings.json.new ~/.claude/settings.json
```

The hook is now registered for **every** `claude` session you launch
(globally), but it stays dormant unless `TRACE_TO_LANGFUSE=true` is set
in that session's environment. So installing the hook costs nothing
when tracing is off.

### 5. Wire credentials so Symphony's dispatched agents trace

Symphony's runner forwards five env vars into every `claude` subprocess:

- `TRACE_TO_LANGFUSE`
- `LANGFUSE_BASE_URL`
- `LANGFUSE_PUBLIC_KEY`
- `LANGFUSE_SECRET_KEY`
- `CC_LANGFUSE_DEBUG` (optional)

Export them in the shell where you launch `iex -S mix`:

```sh
export TRACE_TO_LANGFUSE=true
export LANGFUSE_BASE_URL=http://localhost:3100
export LANGFUSE_PUBLIC_KEY=pk-lf-symphony-local-dev
export LANGFUSE_SECRET_KEY=<the value you set in .env>
export LINEAR_API_KEY=<your linear personal API key>

mise exec -- iex -S mix
```

Persist them in `~/.zshrc`, a `.envrc` (direnv), or a launcher script —
whatever fits your shell habits.

### 6. Verify with a smoke test

```sh
cd /tmp && rm -rf lf-smoke && mkdir lf-smoke && cd lf-smoke
env TRACE_TO_LANGFUSE=true \
    LANGFUSE_BASE_URL=http://localhost:3100 \
    LANGFUSE_PUBLIC_KEY=pk-lf-symphony-local-dev \
    LANGFUSE_SECRET_KEY=<from .env> \
  claude --print "say 'tracing live' and stop"
```

Then refresh http://localhost:3100/project/linear-agents/traces — you
should see one trace named `Claude Code - Turn 1` with two
observations.

If nothing shows up, see [Troubleshooting](#troubleshooting).

---

## Turning tracing off

Three ways, pick whichever:

- **Don't set `TRACE_TO_LANGFUSE`** in the shell → the hook fires but
  exits immediately when it sees the var is unset. Free, no
  side-effects.
- **Stop the stack** (`docker compose stop` from `langfuse/`) → the hook
  fires, tries to send, fails silently. Slightly wasteful but harmless.
- **Remove the global hook entry** from `~/.claude/settings.json` →
  rolls back step 4 entirely.

Symphony's agent flow is unaffected by any of these. The orchestrator
never reads tracing state; the runner just forwards env vars.

---

## Troubleshooting

### Nothing shows up in Langfuse

```sh
# Tail the hook log:
tail -f ~/.claude/state/langfuse_hook.log

# Or run a one-shot with debug:
env TRACE_TO_LANGFUSE=true \
    LANGFUSE_BASE_URL=http://localhost:3100 \
    LANGFUSE_PUBLIC_KEY=pk-lf-symphony-local-dev \
    LANGFUSE_SECRET_KEY=<...> \
    CC_LANGFUSE_DEBUG=true \
  claude --print "test"
```

The most common failure modes:

- **Hook log says `start_as_current_span` is not an attribute** → you
  ended up on Langfuse SDK 4.x. Re-pin and re-sync (step 4 above).
- **Hook log empty** → `TRACE_TO_LANGFUSE` isn't set in the subprocess.
  Inside Symphony, this means the env var didn't reach the BEAM that
  spawned the worker; export it before `iex -S mix`.
- **Hook log shows auth error** → key mismatch between `.env` and
  exported env vars. Compare them.

### Stack won't start

```sh
docker compose logs langfuse-web | tail -50
```

Usually clickhouse or postgres needs a few more seconds; just wait and
retry. If the web container keeps restarting, check `docker compose ps`
for unhealthy services and inspect their logs.

### Port collision

```sh
lsof -nP -iTCP:3100 -sTCP:LISTEN
```

If something else owns the port, edit
`langfuse/docker-compose.override.yml` and `langfuse/.env` to a free one
(e.g., 3333, 4040). Restart with `docker compose up -d`.

### `~/.claude/settings.json` got mangled

A backup was written to `~/.claude/settings.json.bak.<timestamp>` by step
4. Restore: `cp ~/.claude/settings.json.bak.<ts> ~/.claude/settings.json`.

---

## Stopping and wiping

```sh
docker compose stop          # stop containers, keep data
docker compose down          # remove containers, keep volumes
docker compose down -v       # destructive: wipes Postgres + Clickhouse + Minio
```

Volumes that hold your data: `langfuse_postgres_data`,
`langfuse_clickhouse_data`, `langfuse_minio_data`. They survive
`stop`/`down` and only disappear with `down -v`.

---

## Files in this directory

- `docker-compose.yml` — official Langfuse self-host compose (postgres,
  clickhouse, redis, minio, langfuse-web, langfuse-worker).
- `docker-compose.override.yml` — host port remap to **3100**. Edit if
  you need a different port; commit a different override per machine.
- `.env.example` — secrets template + first-run bootstrap (org, project,
  admin user, API keys). Copy to `.env` (gitignored) before bringing the
  stack up.
- `.gitignore` — keeps `.env` and any logs out of version control.

The Stop-hook script and installer are vendored under
`../third_party/langfuse-claudecode/` (mirror of
`douinc/langfuse-claudecode`).
