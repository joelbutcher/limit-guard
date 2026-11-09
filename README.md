# limit-guard

A small, deterministic supervisor for local Claude Code agents. It watches Claude plan usage
(5-hour and 7-day windows), tells running agents to checkpoint and stop **before** a limit is hit,
waits for the reset, then resumes every agent it paused.

It is bash + jq + curl, a launchd daemon and Claude Code hooks. It is **not** a Claude session,
so supervising costs no quota.

```
limit-guard status          # usage, state, daemon, tracked sessions
limit-guard pause / resume  # manual control
limit-guard log -f          # what it decided and why
```

## How it works

```
 statusline ──► samples/statusline.json ─┐
 claude -p … | limit-guard ingest-stream ─┤   daemon (launchd, adaptive heartbeat)
   ──► samples/stream.json ───────────────┼─► usage.json ─► decide ─► state.json (running|paused)
 GET /api/oauth/usage (≤1 per heartbeat) ─┤                              │
 transcript estimate (low confidence) ────┘                              ▼
                                                    hooks read state.json on every event
```

**Usage sources**, best first. Every source is normalised to `{pct, resets_at(epoch)}` per window.
`resets_at` arrives as epoch seconds, epoch milliseconds or ISO 8601, and all three are handled.

1. **Statusline** `rate_limits.five_hour/seven_day`. limit-guard installs itself as the
   statusline and chains to your previous one if you had one. Each refresh records a sample at no cost.
2. **Headless stream events.** Pipe `claude -p --output-format stream-json --verbose` through
   `limit-guard ingest-stream`; it passes output through unchanged and records `rate_limit_event` usage.
3. **`GET https://api.anthropic.com/api/oauth/usage`**, the endpoint behind `/usage`. This endpoint
   is undocumented, so treat it as best-effort. It is called only when no fresh sample exists, at most
   once per `LG_API_MIN_INTERVAL`, and it backs off for 10 minutes after a 429. The OAuth token is
   read from the Keychain (`Claude Code-credentials`), or from `~/.claude/.credentials.json`, at call
   time and goes to curl on stdin. It is never in argv, never logged and never persisted.
   An **expired token is never refreshed** by limit-guard, because refreshing would rotate it under
   your agents. limit-guard falls back to its other sources instead.
4. **Transcript estimate.** Weighted token counts from `~/.claude/projects/**/*.jsonl`,
   de-duplicated by message id. limit-guard calibrates tokens-per-percent automatically from
   high-confidence readings, and only uses this once a calibration exists. It is flagged
   `confidence: low`.

**Decision.** limit-guard pauses when 5h ≥ `LG_PAUSE_5H` (default 90) or 7d ≥ `LG_PAUSE_7D` (default 95).
`resume_at` is the latest reset among the tripped windows plus `LG_RESUME_GRACE`. After that time,
fresh data that still shows a tripped window with a future reset extends the pause. Otherwise the
clock is trusted (the window has rolled over) and every paused agent is resumed. A manual
`limit-guard pause` never auto-resumes.

**Heartbeat.** The interval shrinks as usage nears a threshold: 15 min when far away, then 10, 5
and 2 min, and 1 min within 8 points. Low-confidence data caps it at 2 min. While paused, the
daemon sleeps until the reset. A statusline or stream sample that crosses a threshold wakes the
daemon immediately.

**Hooks** (user `~/.claude/settings.json`; all are no-ops while running):

| Event | While paused |
| --- | --- |
| `PreToolUse` | Denies with a `permissionDecisionReason` telling the agent to write a checkpoint to `~/.claude/limit-guard/checkpoints/<session>.md` and end its turn. Writing that file (and `TodoWrite`) is allowed. |
| `Stop` | An agent that was told to checkpoint is now `paused`. An agent that simply finished its turn is not resumed later. |
| `UserPromptSubmit` | Blocks new prompts and saves them. The saved prompt is delivered on resume. |
| `SessionStart` | Registers the session (pid, argv, kind, tmux pane) and injects a "paused" note. |
| `SessionEnd` | Headless agents exit after pausing but stay resumable. |

Any hook failure exits 0 with no output, so a limit-guard bug can never block your agents.
`LIMIT_GUARD_DISABLE=1 claude …` runs a session unguarded.

**Resume**, by session kind:

- **tmux**: types `[limit-guard:resume] … read your checkpoint …` into the pane and presses Enter.
  If Claude has exited, runs `claude --resume <id> "<prompt>"` in the pane's shell.
- **headless** (`claude -p`): once the old process is gone, runs
  `claude -p --resume <id> <flags> "<prompt>"` detached in the session's cwd, logging to
  `~/.claude/limit-guard/logs/<id>.resume.log`. Re-used flags are `--model`, `--permission-mode`,
  `--max-turns`, `--effort`, `--output-format`, `--fallback-model`, `--add-dir`, `--verbose` and
  `--dangerously-skip-permissions`. A session blocked before its first turn is re-run fresh with
  its saved prompt.
- **desktop app / plain terminal**: limit-guard can pause these but cannot type into them. It
  sends a macOS notification naming them so you can continue them by hand.

## Install

```bash
~/Projects/limit-guard/bin/limit-guard install   # symlink, config, hooks, statusline, launchd
limit-guard uninstall                            # reverses it (state kept)
```

- CLI: `~/.local/bin/limit-guard` (symlink)
- State, config, logs: `~/.claude/limit-guard/` (`config.env`, `state.json`, `usage.json`,
  `sessions/`, `checkpoints/`, `limit-guard.log`)
- Daemon: `~/Library/LaunchAgents/com.limit-guard.daemon.plist` (`KeepAlive`, `RunAtLoad`)
- `settings.json` is backed up as `settings.json.bak-limit-guard-<timestamp>` on every change.

## Tests

```bash
tests/run.sh            # all
tests/run.sh decide     # filter by name
```

The tests run offline. `security`, `curl`, `tmux`, `claude` and `osascript` are PATH stubs, and the
clock is fixed via `LG_NOW`.

## Known limits

- `/api/oauth/usage` is undocumented and may change. limit-guard degrades to the statusline,
  stream and estimate sources.
- Headless resume re-uses only whitelisted flags. The original command line is read from `ps`,
  which loses quoting, so wrap complex invocations in a script if you need more.
- A turn that produces no tool calls cannot be interrupted; it finishes, then is held at its next prompt.
