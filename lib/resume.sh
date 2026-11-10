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

# Harmless flags recovered from the original `claude -p` command line, one per line.
# `ps` output loses quoting, so prompt text could look like flags: only flags that cannot
# widen what the agent may do are recovered, and each value must match a strict pattern.
# Permission flags (--dangerously-skip-permissions, --permission-mode, --allowedTools, --add-dir)
# are NEVER recovered; declare them explicitly in LG_HEADLESS_RESUME_FLAGS if you want them.
lg_headless_flags() {
  local argv="$1" prev='' tok toks extra
  # read -a splits on whitespace without glob expansion (a bare * in a prompt stays a *).
  read -r -a toks <<< "$argv"
  for tok in ${toks[@]+"${toks[@]}"}; do
    case "$prev" in
      --model|--fallback-model)
        printf '%s' "$tok" | grep -Eq '^[A-Za-z0-9._:-]{1,64}$' && printf '%s\n%s\n' "$prev" "$tok" ;;
      --effort)
        case "$tok" in low|medium|high|xhigh|max) printf '%s\n%s\n' "$prev" "$tok" ;; esac ;;
      --output-format)
        case "$tok" in text|json|stream-json) printf '%s\n%s\n' "$prev" "$tok" ;; esac ;;
      --max-turns)
        printf '%s' "$tok" | grep -Eq '^[0-9]{1,4}$' && printf '%s\n%s\n' "$prev" "$tok" ;;
    esac
    [ "$tok" = "--verbose" ] && printf '%s\n' "$tok"
    prev="$tok"
  done
  # Explicit, user-declared extra flags (config.env), split on whitespace.
  read -r -a extra <<< "${LG_HEADLESS_RESUME_FLAGS:-}"
  for tok in ${extra[@]+"${extra[@]}"}; do printf '%s\n' "$tok"; done
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
  local s="$1" prompt="$2" id pid cwd argv transcript log flag
  local flags=()
  id="$(printf '%s' "$s" | jq -r .session_id)"
  pid="$(printf '%s' "$s" | jq -r '.pid // empty')"
  cwd="$(printf '%s' "$s" | jq -r '.cwd // empty')"
  argv="$(printf '%s' "$s" | jq -r '.argv // empty')"
  transcript="$(printf '%s' "$s" | jq -r '.transcript_path // empty')"
  # Never run two processes on one session.
  lg_pid_alive "$pid" && return 2
  [ -d "$cwd" ] || return 1
  while IFS= read -r flag; do
    [ -n "$flag" ] && flags[${#flags[@]}]="$flag"
  done <<EOF
$(lg_headless_flags "$argv")
EOF
  log="$LG_HOME/logs/$id.resume.log"
  printf '\n=== %s resume ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$log"
  if lg_transcript_has_turns "$transcript"; then
    (cd "$cwd" && nohup "$LG_CLAUDE_BIN" -p --resume "$id" ${flags[@]+"${flags[@]}"} "$prompt" >> "$log" 2>&1 &)
  else
    # Blocked before its first turn: run the saved prompt as a fresh headless session.
    prompt="$(printf '%s' "$s" | jq -r '.deferred_prompt // empty')"
    [ -n "$prompt" ] || return 1
    LG_RESUMED_FRESH=1
    (cd "$cwd" && nohup "$LG_CLAUDE_BIN" -p ${flags[@]+"${flags[@]}"} "$prompt" >> "$log" 2>&1 &)
  fi
  return 0
}

# Background sessions (`claude --bg`) stay alive, idle at their prompt, after the agent stops.
# Stop the idle process, then wake the same session with the prompt. The background service
# restores the session's own saved options (model, name, permission mode); limit-guard adds none.
lg_resume_background() {
  local s="$1" prompt="$2" id status pid cwd transcript log i
  id="$(printf '%s' "$s" | jq -r .session_id)"
  status="$(printf '%s' "$s" | jq -r '.status // empty')"
  pid="$(printf '%s' "$s" | jq -r '.pid // empty')"
  cwd="$(printf '%s' "$s" | jq -r '.cwd // empty')"
  transcript="$(printf '%s' "$s" | jq -r '.transcript_path // empty')"
  [ -d "$cwd" ] || return 1
  if lg_pid_alive "$pid"; then
    # Only a session whose turn has ended (Stop hook fired) is safe to stop.
    case "$status" in paused|deferred) ;; *) return 2 ;; esac
    "$LG_CLAUDE_BIN" stop "${id:0:8}" >/dev/null 2>&1
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      lg_pid_alive "$pid" || break
      sleep 1
    done
    lg_pid_alive "$pid" && return 2
  fi
  log="$LG_HOME/logs/$id.resume.log"
  printf '\n=== %s background resume ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$log"
  # A background session's transcript holds its settings even before the first turn, so resume it whenever
  # one exists; the resume prompt carries any prompt saved while paused.
  if [ -s "$transcript" ]; then
    (cd "$cwd" && "$LG_CLAUDE_BIN" --bg --resume "$id" "$prompt") >> "$log" 2>&1 || return 1
  else
    prompt="$(printf '%s' "$s" | jq -r '.deferred_prompt // empty')"
    [ -n "$prompt" ] || return 1
    LG_RESUMED_FRESH=1
    (cd "$cwd" && "$LG_CLAUDE_BIN" --bg "$prompt") >> "$log" 2>&1 || return 1
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
    background) lg_resume_background "$s" "$prompt"; rc=$? ;;
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
