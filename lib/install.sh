# shellcheck shell=bash
# install / uninstall: CLI symlink, Claude Code hooks + statusline, launchd agent.

LG_LABEL="${LG_LABEL:-com.limit-guard.daemon}"
LG_SETTINGS="${LG_SETTINGS:-$HOME/.claude/settings.json}"
LG_PLIST="${LG_PLIST:-$HOME/Library/LaunchAgents/$LG_LABEL.plist}"
LG_BIN_LINK="${LG_BIN_LINK:-$HOME/.local/bin/limit-guard}"

lg_backup_settings() {
  [ -f "$LG_SETTINGS" ] || { echo '{}' > "$LG_SETTINGS"; return; }
  cp -p "$LG_SETTINGS" "$LG_SETTINGS.bak-limit-guard-$(date +%Y%m%d-%H%M%S)"
}

# Remove our hook entries (matched by command) and drop empty groups/events.
LG_JQ_STRIP_HOOKS='
  def ours: (.command // "") | test("limit-guard(\\.sh)? hook");
  if .hooks then
    .hooks |= (with_entries(.value |= (map(.hooks |= map(select(ours | not))) | map(select((.hooks | length) > 0))))
               | with_entries(select((.value | length) > 0)))
    | (if (.hooks | length) == 0 then del(.hooks) else . end)
  else . end'

lg_install_hooks() {
  local cmd="$LG_BIN_LINK hook"
  lg_backup_settings
  lg_jq_update "$LG_SETTINGS" --arg cmd "$cmd" "$LG_JQ_STRIP_HOOKS"'
    | def entry($t): {type: "command", command: $cmd, timeout: $t};
      .hooks = (.hooks // {})
    | .hooks.SessionStart     = ((.hooks.SessionStart // [])     + [{hooks: [entry(10)]}])
    | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [{hooks: [entry(10)]}])
    | .hooks.PreToolUse       = ((.hooks.PreToolUse // [])       + [{matcher: "*", hooks: [entry(10)]}])
    | .hooks.Stop             = ((.hooks.Stop // [])             + [{hooks: [entry(10)]}])
    | .hooks.SessionEnd       = ((.hooks.SessionEnd // [])       + [{hooks: [entry(5)]}])'
}

lg_install_statusline() {
  local current ours="$LG_BIN_LINK statusline"
  current="$(jq -r '.statusLine.command // empty' "$LG_SETTINGS" 2>/dev/null)"
  if [ -n "$current" ] && [ "$current" != "$ours" ]; then
    # Keep the user's own statusline: limit-guard chains to it.
    lg_config_set LG_STATUSLINE_CHAIN "$current"
    echo "  existing statusline chained: $current"
  fi
  lg_jq_update "$LG_SETTINGS" --arg cmd "$ours" '.statusLine = ((.statusLine // {}) + {type: "command", command: $cmd})'
}

lg_config_set() {
  local key="$1" val="$2" file="$LG_HOME/config.env"
  touch "$file"
  grep -v "^$key=" "$file" > "$file.tmp" || true
  # Single-quoted so ~, $ and spaces survive being sourced.
  printf "%s='%s'\n" "$key" "$(printf '%s' "$val" | sed "s/'/'\\\\''/g")" >> "$file.tmp"
  mv -f "$file.tmp" "$file"
}

lg_write_default_config() {
  local file="$LG_HOME/config.env" claude_bin
  [ -f "$file" ] && return 0
  # Absolute path, so launchd can find it and shell aliases never apply.
  if [ -x "$HOME/.local/bin/claude" ]; then claude_bin="$HOME/.local/bin/claude"
  else claude_bin="$(command -v claude 2>/dev/null || echo claude)"; fi
  cat > "$file" <<EOF
# limit-guard configuration (sourced by bash). Values shown are the defaults.
LG_PAUSE_5H=95          # pause when 5-hour usage reaches this %
LG_PAUSE_7D=95          # pause when 7-day usage reaches this %
LG_RESUME_GRACE=120     # seconds after the reset before resuming
LG_HB_MIN=60            # shortest heartbeat
LG_HB_MAX=900           # longest heartbeat
LG_API_MIN_INTERVAL=60  # never call the usage endpoint more often than this
LG_ESTIMATE=1           # allow the low-confidence transcript estimate as a last resort
LG_NOTIFY=1             # macOS notifications on pause/resume
LG_CLAUDE_BIN=$claude_bin
EOF
}

lg_install_launchd() {
  local path_env="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin"
  mkdir -p "$(dirname "$LG_PLIST")"
  cat > "$LG_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LG_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$LG_BIN_LINK</string><string>daemon</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$path_env</string><key>HOME</key><string>$HOME</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LG_HOME/logs/daemon.out</string>
  <key>StandardErrorPath</key><string>$LG_HOME/logs/daemon.err</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$LG_LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$LG_PLIST"
}

# Hard requirements fail the install; things that only limit features are warnings.
lg_preflight() {
  local jq_bin="${LG_PREFLIGHT_JQ:-jq}" ok=0
  if ! command -v "$jq_bin" >/dev/null 2>&1; then
    echo "✗ jq is required (built into macOS 15+; otherwise: brew install jq)" >&2; ok=1
  fi
  command -v curl >/dev/null 2>&1 || { echo "✗ curl is required" >&2; ok=1; }
  if [ ! -x "$HOME/.local/bin/claude" ] && ! command -v claude >/dev/null 2>&1; then
    echo "! claude not found: install Claude Code first, or set LG_CLAUDE_BIN in $LG_HOME/config.env" >&2
  fi
  case ":$PATH:" in
    *":$(dirname "$LG_BIN_LINK"):"*) ;;
    *) echo "! $(dirname "$LG_BIN_LINK") is not on your PATH: add it to use the limit-guard command (hooks and the daemon work regardless)" >&2 ;;
  esac
  return "$ok"
}

lg_install() {
  local repo="$1" what="${2:-all}"
  lg_preflight || return 1
  mkdir -p "$(dirname "$LG_BIN_LINK")"
  ln -sfn "$repo/bin/limit-guard" "$LG_BIN_LINK"
  echo "✓ $LG_BIN_LINK -> $repo/bin/limit-guard"
  lg_write_default_config
  echo "✓ config: $LG_HOME/config.env"
  case "$what" in all|hooks)
    lg_install_hooks; echo "✓ hooks added to $LG_SETTINGS (backup alongside)"
    lg_install_statusline; echo "✓ statusline set" ;;
  esac
  case "$what" in all|daemon)
    lg_install_launchd; echo "✓ launchd agent $LG_LABEL loaded" ;;
  esac
}

lg_uninstall() {
  launchctl bootout "gui/$(id -u)/$LG_LABEL" >/dev/null 2>&1 || true
  rm -f "$LG_PLIST"
  echo "✓ launchd agent removed"
  if [ -f "$LG_SETTINGS" ]; then
    lg_backup_settings
    lg_jq_update "$LG_SETTINGS" "$LG_JQ_STRIP_HOOKS"
    if [ "$(jq -r '.statusLine.command // empty' "$LG_SETTINGS")" = "$LG_BIN_LINK statusline" ]; then
      if [ -n "$LG_STATUSLINE_CHAIN" ]; then
        lg_jq_update "$LG_SETTINGS" --arg c "$LG_STATUSLINE_CHAIN" '.statusLine.command = $c'
      else
        lg_jq_update "$LG_SETTINGS" 'del(.statusLine)'
      fi
    fi
    echo "✓ hooks and statusline removed from $LG_SETTINGS"
  fi
  [ -L "$LG_BIN_LINK" ] && rm -f "$LG_BIN_LINK" && echo "✓ $LG_BIN_LINK removed"
  echo "State kept in $LG_HOME (delete it by hand if you want)."
}
