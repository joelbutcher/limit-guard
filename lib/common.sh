# shellcheck shell=bash
# Shared paths, config, logging, clock and atomic file helpers.
# Bash 3.2 compatible (macOS /bin/bash).

LG_HOME="${LG_HOME:-$HOME/.claude/limit-guard}"

lg_defaults() {
  : "${LG_PAUSE_5H:=90}"            # pause when 5-hour usage reaches this %
  : "${LG_PAUSE_7D:=95}"            # pause when 7-day usage reaches this %
  : "${LG_RESUME_GRACE:=120}"       # seconds to wait after resets_at before resuming
  : "${LG_HB_MIN:=60}"              # shortest heartbeat (seconds)
  : "${LG_HB_MAX:=900}"             # longest heartbeat (seconds)
  : "${LG_SAMPLE_MAX_AGE:=300}"     # statusline/stream samples younger than this skip the API call
  : "${LG_API_MIN_INTERVAL:=60}"    # never call the usage endpoint more often than this
  : "${LG_API_URL:=https://api.anthropic.com/api/oauth/usage}"
  : "${LG_ESTIMATE:=1}"             # 1 = allow the transcript estimate as a last resort
  : "${LG_CALIBRATE_EVERY:=1800}"   # seconds between estimate calibrations
  : "${LG_PROJECTS_DIR:=$HOME/.claude/projects}"
  : "${LG_CHECKPOINT_DIR:=$LG_HOME/checkpoints}"
  : "${LG_ALLOW_TOOLS:=TodoWrite TaskCreate TaskUpdate}"  # tools still allowed while paused
  : "${LG_CLAUDE_BIN:=claude}"
  : "${LG_NOTIFY:=1}"
  : "${LG_RESUME_MAX_ATTEMPTS:=5}"
  : "${LG_STATUSLINE_CHAIN:=}"      # original statusline command to chain to
}

lg_load_config() {
  if [ -f "$LG_HOME/config.env" ]; then
    # shellcheck disable=SC1091
    . "$LG_HOME/config.env"
  fi
  lg_defaults
}

lg_init() {
  mkdir -p "$LG_HOME/sessions" "$LG_HOME/samples" "$LG_HOME/logs" 2>/dev/null || true
  lg_load_config
  mkdir -p "$LG_CHECKPOINT_DIR" 2>/dev/null || true
}

lg_now() {
  if [ -n "${LG_NOW:-}" ]; then echo "$LG_NOW"; else date +%s; fi
}

lg_log() {
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${LG_COMPONENT:-cli}" "$*" \
    >> "$LG_HOME/limit-guard.log" 2>/dev/null || true
}

lg_die() { echo "limit-guard: $*" >&2; exit 1; }

# Write stdin to a file atomically (same-directory temp + rename).
lg_write() {
  local target="$1" tmp
  tmp="$(mktemp "${target}.XXXXXX")" || return 1
  cat > "$tmp" && mv -f "$tmp" "$target"
}

# Apply a jq filter to a JSON file in place, atomically. Missing file starts as {}.
lg_jq_update() {
  local file="$1"; shift
  local current='{}'
  [ -s "$file" ] && current="$(cat "$file")"
  printf '%s' "$current" | jq "$@" | lg_write "$file"
}

# Directory lock with stale-owner recovery. Usage: lg_lock name && ...; lg_unlock name
lg_lock() {
  local dir="$LG_HOME/.$1.lock" tries=0 owner
  while ! mkdir "$dir" 2>/dev/null; do
    owner="$(cat "$dir/pid" 2>/dev/null)"
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$dir"; continue
    fi
    tries=$((tries + 1))
    [ "$tries" -ge 50 ] && return 1
    sleep 0.1
  done
  echo "$$" > "$dir/pid"
}

lg_unlock() { rm -rf "$LG_HOME/.$1.lock"; }

# jq helper: ISO-8601 (with optional fraction / offset) or epoch -> epoch seconds.
LG_JQ_TO_EPOCH='def to_epoch:
  if . == null then null
  elif type == "number" then (if . > 100000000000 then (. / 1000 | floor) else floor end)
  elif type == "string" and test("^[0-9]+(\\.[0-9]+)?$") then (tonumber | to_epoch)
  elif type == "string" then
    (sub("\\.[0-9]+"; "")
     | capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")
     | ((.d + "Z") | fromdateiso8601)
       - ((.z // "Z") | if . == "Z" then 0
          else ((if .[0:1] == "-" then -1 else 1 end) * ((.[1:3] | tonumber) * 3600 + (.[-2:] | tonumber) * 60)) end))
  else null end;'

lg_fmt_time() {
  # epoch -> local HH:MM (with weekday if not today)
  local ts="$1"
  [ -z "$ts" ] || [ "$ts" = "null" ] && { echo "?"; return; }
  if [ "$(date -r "$ts" +%F)" = "$(date +%F)" ]; then date -r "$ts" +%H:%M; else date -r "$ts" '+%a %H:%M'; fi
}

lg_notify() {
  [ "$LG_NOTIFY" = "1" ] || return 0
  local msg="$1"
  lg_log "notify: $msg"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${msg//\"/\\\"}\" with title \"limit-guard\"" >/dev/null 2>&1 || true
  fi
}
