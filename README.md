# limit-guard

Stop your Claude Code agents from hitting the plan usage limit mid-task.

limit-guard watches your Claude plan usage (the 5-hour and 7-day windows). Just before a limit is
reached it tells every running agent to write a checkpoint and stop cleanly. When the window resets,
it starts them again from their checkpoints.

It is a small macOS background service written in bash, plus Claude Code hooks. It is **not** a
Claude session itself, so watching your usage costs no quota.

```text
$ limit-guard status
limit-guard: 5h 62% · 7d 34%
  usage: source=api confidence=high age=41s
  five_hour resets 14:00
  seven_day resets Sat 02:00
  thresholds: 5h>=95% 7d>=95%
  daemon: pid 65276, last tick 40s ago, next in 560s
  sessions:
    active   background  45115dbd  /Users/you/Projects/api
    active   tmux        8b13d808  /Users/you/Projects/web
    active   desktop     9d4451d1  /Users/you/Projects/infra
```

> **Unofficial.** limit-guard is a personal tool, not an Anthropic product. One of its usage sources
> is an undocumented endpoint that may change. When that happens it falls back to its other sources
> (see [How it works](docs/how-it-works.md)).

## What happens at the limit

When usage reaches **95%** of either window (configurable):

1. **New work stops.** An agent's next tool call is denied with an instruction to write a checkpoint
   (goal, what is done, next steps, files touched, uncommitted state) and end its turn. New prompts
   are held and saved.
2. **It waits.** limit-guard sleeps until the window resets, plus 2 minutes.
3. **Agents resume.** How depends on where the agent is running:

| Where the agent runs | After the reset |
| --- | --- |
| `claude --bg` (background agents) | **Resumed automatically** in the same session, with the same settings. |
| tmux pane | **Resumed automatically**: the resume prompt is typed into the pane. |
| `claude -p` (headless) | **Resumed automatically** with `claude -p --resume`. |
| Claude desktop app, or a plain terminal tab | **You continue it.** You get a notification naming the sessions. Send any message (`continue` is enough) and the agent is handed its checkpoint and anything you sent while it was paused. |

**For unattended runs, such as overnight, start your agents with `claude --bg`.** You can still
watch or take over any of them with `claude attach <id>`, and list them with `claude agents`.

## Requirements

- macOS, with the Claude desktop app or the Claude Code CLI signed in to a Claude subscription
  (Pro, Max, Team or Enterprise). API-key billing has no plan windows to watch.
- `jq` and `curl`. Both are built into macOS 15 and later. On older macOS, run `brew install jq`.
- `~/.local/bin` on your `PATH`, so you can run the `limit-guard` command. Claude Code's installer
  normally adds it.

## Install

```bash
git clone https://github.com/joelbutcher/limit-guard.git ~/.limit-guard
~/.limit-guard/bin/limit-guard install
```

The installer:

- links `~/.local/bin/limit-guard` to the clone, so keep the clone where it is;
- writes your config to `~/.claude/limit-guard/config.env`;
- adds five hooks and a statusline to `~/.claude/settings.json`, after backing it up to
  `settings.json.bak-limit-guard-<timestamp>`. If you already had a statusline, it keeps working:
  limit-guard shows its first line, followed by its own short summary;
- starts the background service (a launchd agent), which also starts at login and restarts if it crashes.

**Restart any Claude sessions that are already open**, so they load the new hooks. Then check it:

```bash
limit-guard status
```

The `daemon:` line should show a pid, and within a minute `usage:` should show a percentage.

### Update

```bash
git -C ~/.limit-guard pull
limit-guard install daemon
```

### Uninstall

```bash
limit-guard uninstall
```

This removes the hooks, the statusline entry (restoring yours if you had one), the background service
and the symlink. Your state in `~/.claude/limit-guard/` is kept; delete it if you don't want it.

## Everyday use

```bash
limit-guard status            # usage, pause state, tracked sessions
limit-guard log -f            # follow what it decides and why
limit-guard pause "lunch"     # pause everything now; stays paused until you resume
limit-guard resume            # resume now and restart paused agents
limit-guard resume --force    # resume even if usage still looks over the limit
LIMIT_GUARD_DISABLE=1 claude  # run one session without limit-guard
```

To change the thresholds, edit `~/.claude/limit-guard/config.env` and run `limit-guard install daemon`:

```bash
LG_PAUSE_5H=95   # pause at this % of the 5-hour window
LG_PAUSE_7D=95   # pause at this % of the 7-day window
```

All settings are listed in [Configuration](docs/configuration.md).

## Good to know

- **A pause applies to every agent on your Mac**, including the session you're typing in. If you
  need to get something done while paused, use `limit-guard resume --force`, or start that one
  session with `LIMIT_GUARD_DISABLE=1`.
- **An agent that is only writing text can't be stopped mid-reply.** Pausing works by denying tool
  calls, so the agent finishes its reply and is held at its next prompt.
- **Agents are asked to checkpoint; they aren't forced to.** In practice they write good checkpoints,
  but an agent can end its turn without one. On resume it is told to re-check the current state first.
- **Usage is shared across your devices.** Usage from claude.ai or another machine counts too, and
  limit-guard sees it, but it can only pause agents on this Mac.

## Documentation

- [How it works](docs/how-it-works.md): usage sources, the pause decision, hooks, and how each
  kind of session is resumed.
- [Configuration](docs/configuration.md): every setting and file.
- [Troubleshooting](docs/troubleshooting.md): common situations and what to do.
- [Privacy and security](docs/how-it-works.md#privacy-and-security): what it reads, and what it never stores.

## Development

```bash
tests/run.sh          # the whole suite, offline (about 15s)
tests/run.sh resume   # only tests whose name matches
```

The tests stub `security`, `curl`, `tmux`, `claude` and `osascript`, and fix the clock with `LG_NOW`,
so they never touch your real Claude setup or quota. The code is bash 3.2 compatible, matching
macOS's `/bin/bash`.
