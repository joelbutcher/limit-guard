# Troubleshooting

Start with these two commands. Most questions are answered by them.

```bash
limit-guard status
limit-guard log
```

## `daemon: NOT RUNNING`

Reinstall the service:

```bash
limit-guard install daemon
```

If it still isn't running, look at its own output:

```bash
cat ~/.claude/limit-guard/logs/daemon.err
```

## `usage: no data yet`, or the percentage never changes

- **Just installed?** The first reading arrives within a minute.
- **`usage api unavailable (rc=3)` in the log** means your Claude login token has expired. That's
  normal when no agent has run for a while; limit-guard never refreshes the token itself. It uses
  its other sources until any Claude session refreshes the token. Running any Claude Code command
  fixes it.
- **`rc=4`** means it is backing off after being rate-limited. It tries again in 10 minutes.
- **`source=estimate confidence=low`** means only the transcript estimate was available. It becomes
  accurate again with the next real reading.

## An agent wasn't paused

- **Was the session open before you installed?** Sessions load hooks when they start. Restart them.
- **Was it only writing text?** limit-guard pauses by denying tool calls. A reply with no tool calls
  finishes, and then the session is held at its next prompt.
- **Started with `LIMIT_GUARD_DISABLE=1`, or with `--bare`?** Both skip hooks.
- Check it is listed in `limit-guard status`. If it isn't, its hooks didn't run.

## An agent wasn't resumed

Look for its line in `limit-guard log`:

| Log says | Meaning | What to do |
| --- | --- | --- |
| `needs a manual continue` | A desktop-app or plain terminal session. | Send it any message, for example `continue`. It is handed its checkpoint. |
| `giving up resuming` | It never became ready (for example, still mid-turn) after several tries. | Continue it by hand, or run `limit-guard resume`. |
| `failed to resume` | The resume command failed. | See `~/.claude/limit-guard/logs/<session>.resume.log`. |
| nothing | It finished its turn before the pause, so there was nothing to resume. | — |

Background agents also show up in `claude agents`. Open one with `claude attach <id>` to see what it did.

## I need to work while paused

```bash
limit-guard resume --force     # resume everything now
LIMIT_GUARD_DISABLE=1 claude   # or: one session that ignores the pause
```

A forced resume restarts the agents that were paused, so they will use what's left of your window.

## A prompt I typed was blocked

While paused, prompts are saved, not lost. Automatically resumed agents get them on resume.
Desktop and terminal sessions get them with the first message you send after the reset.

## My statusline changed

limit-guard installs itself as the statusline so it can read usage for free. If you had one, it
still runs: its first line is shown, followed by limit-guard's short summary. Its command is stored as
`LG_STATUSLINE_CHAIN` in `config.env`. `limit-guard uninstall` puts it back.

## Removing it

```bash
limit-guard uninstall
rm -rf ~/.claude/limit-guard   # optional: state, checkpoints and logs
```

Your `~/.claude/settings.json` is also backed up as `settings.json.bak-limit-guard-<timestamp>`
every time limit-guard changes it.
