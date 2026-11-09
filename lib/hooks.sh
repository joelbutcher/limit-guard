# shellcheck shell=bash
# Claude Code hook handler. One entrypoint for every event; reads the hook JSON on stdin.
# Contract: never block by accident. Any internal failure exits 0 with no output.

lg_hook_paused_context() {
  local st usage
  st="$(lg_state)"
  usage="$(cat "$LG_HOME/usage.json" 2>/dev/null || echo '{}')"
  jq -rn --argjson s "$st" --argjson u "$usage" --arg until "$(lg_fmt_time "$(printf '%s' "$st" | jq -r '.resume_at // empty')")" '
    "Claude plan usage: 5h \($u.five_hour.pct // "?")%, 7d \($u.seven_day.pct // "?")% (paused: \($s.reason // "manual")). Expected resume: \($until)."'
}

lg_hook_deny_reason() {
  local id="$1" cp
  cp="$(lg_checkpoint_path "$id")"
  printf '%s' "limit-guard: work is paused to stay under the Claude plan usage limits. $(lg_hook_paused_context) \
Do NOT start or continue any other work. Your only remaining actions: (1) write a concise checkpoint to $cp with the Write tool \
covering the task goal, what is done, the exact next steps, files touched and any uncommitted or half-applied state; \
(2) end your turn immediately with a one-line summary. limit-guard will resume this session automatically after the reset \
and point you at the checkpoint."
}

lg_hook_pretooluse() {
  local input="$1" id tool path cp allowed t
  id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
  tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
  cp="$(lg_checkpoint_path "$id")"

  # The checkpoint write itself is always allowed.
  case "$tool" in
    Write|Edit|MultiEdit)
      path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
      if [ "$path" = "$cp" ]; then
        lg_session_update "$id" --argjson now "$(lg_now)" '.checkpoint_written_at = $now'
        return 0
      fi ;;
  esac
  allowed=0
  for t in $LG_ALLOW_TOOLS; do [ "$t" = "$tool" ] && allowed=1; done
  [ "$allowed" = 1 ] && return 0

  lg_session_update "$id" --argjson now "$(lg_now)" '
    if (.status // "active") == "active" then .status = "checkpoint_requested" | .paused_at = $now else . end
    | .denied = ((.denied // 0) + 1) | .last_seen = $now'
  jq -cn --arg r "$(lg_hook_deny_reason "$id")" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
}

lg_hook_stop() {
  local id="$1"
  # Only sessions we interrupted count as paused; a session that just finished its turn has nothing to resume.
  lg_session_update "$id" --argjson now "$(lg_now)" '
    if .status == "checkpoint_requested" then .status = "paused" | .stopped_at = $now else . end | .last_seen = $now'
}

lg_hook_userpromptsubmit() {
  local input="$1" id prompt
  id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
  prompt="$(printf '%s' "$input" | jq -r '.prompt // empty')"
  case "$prompt" in "[limit-guard:resume]"*) return 0 ;; esac
  lg_session_update "$id" --argjson now "$(lg_now)" --arg p "$prompt" '
    .deferred_prompt = $p | .deferred_at = $now | .last_seen = $now
    | if (.status // "active") == "active" then .status = "deferred" else . end'
  jq -cn --arg r "limit-guard: paused to stay under the Claude plan usage limits. $(lg_hook_paused_context) \
Your prompt was saved and will be sent to this session automatically after the reset. \
To override now: limit-guard resume --force" '{decision: "block", reason: $r}'
}

lg_hook_sessionstart() {
  local input="$1"
  jq -cn --arg c "limit-guard is active and has paused work to stay under the Claude plan usage limits. $(lg_hook_paused_context) \
Do not start new work; it will be resumed automatically after the reset." \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
}

lg_hook_sessionend() {
  local id="$1"
  # Headless sessions exit after pausing; keep them resumable.
  lg_session_update "$id" --argjson now "$(lg_now)" '
    .exited = true | .exited_at = $now | .last_seen = $now
    | if (.status // "active") == "active" then .status = "ended" else . end'
}

lg_hook() {
  LG_COMPONENT=hook
  [ "${LIMIT_GUARD_DISABLE:-0}" = "1" ] && return 0
  local input event id mode
  input="$(cat)"
  event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)" || return 0
  id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
  [ -n "$event" ] && [ -n "$id" ] || return 0
  mode="$(lg_state_mode)"

  case "$event" in
    SessionStart)
      lg_session_register "$input"
      [ "$mode" = "paused" ] && lg_hook_sessionstart "$input"
      ;;
    PreToolUse)
      [ "$mode" = "paused" ] || return 0
      lg_session_ensure "$input"
      lg_hook_pretooluse "$input"
      ;;
    UserPromptSubmit)
      lg_session_ensure "$input"
      if [ "$mode" = "paused" ]; then
        lg_hook_userpromptsubmit "$input"
      else
        # Someone is driving the session again: it no longer needs an automatic resume.
        lg_session_update "$id" --argjson now "$(lg_now)" '
          .last_seen = $now | if (.status == "paused" or .status == "deferred" or .status == "checkpoint_requested")
            then .status = "active" | .resumed_at = $now | del(.deferred_prompt) else . end'
      fi
      ;;
    Stop)
      lg_session_ensure "$input"
      if [ "$mode" = "paused" ]; then lg_hook_stop "$id"
      else lg_session_update "$id" --argjson now "$(lg_now)" '.last_seen = $now'; fi
      ;;
    SessionEnd)
      [ -s "$(lg_session_file "$id")" ] && lg_hook_sessionend "$id"
      ;;
  esac
  return 0
}
