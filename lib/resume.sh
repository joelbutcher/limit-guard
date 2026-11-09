# shellcheck shell=bash
# Resuming paused sessions.
# lg_resume_session returns: 0 resumed, 2 not yet possible (retry later), 3 needs a human, 1 failed.

lg_resume_prompt() {
  local s="$1" id cp usage
  id="$(printf '%s' "$s" | jq -r .session_id)"
  cp="$(lg_checkpoint_path "$id")"
  usage="$(cat "$LG_HOME/usage.json" 2>/dev/null || echo '{}')"
  jq -rn --argjson s "$s" --argjson u "$usage" --arg cp "$cp" --arg has_cp "$([ -s "$cp" ] && echo 1)" '
    "[limit-guard:resume] Claude usage limits have reset (5h \($u.five_hour.pct // "?")%, 7d \($u.seven_day.pct // "?")%). "
    + (if $s.status == "deferred" and ($s.deferred_prompt // "") != "" then
         "While paused you were sent this prompt; act on it now: " + $s.deferred_prompt
       elif $has_cp == "1" then
         "Read your checkpoint at \($cp) and continue the interrupted task from where you left off."
       else
         "Continue the interrupted task from where you left off (no checkpoint was written; re-check the current state first)."
       end)
    + (if $s.status != "deferred" and ($s.deferred_prompt // "") != "" then
         " Also, while paused you were sent this prompt; handle it after: " + $s.deferred_prompt else "" end)'
}

lg_tmux() {
  local sock="$1"; shift
  if [ -n "$sock" ] && [ "$sock" != "null" ]; then tmux -S "$sock" "$@"; else tmux "$@"; fi
}

# Whitelisted flags from the original `claude -p` command line, re-used on resume.
lg_headless_flags() {
  local argv="$1" prev='' tok out=''
  for tok in $argv; do
    case "$prev" in
      --model|--permission-mode|--max-turns|--effort|--output-format|--fallback-model|--add-dir)
        out="$out $prev $tok" ;;
    esac
    case "$tok" in
      --dangerously-skip-permissions|--verbose) out="$out $tok" ;;
      --model=*|--permission-mode=*|--max-turns=*|--effort=*|--output-format=*|--fallback-model=*) out="$out $tok" ;;
    esac
    prev="$tok"
  done
  echo "$out"
}

lg_transcript_has_turns() {
  local t="$1"
  [ -n "$t" ] && [ -s "$t" ] && grep -q '"type":"assistant"' "$t" 2>/dev/null
}

lg_resume_tmux() {
  local s="$1" prompt="$2" id pane sock pid cwd cmd
  id="$(printf '%s' "$s" | jq -r .session_id)"
  pane="$(printf '%s' "$s" | jq -r '.tmux_pane // empty')"
  sock="$(printf '%s' "$s" | jq -r '.tmux_socket // empty')"
  pid="$(printf '%s' "$s" | jq -r '.pid // empty')"
  cwd="$(printf '%s' "$s" | jq -r '.cwd // empty')"
  lg_tmux "$sock" display-message -p -t "$pane" '#{pane_id}' >/dev/null 2>&1 || return 3

  if lg_pid_alive "$pid"; then
    # Claude is still sitting at its prompt in that pane: type the resume prompt.
    lg_tmux "$sock" send-keys -t "$pane" -l "$prompt" || return 1
    sleep 0.5
    lg_tmux "$sock" send-keys -t "$pane" Enter || return 1
    return 0
  fi
  cmd="$(lg_tmux "$sock" display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)"
  case "$cmd" in
    zsh|bash|sh|fish|-zsh|-bash)
      lg_tmux "$sock" send-keys -t "$pane" -l \
        "cd $(printf '%q' "$cwd") && $LG_CLAUDE_BIN --resume $id $(printf '%q' "$prompt")" || return 1
      lg_tmux "$sock" send-keys -t "$pane" Enter || return 1
      return 0 ;;
  esac
  return 3
}

lg_resume_headless() {
  local s="$1" prompt="$2" id pid cwd argv flags transcript log
  id="$(printf '%s' "$s" | jq -r .session_id)"
  pid="$(printf '%s' "$s" | jq -r '.pid // empty')"
  cwd="$(printf '%s' "$s" | jq -r '.cwd // empty')"
  argv="$(printf '%s' "$s" | jq -r '.argv // empty')"
  transcript="$(printf '%s' "$s" | jq -r '.transcript_path // empty')"
  # Never run two processes on one session.
  lg_pid_alive "$pid" && return 2
  [ -d "$cwd" ] || return 1
  flags="$(lg_headless_flags "$argv")"
  log="$LG_HOME/logs/$id.resume.log"
  printf '\n=== %s resume ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$log"
  if lg_transcript_has_turns "$transcript"; then
    # shellcheck disable=SC2086
    (cd "$cwd" && nohup "$LG_CLAUDE_BIN" -p --resume "$id" $flags "$prompt" >> "$log" 2>&1 &)
  else
    # Blocked before its first turn: run the saved prompt as a fresh headless session.
    prompt="$(printf '%s' "$s" | jq -r '.deferred_prompt // empty')"
    [ -n "$prompt" ] || return 1
    LG_RESUMED_FRESH=1
    # shellcheck disable=SC2086
    (cd "$cwd" && nohup "$LG_CLAUDE_BIN" -p $flags "$prompt" >> "$log" 2>&1 &)
  fi
  return 0
}

lg_resume_session() {
  local id="$1" s kind prompt rc attempts now
  s="$(lg_session_get "$id")"
  [ -n "$s" ] || return 1
  now="$(lg_now)"
  kind="$(printf '%s' "$s" | jq -r '.kind // "terminal"')"
  prompt="$(lg_resume_prompt "$s")"
  LG_RESUMED_FRESH=0
  case "$kind" in
    tmux) lg_resume_tmux "$s" "$prompt"; rc=$? ;;
    headless) lg_resume_headless "$s" "$prompt"; rc=$? ;;
    *) rc=3 ;;
  esac
  attempts="$(printf '%s' "$s" | jq -r '.resume_attempts // 0')"
  case "$rc" in
    0)
      lg_log "resumed $kind session $id"
      # A fresh re-run starts a new session (registered by its own hooks); this one is done.
      lg_session_update "$id" --argjson now "$now" --argjson fresh "$LG_RESUMED_FRESH" \
        '.resumed_at = $now | .resume_attempts = 0 | del(.deferred_prompt)
         | if $fresh == 1 then .status = "ended" | .superseded = true else .status = "active" end' ;;
    2)
      if [ $((attempts + 1)) -ge "$LG_RESUME_MAX_ATTEMPTS" ]; then
        lg_log "giving up resuming $id after $((attempts + 1)) attempts"
        lg_session_update "$id" '.status = "resume_failed"'
      else
        lg_session_update "$id" '.resume_attempts = ((.resume_attempts // 0) + 1)'
      fi ;;
    3)
      lg_log "session $id ($kind) needs a manual continue"
      lg_session_update "$id" --argjson now "$now" '.status = "resume_failed" | .needs_manual = true | .resumed_at = $now' ;;
    *)
      lg_log "failed to resume $kind session $id"
      lg_session_update "$id" '.resume_attempts = ((.resume_attempts // 0) + 1)
        | if .resume_attempts >= '"$LG_RESUME_MAX_ATTEMPTS"' then .status = "resume_failed" else . end' ;;
  esac
  return "$rc"
}
