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

# Only tmux and headless sessions can be driven from outside; desktop and plain terminal ones need the user.
lg_hook_auto_resumable() {
  case "$(lg_session_get "$1" | jq -r '.kind // "terminal"' 2>/dev/null)" in
    tmux|headless) return 0 ;;
    *) return 1 ;;
  esac
}

lg_hook_deny_reason() {
  local id="$1" cp after
  cp="$(lg_checkpoint_path "$id")"
  if lg_hook_auto_resumable "$id"; then
    after="limit-guard will resume this session automatically after the reset and point you at the checkpoint."
  else
    after="After the reset the user will continue this session, and limit-guard will point you at the checkpoint then."
  fi
  printf '%s' "limit-guard: work is paused to stay under the Claude plan usage limits. $(lg_hook_paused_context) \
Do NOT start or continue any other work. Your only remaining actions: (1) write a concise checkpoint to $cp with the Write tool \
covering the task goal, what is done, the exact next steps, files touched and any uncommitted or half-applied state; \
(2) end your turn immediately with a one-line summary. $after"
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
  local after
  if lg_hook_auto_resumable "$id"; then
    after="Your prompt was saved and will be sent to this session automatically after the reset."
  else
    after="Your prompt was saved. After the reset, send any message (e.g. \"continue\") and it will be handed to the agent with its checkpoint."
  fi
  jq -cn --arg r "limit-guard: paused to stay under the Claude plan usage limits. $(lg_hook_paused_context) \
$after To override now: limit-guard resume --force" '{decision: "block", reason: $r}'
}

# First prompt typed into a session that limit-guard paused: hand over the checkpoint and any saved prompt.
lg_hook_handover() {
  local id="$1" s
  s="$(lg_session_get "$id")"
  [ -n "$s" ] || return 0
  printf '%s' "$s" | jq -e '(.status | IN("paused","deferred","checkpoint_requested")) or .needs_manual == true' \
    >/dev/null 2>&1 || return 0
  jq -cn --arg c "$(lg_resume_prompt "$s")" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
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
        # Someone is driving the session again: hand over the checkpoint once, and drop any pending auto-resume.
        lg_hook_handover "$id"
        lg_session_update "$id" --argjson now "$(lg_now)" '
          .last_seen = $now | if (.status | IN("paused","deferred","checkpoint_requested")) or .needs_manual == true
            then .status = "active" | .resumed_at = $now | del(.deferred_prompt) | del(.needs_manual) else . end'
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
