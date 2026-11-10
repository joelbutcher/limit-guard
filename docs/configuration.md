# Configuration

Settings live in `~/.claude/limit-guard/config.env`. The file is sourced by bash, so it uses
`NAME=value` lines, and `#` starts a comment. Anything you leave out uses its default.

After changing it, restart the background service so it picks the change up. Hooks read the file
on every event, so they pick changes up straight away.

```bash
limit-guard install daemon
```

## When to pause and resume

| Setting | Default | What it does |
| --- | --- | --- |
| `LG_PAUSE_5H` | `95` | Pause when the 5-hour window reaches this percentage. |
| `LG_PAUSE_7D` | `95` | Pause when the 7-day window reaches this percentage. |
| `LG_RESUME_GRACE` | `120` | Seconds to wait after a reset before resuming. |
| `LG_RESUME_MAX_ATTEMPTS` | `5` | Tries to resume a session that isn't ready yet, before giving up on it. |

Pausing earlier leaves more headroom for agents to write their checkpoints. Pausing later uses more
of your window. Between 90 and 95 works well.

## How often to check

| Setting | Default | What it does |
| --- | --- | --- |
| `LG_HB_MIN` | `60` | Shortest time between checks, in seconds. |
| `LG_HB_MAX` | `900` | Longest time between checks, in seconds. |
| `LG_SAMPLE_MAX_AGE` | `300` | A statusline or stream reading younger than this is used without calling the usage endpoint. |
| `LG_API_MIN_INTERVAL` | `60` | Never call the usage endpoint more often than this. |
| `LG_ESTIMATE` | `1` | Set to `0` to never use the transcript estimate. |
| `LG_CALIBRATE_EVERY` | `1800` | Seconds between updates of the estimate's tokens-to-percent figure. |

## While paused

| Setting | Default | What it does |
| --- | --- | --- |
| `LG_ALLOW_TOOLS` | `TodoWrite TaskCreate TaskUpdate` | Tools agents may still use while paused, space-separated. Writing the checkpoint is always allowed. |
| `LG_CHECKPOINT_DIR` | `~/.claude/limit-guard/checkpoints` | Where agents write their checkpoints. |
| `LG_NOTIFY` | `1` | Set to `0` to turn off macOS notifications. |

## Resuming

| Setting | Default | What it does |
| --- | --- | --- |
| `LG_CLAUDE_BIN` | the `claude` found at install | Absolute path of the `claude` command used to resume agents. It is absolute so launchd can find it and shell aliases never apply. |
| `LG_HEADLESS_RESUME_FLAGS` | empty | Extra flags for resuming `claude -p` agents, for example `--permission-mode acceptEdits`. Permission flags are never copied from the original command, so set them here if headless agents need them. |

Background (`claude --bg`) agents need nothing here; they resume with their own saved settings.

## Other

| Setting | Default | What it does |
| --- | --- | --- |
| `LG_STATUSLINE_CHAIN` | your previous statusline | The statusline command limit-guard runs alongside its own. Set at install. |
| `LG_PROJECTS_DIR` | `~/.claude/projects` | Where Claude Code keeps transcripts (used by the estimate). |
| `LG_HOME` | `~/.claude/limit-guard` | State directory. Set it as an environment variable, not in `config.env`. |

## Per session

```bash
LIMIT_GUARD_DISABLE=1 claude   # this session ignores limit-guard entirely
```
