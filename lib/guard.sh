# shellcheck shell=bash
# Global guard state, the pause/resume decision, and the daemon loop.
# state.json: {mode: running|paused, manual, reason, tripped, paused_at, resume_at, updated_at}

lg_state() {
  local s
  s="$(cat "$LG_HOME/state.json" 2>/dev/null)"
  [ -n "$s" ] && printf '%s\n' "$s" || echo '{"mode":"running"}'
}

lg_state_mode() { lg_state | jq -r '.mode // "running"' 2>/dev/null || echo running; }

lg_state_set() {
  lg_jq_update "$LG_HOME/state.json" --argjson now "$(lg_now)" "$@"
}

# Pure decision. Inputs: usage record, state, now. Output:
# {action: none|pause|extend|resume, resume_at, reason, tripped, next}
lg_decide() {
  local usage="$1" state="$2" now="$3"
  jq -cn --argjson u "${usage:-null}" --argjson s "$state" --argjson now "$now" \
    --argjson p5 "$LG_PAUSE_5H" --argjson p7 "$LG_PAUSE_7D" --argjson grace "$LG_RESUME_GRACE" \
    --argjson hbmin "$LG_HB_MIN" --argjson hbmax "$LG_HB_MAX" '
    def thresholds: {five_hour: $p5, seven_day: $p7};
    def tripped: if $u == null then [] else
      [ thresholds | to_entries[] | . as $t
        | ($u[$t.key]) as $w
        | select($w != null and ($w.pct // 0) >= $t.value)
        | {window: $t.key, pct: $w.pct, resets_at: $w.resets_at} ] end;
    def until_for($tr): ([ $tr[] | (if .resets_at == null then $now + 1800 - $grace else .resets_at end) ] | max) + $grace;
    def reason_for($tr): ([ $tr[] | "\(.window | sub("_hour"; "h") | sub("seven_day"; "7d") | sub("five"; "5")) \(.pct)%" ] | join(", "));
    def gap: if $u == null then 0 else
      ([ ($p5 - ($u.five_hour.pct // 0)), ($p7 - ($u.seven_day.pct // 0)) ] | min) end;
    def running_next:
      (gap) as $g
      | (if $g >= 40 then $hbmax elif $g >= 25 then 600 elif $g >= 15 then 300 elif $g >= 8 then 120 else $hbmin end)
      | (if ($u == null or $u.confidence != "high") then ([., 120] | min) else . end)
      | ([[., $hbmax] | min, $hbmin] | max);
    def paused_next($at): ([[($at - $now), $hbmax] | min, $hbmin] | max);
    tripped as $tr
    | if ($s.mode // "running") != "paused" then
        if ($tr | length) > 0 then
          until_for($tr) as $at
          | {action: "pause", resume_at: $at, reason: reason_for($tr), tripped: $tr, next: paused_next($at)}
        else {action: "none", next: running_next} end
      elif ($s.manual // false) then {action: "none", next: $hbmax}
      elif $now < ($s.resume_at // 0) then
        (if ($tr | length) > 0 and until_for($tr) > $s.resume_at
         then {action: "extend", resume_at: until_for($tr), reason: reason_for($tr), tripped: $tr}
         else {action: "none"} end)
        | .next = paused_next(.resume_at // $s.resume_at)
      else
        # Reset time reached. Trust fresh high-confidence data observed after the reset;
        # otherwise trust the clock (the tripped window has rolled over).
        (($u != null) and ($u.confidence == "high") and ($u.source != "cache")
          and (($u.observed_at // 0) >= (($s.resume_at // 0) - $grace))) as $fresh
        | if $fresh and ($tr | length) > 0 and ([ $tr[] | (.resets_at // 0) > $now ] | any)
          then until_for($tr) as $at | {action: "extend", resume_at: $at, reason: reason_for($tr), tripped: $tr, next: paused_next($at)}
          else {action: "resume", next: $hbmin} end
      end'
}

lg_pause() {
  local reason="$1" resume_at="$2" manual="${3:-false}" tripped="${4:-[]}"
  lg_state_set --arg r "$reason" --argjson at "${resume_at:-null}" --argjson m "$manual" --argjson tr "$tripped" '
    .mode = "paused" | .manual = $m | .reason = $r | .tripped = $tr
    | .paused_at = $now | .resume_at = $at | .updated_at = $now'
  lg_log "PAUSE ($reason) until $(lg_fmt_time "$resume_at")"
  lg_notify "Pausing agents: $reason. Resume at $(lg_fmt_time "$resume_at")."
}

lg_resume_all() {
  local why="$1" id rc manual_list='' ok=0 failed=0
  lg_state_set '.mode = "running" | .manual = false | .resumed_at = $now | .updated_at = $now | del(.resume_at)'
  lg_log "RESUME ($why)"
  for id in $(lg_sessions_with_status checkpoint_requested paused deferred); do
    lg_resume_session "$id"; rc=$?
    case "$rc" in
      0) ok=$((ok + 1)) ;;
      3) manual_list="$manual_list $(lg_session_get "$id" | jq -r '(.cwd // "?") | split("/") | last')" ;;
      *) failed=$((failed + 1)) ;;
    esac
  done
  local msg="Limits reset ($why). Resumed $ok agent(s)."
  [ -n "$manual_list" ] && msg="$msg Continue manually:$manual_list."
  [ "$failed" -gt 0 ] && msg="$msg $failed will retry."
  lg_notify "$msg"
}

# Retry sessions whose resume could not run yet (e.g. headless process still exiting).
lg_resume_retry() {
  local id
  [ "$(lg_state_mode)" = "running" ] || return 0
  for id in $(lg_sessions_with_status checkpoint_requested paused deferred); do
    lg_resume_session "$id" >/dev/null 2>&1
  done
}

# One supervision step. Prints the next heartbeat in seconds.
lg_tick() {
  local usage state now decision action
  usage="$(lg_usage_refresh 2>/dev/null)" || usage=''
  [ -n "$usage" ] || usage='null'
  state="$(lg_state)"
  now="$(lg_now)"
  decision="$(lg_decide "$usage" "$state" "$now")" || decision='{"action":"none","next":120}'
  action="$(printf '%s' "$decision" | jq -r .action)"
  case "$action" in
    pause)
      lg_pause "$(printf '%s' "$decision" | jq -r .reason)" "$(printf '%s' "$decision" | jq -r .resume_at)" false \
        "$(printf '%s' "$decision" | jq -c .tripped)" ;;
    extend)
      lg_state_set --argjson at "$(printf '%s' "$decision" | jq .resume_at)" --arg r "$(printf '%s' "$decision" | jq -r .reason)" \
        '.resume_at = $at | .reason = $r | .updated_at = $now'
      lg_log "EXTEND pause until $(lg_fmt_time "$(printf '%s' "$decision" | jq -r .resume_at)") ($(printf '%s' "$decision" | jq -r .reason))" ;;
    resume)
      lg_resume_all "reset reached" ;;
    *)
      lg_resume_retry ;;
  esac
  lg_jq_update "$LG_HOME/daemon.json" --argjson now "$now" --argjson d "$decision" --argjson pid "$$" \
    '.last_tick = $now | .last_decision = $d | .pid = $pid | .next_tick = ($now + $d.next)'
  printf '%s' "$decision" | jq -r '.next // 120'
}

lg_daemon() {
  local next
  LG_COMPONENT=daemon
  if ! lg_lock daemon; then lg_die "another daemon is running (pid $(cat "$LG_HOME/.daemon.lock/pid" 2>/dev/null))"; fi
  trap 'lg_unlock daemon; lg_log "daemon stopped"; exit 0' INT TERM
  trap 'lg_unlock daemon' EXIT
  lg_log "daemon started (pid $$, pause at 5h>=${LG_PAUSE_5H}% 7d>=${LG_PAUSE_7D}%)"
  lg_sessions_gc
  while :; do
    lg_load_config
    next="$(lg_tick)"
    case "$next" in ''|*[!0-9]*) next=120 ;; esac
    # Sleep in short steps so a `limit-guard poke` (touching .wake) is honoured quickly.
    local slept=0
    while [ "$slept" -lt "$next" ]; do
      sleep 5; slept=$((slept + 5))
      if [ -f "$LG_HOME/.wake" ]; then rm -f "$LG_HOME/.wake"; break; fi
    done
  done
}
