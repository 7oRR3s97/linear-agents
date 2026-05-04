# Self-hosted Langfuse for the linear-agents orchestrator

A local Langfuse stack that captures every Claude Code turn dispatched by
Symphony as a Langfuse trace.

```
linear-agents  ──spawns──▶  claude --print  ──Stop hook──▶  langfuse_hook.py
                                                               │
                                                               ▼
                                                       http://localhost:3100
                                                       (Langfuse self-host)
```

## What's in this directory

- `docker-compose.yml` — official Langfuse self-host compose (postgres,
  clickhouse, redis, minio, langfuse-web, langfuse-worker).
- `docker-compose.override.yml` — host-side port remap (3100 instead of
  the default 3000) so we don't collide with a Next.js dev server.
- `.env.example` — secrets + first-run bootstrap. Copy to `.env` before
  bringing the stack up.

The Stop hook script + installer live under `third_party/langfuse-claudecode/`
(vendored from `douinc/langfuse-claudecode`).

## Pre-requisites

| Tool | Why |
| --- | --- |
| A container runtime (Docker Desktop, OrbStack, Colima, or podman) | To run the compose stack. |
| `uv` (Astral's Python package manager) | The Stop hook is a `uv run`-managed Python script. |
| `claude` CLI authenticated (`claude login`) | The agent runtime. |

Install uv: `curl -LsSf https://astral.sh/uv/install.sh | sh`.

## One-time setup

```sh
cd langfuse
cp .env.example .env
# edit .env: rotate ENCRYPTION_KEY / NEXTAUTH_SECRET / SALT if this isn't a
# pure-localhost dev box, set LANGFUSE_INIT_USER_PASSWORD, set a real
# LANGFUSE_INIT_PROJECT_SECRET_KEY (32 chars).

docker compose up -d
# wait ~60s for clickhouse + langfuse-web to be ready
docker compose logs -f langfuse-web | head -40
```

Open http://localhost:3100 — you should see the Langfuse UI logged in as
the bootstrapped admin user. The `linear-agents` project is already
created (per `LANGFUSE_INIT_PROJECT_*`). Note its public + secret API
keys.

## Install the Claude Code Stop hook

The upstream installer asks for credentials interactively (reads
`/dev/tty`), so on a fresh machine the cleanest path is the manual
sequence below. It mirrors what `install.sh` does:

```sh
mkdir -p ~/.claude/hooks/langfuse-claudecode
cp third_party/langfuse-claudecode/langfuse_hook.py ~/.claude/hooks/langfuse-claudecode/
curl -fsSL https://raw.githubusercontent.com/douinc/langfuse-claudecode/main/pyproject.toml \
  -o ~/.claude/hooks/langfuse-claudecode/pyproject.toml

# Pin langfuse to 3.x — the hook script uses `start_as_current_span`
# which was removed in 4.x.
sed -i '' 's/"langfuse>=3.14.4"/"langfuse>=3.14.4,<4"/' \
  ~/.claude/hooks/langfuse-claudecode/pyproject.toml

(cd ~/.claude/hooks/langfuse-claudecode && uv sync)

# Append to the global Stop hooks array (preserves any existing hooks).
HOOK_CMD="uv run --project ${HOME}/.claude/hooks/langfuse-claudecode ${HOME}/.claude/hooks/langfuse-claudecode/langfuse_hook.py"
cp ~/.claude/settings.json ~/.claude/settings.json.bak
jq --arg cmd "$HOOK_CMD" \
  '.hooks.Stop += [{"hooks":[{"type":"command","command":$cmd}]}]' \
  ~/.claude/settings.json > ~/.claude/settings.json.new \
  && mv ~/.claude/settings.json.new ~/.claude/settings.json
```

The hook runs globally for any `claude` session you launch, but only
sends data when `TRACE_TO_LANGFUSE=true` is set in that session's
environment.

## Wire credentials for Symphony's dispatched agents

Two equivalent paths — pick one.

### Path A — process env (recommended for development)

Symphony's agent runner forwards every env var starting with `LANGFUSE_`
or `TRACE_TO_LANGFUSE` (plus `CC_LANGFUSE_DEBUG`) into each `claude`
subprocess. So launching Symphony with these set in the shell is enough:

```sh
export TRACE_TO_LANGFUSE=true
export LANGFUSE_BASE_URL=http://localhost:3100
export LANGFUSE_PUBLIC_KEY=pk-lf-symphony-local-dev
export LANGFUSE_SECRET_KEY=<from your .env>
export LINEAR_API_KEY=<your linear key>

mise exec -- iex -S mix
```

> The Stop hook depends on Langfuse Python SDK 3.x. The packaged
> `pyproject.toml` already pins `langfuse>=3.14.4,<4`. The 4.x SDK
> changed the span API and breaks the hook — leave the upper bound in
> place until the upstream hook script catches up.

Persist these in `~/.zshrc` (or per-project via direnv) so you don't
re-export every session.

### Path B — committed `.claude/settings.local.json` per workspace

If you'd rather have the credentials follow the cloned workspace, drop a
`.claude/settings.local.json` into the source repo and the `after_create`
hook will carry it forward:

```json
{
  "env": {
    "TRACE_TO_LANGFUSE": "true",
    "LANGFUSE_BASE_URL": "http://host.docker.internal:3000",
    "LANGFUSE_PUBLIC_KEY": "pk-lf-symphony-local-dev",
    "LANGFUSE_SECRET_KEY": "sk-lf-symphony-local-dev-..."
  }
}
```

`.claude/settings.local.json` is in `.gitignore` by Claude Code
convention; never commit it with real secrets. For a multi-machine setup,
distribute the file out-of-band and let `after_create` copy it from a
shared location.

## Smoke test

1. Bring the stack up (`docker compose up -d`).
2. Export the env vars (Path A above).
3. Run `claude --print "say hi" -p` once from any directory. The hook
   should fire.
4. Refresh http://localhost:3100 → `linear-agents` project → Traces. You
   should see one trace.
5. Now create an AFK Linear issue and let Symphony dispatch — every
   dispatched agent's turn shows up as a trace.

## Troubleshooting

### Nothing shows up in Langfuse

- `CC_LANGFUSE_DEBUG=true claude --print "test"` — surfaces hook errors
  on stderr.
- `tail -f ~/.claude/hooks/langfuse-claudecode/langfuse_hook.log`
  (created by the script when debug is on).
- Confirm `TRACE_TO_LANGFUSE=true` is in the subprocess environment:
  `printenv | grep LANGFUSE` from inside an interactive `claude` session.

### Stack won't start

- `docker compose logs langfuse-web | tail -50` — usually clickhouse not
  ready yet; wait and retry.
- Postgres data lives in the `langfuse_postgres_data` named volume.
  `docker compose down -v` wipes everything.

### Health checks

- `curl -fsS http://localhost:3100/api/public/health` → `{"status":"OK"}`
- `curl -fsS http://localhost:3100/api/public/ready` once everything is
  warm.

## Stopping

```sh
docker compose stop          # keep data
docker compose down          # remove containers, keep volumes
docker compose down -v       # wipe everything (destructive)
```
