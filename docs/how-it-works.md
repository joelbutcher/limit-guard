# How it works

```text
 statusline ───────────────► samples/statusline.json ─┐
 claude -p … | limit-guard ingest-stream ─► samples/ ──┤   daemon (launchd, adaptive heartbeat)
 GET /api/oauth/usage (at most once per heartbeat) ────┼─► usage.json ─► decide ─► state.json
 transcript estimate (low confidence) ─────────────────┘                             │
                                                                                      ▼
                                              Claude Code hooks read state.json on every event
```

There are three parts:

- a **daemon** (a launchd agent) that reads usage and decides whether to pause or resume;
- **hooks** in your user `~/.claude/settings.json` that act on that decision inside each session;
- **resumers** that restart paused agents after the reset.

## Reading usage

Each source is turned into the same record, per window: `{pct, resets_at}`. Reset times arrive as
epoch seconds, epoch milliseconds or ISO 8601, and all three are handled. Sources, best first:

1. **The statusline.** Claude Code passes `rate_limits.five_hour` and `rate_limits.seven_day` to
   the statusline command. limit-guard installs itself as the statusline (running your previous one
   too, if you had one) and records each update for free.
2. **Headless stream events.** `claude -p --output-format stream-json --verbose` emits
   `rate_limit_event` messages. Pipe the output through `limit-guard ingest-stream` to record them;
   the output passes through unchanged.
3. **The usage endpoint** behind Claude Code's `/usage`,
   `GET https://api.anthropic.com/api/oauth/usage`. This is undocumented, so limit-guard treats it as
   best-effort. It is called only when no sample from 1 or 2 is fresher than `LG_SAMPLE_MAX_AGE`,
   at most once per `LG_API_MIN_INTERVAL`, and backs off for 10 minutes after a `429`.
4. **A transcript estimate.** This is a weighted token count from `~/.claude/projects/**/*.jsonl`,
   de-duplicated by message id. limit-guard learns the conversion from tokens to percent from its
   high-confidence readings, and only estimates once it has learned it. Estimates are marked
   `confidence: low` and make the daemon check more often.

Desktop-app sessions don't run a statusline. If all your agents are in the desktop app, usage
comes from the endpoint, which is why `limit-guard status` usually shows `source=api`.

## Deciding

- **Pause** when the 5-hour window reaches `LG_PAUSE_5H` or the 7-day window reaches `LG_PAUSE_7D`
  (both default to 95%). The pause lasts until the latest reset among the tripped windows, plus
  `LG_RESUME_GRACE` (2 minutes).
- **Resume** at that time. If fresh data then still shows a tripped window with a later reset, the
  pause is extended instead. Otherwise the clock is trusted, since the window has rolled over.
- **Manual pauses** (`limit-guard pause`) never resume on their own.

**Heartbeat.** The daemon checks less often when usage is far from a threshold:

| Gap to the threshold | Check every |
| --- | --- |
| 40 points or more | 15 min |
| 25–39 | 10 min |
| 15–24 | 5 min |
| 8–14 | 2 min |
| under 8 | 1 min |

Low-confidence (estimated) data caps the interval at 2 minutes. While paused, the daemon sleeps until
the reset. A statusline or stream sample that crosses a threshold wakes the daemon immediately.

## Hooks

All hooks do nothing while limit-guard is running, apart from keeping track of sessions.

| Event | While paused | After the reset |
| --- | --- | --- |
| `SessionStart` | Registers the session and tells the agent work is paused. | Registers the session: its process, command line, kind (desktop, background, tmux, headless or terminal) and tmux pane. |
| `PreToolUse` | Denies the call. The reason tells the agent to write a checkpoint to `~/.claude/limit-guard/checkpoints/<session>.md` and end its turn. Writing that file, and todo-list tools, stay allowed. | — |
| `Stop` | An agent that was told to checkpoint is now **paused**. An agent that just finished its turn is left alone; it has nothing to resume. | — |
| `UserPromptSubmit` | Blocks the prompt and saves it. | On the first prompt you type into a paused session, adds the checkpoint path and any saved prompt as context. |
| `SessionEnd` | Headless agents exit after pausing, and stay resumable. | — |

