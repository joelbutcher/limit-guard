# shellcheck shell=bash
# Session registry: one JSON file per Claude session under $LG_HOME/sessions.
# {
#   session_id, cwd, transcript_path, pid, argv, kind: tmux|headless|desktop|terminal,
#   tmux_pane, tmux_socket, status: active|checkpoint_requested|paused|deferred|resume_failed|ended,
#   deferred_prompt, started_at, last_seen, paused_at, resumed_at, resume_attempts, exited
# }

lg_session_file() { echo "$LG_HOME/sessions/$1.json"; }

lg_session_get() { cat "$(lg_session_file "$1")" 2>/dev/null; }

# lg_session_update <id> <jq args...>
lg_session_update() {
  local id="$1"; shift
  lg_jq_update "$(lg_session_file "$id")" "$@"
}

# Walk up from the hook's parent to the claude process. Tests may set LG_TEST_PID/LG_TEST_ARGV.
lg_find_claude_pid() {
  if [ -n "${LG_TEST_PID:-}" ]; then echo "$LG_TEST_PID"; return; fi
  local p="${PPID:-}" i=0 comm
  while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$i" -lt 8 ]; do
    comm="$(ps -o comm= -p "$p" 2>/dev/null)"
    case "$comm" in
      */claude|claude|*/.local/share/claude/versions/*|*/claude-code/*/claude) echo "$p"; return ;;
    esac
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    i=$((i + 1))
  done
  return 1
}

lg_proc_args() {
  if [ -n "${LG_TEST_ARGV:-}" ]; then echo "$LG_TEST_ARGV"; return; fi
  ps -o args= -p "$1" 2>/dev/null
}

lg_pid_alive() {
  [ -n "$1" ] && [ "$1" != "null" ] && [ "$1" != "0" ] || return 1
  if [ -n "${LG_TEST_ALIVE:-}" ]; then
    case " $LG_TEST_ALIVE " in *" $1 "*) return 0 ;; *) return 1 ;; esac
  fi
  kill -0 "$1" 2>/dev/null
}

lg_classify() {
  local argv="$1"
  case " $argv " in
    *" --input-format stream-json "*|*" --input-format=stream-json "*) echo desktop; return ;;
    *" -p "*|*" --print "*) echo headless; return ;;
  esac
  if [ -n "${TMUX_PANE:-}" ]; then echo tmux; else echo terminal; fi
}

# Register (or refresh) a session from hook input JSON.
lg_session_register() {
  local input="$1" now id file pid argv kind sock
  now="$(lg_now)"
  id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
  [ -n "$id" ] || return 1
  file="$(lg_session_file "$id")"
  pid="$(lg_find_claude_pid)" || pid=''
  argv=''
  [ -n "$pid" ] && argv="$(lg_proc_args "$pid")"
  kind="$(lg_classify "$argv")"
  sock=''
  [ -n "${TMUX:-}" ] && sock="${TMUX%%,*}"
  printf '%s' "$input" | jq -c \
    --argjson now "$now" --arg pid "$pid" --arg argv "$argv" --arg kind "$kind" \
    --arg pane "${TMUX_PANE:-}" --arg sock "$sock" \
    --argjson prev "$(cat "$file" 2>/dev/null || echo '{}')" '
    $prev + {
      session_id: .session_id,
      cwd: (.cwd // $prev.cwd),
      transcript_path: (.transcript_path // $prev.transcript_path),
      pid: (if $pid == "" then $prev.pid else ($pid | tonumber) end),
      argv: (if $argv == "" then $prev.argv else $argv end),
      kind: $kind,
      tmux_pane: (if $pane == "" then null else $pane end),
      tmux_socket: (if $sock == "" then null else $sock end),
      status: (if ($prev.status // "ended") == "ended" or $prev.status == "resume_failed" then "active" else $prev.status end),
      started_at: ($prev.started_at // $now),
      last_seen: $now,
      exited: false
    }' | lg_write "$file"
}

lg_session_ensure() {
  local input="$1" id
  id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
  [ -n "$id" ] || return 1
  [ -s "$(lg_session_file "$id")" ] || lg_session_register "$input"
}

lg_sessions_with_status() {
  # prints session ids whose status is one of the given values
  local f
  for f in "$LG_HOME"/sessions/*.json; do
    [ -s "$f" ] || continue
    jq -r --arg want " $* " '(.status // "") as $s | select($want | contains(" " + $s + " ")) | .session_id' "$f" 2>/dev/null
  done
}

# Drop ended sessions older than a week.
lg_sessions_gc() {
  local now f
  now="$(lg_now)"
  for f in "$LG_HOME"/sessions/*.json; do
    [ -s "$f" ] || continue
    if jq -e --argjson now "$now" '(.status == "ended" or .status == "resume_failed") and (($now - (.last_seen // 0)) > 604800)' "$f" >/dev/null 2>&1; then
      rm -f "$f"
    fi
  done
}

lg_checkpoint_path() { echo "$LG_CHECKPOINT_DIR/$1.md"; }
