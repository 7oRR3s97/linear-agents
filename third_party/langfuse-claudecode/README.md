# langfuse-claudecode

Langfuse tracing hook for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Automatically sends conversation traces to [Langfuse](https://langfuse.com) for observability.

[Link to the official Langfuse docs for Claude Code integration](https://langfuse.com/integrations/other/claude-code)

## What it does

This hook runs after every Claude Code assistant turn and:

- Reads the conversation transcript incrementally
- Builds structured traces with spans, LLM generations, and tool observations
- Sends them to Langfuse with session grouping, user attribution, and host metadata
- Fails open: if Langfuse is unreachable, Claude Code continues normally

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/douinc/langfuse-claudecode/main/install.sh | bash
```

Run from your **project root** (where `.claude/` lives or will be created).

The installer will:

1. Check that `uv` is installed
2. Download the hook to `~/.claude/hooks/langfuse-claudecode/` (global, shared across projects)
3. Install dependencies into an isolated `.venv` inside that directory
4. Register the Stop hook in `~/.claude/settings.json` (user-wide)
5. Prompt for your Langfuse credentials
6. Save credentials in `.claude/settings.local.json` (per-project, gitignored)

### Per-project setup

Once the hook is installed globally, add tracing to additional projects with:

```bash
curl -fsSL https://raw.githubusercontent.com/douinc/langfuse-claudecode/main/install.sh | bash -s -- --setup
```

The `--setup` flag skips the global hook installation and only prompts for project-level credentials.

### Non-interactive install

Pre-set environment variables to skip prompts:

The `CC_LANGFUSE_ENVIRONMENT` should not start with `langfuse`.

Check more from [the official Langfuse docs](https://langfuse.com/docs/observability/features/environments)

```bash
LANGFUSE_PUBLIC_KEY=pk-lf-... \
LANGFUSE_SECRET_KEY=sk-lf-... \
LANGFUSE_BASE_URL=https://cloud.langfuse.com \
CC_LANGFUSE_USER_ID=you@example.com \
CC_LANGFUSE_ENVIRONMENT=my-project \
  curl -fsSL https://raw.githubusercontent.com/douinc/langfuse-claudecode/main/install.sh | bash
```

## Prerequisites

- [uv](https://docs.astral.sh/uv/) -- the Python package manager
- A [Langfuse](https://langfuse.com) account (cloud or self-hosted)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)

## Manual installation

### 1. Download the hook

```bash
mkdir -p ~/.claude/hooks/langfuse-claudecode
curl -fsSL https://raw.githubusercontent.com/douinc/langfuse-claudecode/main/langfuse_hook.py \
  > ~/.claude/hooks/langfuse-claudecode/langfuse_hook.py
curl -fsSL https://raw.githubusercontent.com/douinc/langfuse-claudecode/main/pyproject.toml \
  > ~/.claude/hooks/langfuse-claudecode/pyproject.toml
curl -fsSL https://raw.githubusercontent.com/douinc/langfuse-claudecode/main/uv.lock \
  > ~/.claude/hooks/langfuse-claudecode/uv.lock
chmod +x ~/.claude/hooks/langfuse-claudecode/langfuse_hook.py
uv sync --project ~/.claude/hooks/langfuse-claudecode/ --python 3.13
```

### 2. Register the hook

Add to `~/.claude/settings.json` (create if it doesn't exist):

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "uv run --project ~/.claude/hooks/langfuse-claudecode/ ~/.claude/hooks/langfuse-claudecode/langfuse_hook.py"
          }
        ]
      }
    ]
  }
}
```

### 3. Configure credentials

Create `.claude/settings.local.json` in your project root:

```json
{
  "env": {
    "TRACE_TO_LANGFUSE": "true",
    "LANGFUSE_PUBLIC_KEY": "pk-lf-...",
    "LANGFUSE_SECRET_KEY": "sk-lf-...",
    "LANGFUSE_BASE_URL": "https://cloud.langfuse.com",
    "CC_LANGFUSE_USER_ID": "you@example.com",
    "CC_LANGFUSE_ENVIRONMENT": "my-project"
  }
}
```

### 4. Gitignore secrets

Add to `.gitignore`:

```
.claude/settings.local.json
```

## Configuration

### Required

| Variable | Description |
|---|---|
| `TRACE_TO_LANGFUSE` | Set to `"true"` to enable tracing |
| `LANGFUSE_PUBLIC_KEY` | Langfuse project public key |
| `LANGFUSE_SECRET_KEY` | Langfuse project secret key |

### Optional

| Variable | Default | Description |
|---|---|---|
| `LANGFUSE_BASE_URL` | `https://cloud.langfuse.com` | Langfuse host URL |
| `CC_LANGFUSE_USER_ID` | -- | User ID for traces (e.g. email) |
| `CC_LANGFUSE_ENVIRONMENT` | -- | Environment name (lowercase, max 40 chars) |
| `CC_LANGFUSE_DEBUG` | `false` | Enable verbose debug logging |
| `CC_LANGFUSE_MAX_CHARS` | `20000` | Max characters before truncation |

## Trace structure

Each Claude Code turn produces a trace with:

- **Span**: `Claude Code - Turn N` with user input and assistant output
- **Generation**: The LLM call with model name
- **Tool observations**: Each tool call (Bash, Read, Edit, etc.) with inputs and outputs

### Metadata

| Key | Description |
|---|---|
| `source` | Always `"claude-code"` |
| `session_id` | Claude Code session UUID |
| `turn_number` | Sequential turn number |
| `transcript_path` | Local path to JSONL transcript |
| `host_ip` | Public IP of the machine |
| `host_name` | OS hostname |
| `host_cwd` | Working directory |

## How it works

The hook is installed globally in `~/.claude/hooks/langfuse-claudecode/` with its own `pyproject.toml` and pre-synced `.venv`. This isolates langfuse's dependencies from your project's Python environment, preventing dependency conflicts.

When Claude Code triggers the Stop hook, it runs `uv run --project ~/.claude/hooks/langfuse-claudecode/ langfuse_hook.py`, which uses the isolated environment regardless of your project's Python setup.

State is persisted in `~/.claude/state/` to support incremental transcript reading across turns within a session.

## Troubleshooting

| Issue | Fix |
|---|---|
| No traces appearing | Check `TRACE_TO_LANGFUSE` is `"true"` and keys are correct |
| Hook errors | `tail -f ~/.claude/state/langfuse_hook.log` |
| Need more detail | Set `CC_LANGFUSE_DEBUG` to `"true"` in settings.local.json |
| Test hook manually | `echo '{}' \| uv run --project ~/.claude/hooks/langfuse-claudecode/ ~/.claude/hooks/langfuse-claudecode/langfuse_hook.py` |
| Dependency conflicts | The global install isolates dependencies; if issues persist, re-run the installer |

## License

MIT