If a hook fails for any reason, it exits 0 with no output, so a limit-guard bug can't block your agents.

Agents are told what will happen next. Agents that will be resumed automatically are told that.
Agents in the desktop app or a plain terminal are told that you will continue them.

## Resuming, by kind of session

**Background (`claude --bg`).** When a background agent stops, it stays alive, idle at its prompt.
After the reset, limit-guard runs `claude stop <id>` and waits for the process to exit. Then it runs
`claude --bg --resume <id> "<resume prompt>"` in the session's folder. The background service
restores the session's own saved settings (model, name, settings files, permission mode), and
limit-guard adds none. An agent that is still in its turn is never stopped; it's tried again on the
next heartbeat.

**tmux.** If Claude is still running in the pane, limit-guard types the resume prompt and presses
Enter. If the pane is back at a shell prompt, it runs `claude --resume <id> "<resume prompt>"` there.

**Headless (`claude -p`).** Once the old process has exited, limit-guard runs
`claude -p --resume <id> "<resume prompt>"` detached, in the session's folder, logging to
`~/.claude/limit-guard/logs/<id>.resume.log`. A session that was blocked before its first turn is
re-run fresh with its saved prompt. Only harmless flags are carried over from the original command
line: `--model`, `--fallback-model`, `--effort`, `--output-format`, `--max-turns` and `--verbose`,
each with a strictly checked value. **Permission flags are never carried over**, because `ps` loses
quoting and text inside a prompt could look like a flag. To resume headless agents with permission
flags, list them in `LG_HEADLESS_RESUME_FLAGS`.

**Claude desktop app and plain terminal tabs.** limit-guard can pause these, but nothing outside
them can type into them: the desktop app's session controls are only available inside the app. You
get a notification naming them. Send any message and the agent is handed its checkpoint.

The resume prompt always starts with `[limit-guard:resume]`. It points the agent at its checkpoint,
or tells it to re-check the current state if there isn't one, and includes any prompt you sent
while it was paused.

## Privacy and security

- **Everything stays on your Mac.** The only network call limit-guard makes is the usage request to
  `api.anthropic.com`, which is the same one `/usage` in Claude Code makes.
- **Your Claude login token is read at the moment of that request and nowhere else.** It is read from
  the macOS Keychain (`Claude Code-credentials`) or `~/.claude/.credentials.json`, and passed to `curl`
  on stdin. It never appears in a process listing, a log or a file.
- **limit-guard never refreshes your token.** Refreshing would replace it under your running agents.
  If the token has expired, which happens when no agent has run for a while, limit-guard uses its
  other sources until Claude Code refreshes it.
- **State is owner-only.** `~/.claude/limit-guard/` is created with `umask 077`, and its directories
  are `700`, because session files hold command lines and saved prompts.
- **limit-guard never widens what an agent may do.** It adds no permission flags when resuming, and
  notification text is passed to AppleScript as an argument, never as script.
- **Writing `settings.json` keeps its file mode** (capped at `0644`). If it's a symlink, for example
  managed by dotfiles, limit-guard writes through the link rather than replacing it.

## Files

| Path | What it is |
| --- | --- |
| `~/.local/bin/limit-guard` | Symlink to `bin/limit-guard` in your clone. |
| `~/.claude/limit-guard/config.env` | Your settings. See [Configuration](configuration.md). |
| `~/.claude/limit-guard/state.json` | `running` or `paused`, why, and until when. |
| `~/.claude/limit-guard/usage.json` | The latest usage reading and its source. |
| `~/.claude/limit-guard/sessions/` | One file per Claude session seen by the hooks. |
| `~/.claude/limit-guard/checkpoints/` | Checkpoints written by paused agents. |
| `~/.claude/limit-guard/limit-guard.log` | Decisions, pauses, resumes and errors. No tokens, no prompts. |
| `~/.claude/limit-guard/logs/` | Daemon output, and the output of resumed headless agents. |
| `~/Library/LaunchAgents/com.limit-guard.daemon.plist` | The background service. |
