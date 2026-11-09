# shellcheck shell=bash
# Usage sources, normalised to one record shape:
# {
#   "source": "statusline|stream|api|estimate|cache",
#   "confidence": "high|low",
#   "observed_at": <epoch>,
#   "five_hour": {"pct": <0-100>, "resets_at": <epoch|null>} | null,
#   "seven_day": {"pct": <0-100>, "resets_at": <epoch|null>} | null
# }
# A window whose resets_at has passed is reported as pct 0 (it has rolled over).

LG_JQ_ROLL='def roll($now):
  if . == null then null
  elif (.resets_at != null and .resets_at <= $now) then {pct: 0, resets_at: null, rolled: true}
  else . end;'

# raw statusline `rate_limits` object on stdin -> normalised record
lg_norm_statusline() {
  local now="$1"
  jq -c --argjson now "$now" "$LG_JQ_TO_EPOCH $LG_JQ_ROLL"'
    def win(w): if w == null or w.used_percentage == null then null
      else {pct: (w.used_percentage | tonumber | . * 100 | round / 100), resets_at: (w.resets_at | to_epoch)} | roll($now) end;
    {source: "statusline", confidence: "high", observed_at: $now,
     five_hour: win(.five_hour), seven_day: win(.seven_day)}'
}

# `rate_limit_event.rate_limit_info` on stdin -> normalised record (utilization is a 0-1 fraction)
lg_norm_stream() {
  local now="$1"
  jq -c --argjson now "$now" "$LG_JQ_TO_EPOCH $LG_JQ_ROLL"'
    def win(w): if w == null or w.utilization == null then null
      else {pct: ((w.utilization | tonumber) * 100 | . * 100 | round / 100), resets_at: (w.resetsAt | to_epoch)} | roll($now) end;
    {source: "stream", confidence: "high", observed_at: $now,
     five_hour: win(.unifiedWindows.five_hour), seven_day: win(.unifiedWindows.seven_day)}'
}

# /api/oauth/usage body on stdin -> normalised record (utilization is already a percentage)
lg_norm_api() {
  local now="$1"
  jq -c --argjson now "$now" "$LG_JQ_TO_EPOCH $LG_JQ_ROLL"'
    def win(w): if w == null or w.utilization == null then null
      else {pct: (w.utilization | tonumber | . * 100 | round / 100), resets_at: (w.resets_at | to_epoch)} | roll($now) end;
    {source: "api", confidence: "high", observed_at: $now,
     five_hour: win(.five_hour), seven_day: win(.seven_day)}'
}

# Re-apply the rollover rule to a stored record at a later time.
lg_reroll() {
  local now="$1"
  jq -c --argjson now "$now" "$LG_JQ_ROLL"'.five_hour |= roll($now) | .seven_day |= roll($now)'
}

# Wake the daemon immediately when a fresh sample crosses a threshold while running.
lg_wake_if_over() {
  [ "$(lg_state_mode)" = "running" ] || return 0
  jq -e --argjson p5 "$LG_PAUSE_5H" --argjson p7 "$LG_PAUSE_7D" \
    '((.five_hour.pct // 0) >= $p5) or ((.seven_day.pct // 0) >= $p7)' "$1" >/dev/null 2>&1 \
    && touch "$LG_HOME/.wake"
  return 0
}

# ---- statusline ---------------------------------------------------------------

# Statusline entrypoint: record the sample, then print a status line.
lg_statusline() {
  local input now rl state_line chain_out
  input="$(cat)"
  now="$(lg_now)"
  rl="$(printf '%s' "$input" | jq -c '.rate_limits // empty' 2>/dev/null)"
  if [ -n "$rl" ] && [ "$rl" != "{}" ]; then
    printf '%s' "$rl" | lg_norm_statusline "$now" | lg_write "$LG_HOME/samples/statusline.json" 2>/dev/null
    lg_wake_if_over "$LG_HOME/samples/statusline.json"
  fi
  state_line="$(lg_status_short)"
  if [ -n "$LG_STATUSLINE_CHAIN" ]; then
    chain_out="$(printf '%s' "$input" | sh -c "$LG_STATUSLINE_CHAIN" 2>/dev/null | head -1)"
    [ -n "$chain_out" ] && { printf '%s │ %s\n' "$chain_out" "$state_line"; return; }
  fi
  printf '%s\n' "$state_line"
}

# ---- headless stream-json ingest --------------------------------------------

# Pass stream-json through unchanged, capturing rate_limit_event samples.
lg_ingest_stream() {
  local line info
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    case "$line" in
      *'"rate_limit_event"'*)
        info="$(printf '%s' "$line" | jq -c 'select(.type == "rate_limit_event") | .rate_limit_info // empty' 2>/dev/null)"
        if [ -n "$info" ]; then
          printf '%s' "$info" | lg_norm_stream "$(lg_now)" | lg_write "$LG_HOME/samples/stream.json" 2>/dev/null
          lg_wake_if_over "$LG_HOME/samples/stream.json"
        fi
        ;;
    esac
  done
}

# ---- /api/oauth/usage --------------------------------------------------------

# Best claude.ai OAuth credential object (Keychain or ~/.claude/.credentials.json,
# whichever expires last). Printed only into a pipe; never stored or logged.
lg_creds_json() {
  {
    security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null
    cat "$HOME/.claude/.credentials.json" 2>/dev/null
  } | jq -cs '[.[] | .claudeAiOauth? // empty | select(.accessToken != null)] | max_by(.expiresAt // 0) // empty' 2>/dev/null
}

lg_api_meta() { cat "$LG_HOME/samples/api.meta.json" 2>/dev/null || echo '{}'; }

# Prints the raw body on success. Return codes:
# 0 ok, 3 token missing/expired (never refreshed here), 4 throttled/backing off, 5 http/network error
lg_api_fetch() {
  local now meta last backoff exp out code body
  now="$(lg_now)"
  meta="$(lg_api_meta)"
  last="$(printf '%s' "$meta" | jq -r '.last_call // 0')"
  backoff="$(printf '%s' "$meta" | jq -r '.backoff_until // 0')"
  if [ $((now - last)) -lt "$LG_API_MIN_INTERVAL" ] || [ "$now" -lt "$backoff" ]; then
    return 4
  fi
  exp="$(lg_creds_json | jq -r '.expiresAt // 0')"
  exp="${exp:-0}"
  if [ $((exp / 1000)) -le $((now + 30)) ]; then
    lg_jq_update "$LG_HOME/samples/api.meta.json" --argjson now "$now" '.last_status = "token_expired" | .last_status_at = $now'
    return 3
  fi
  out="$(lg_creds_json \
    | jq -r '"header = \"Authorization: Bearer " + .accessToken + "\""' \
    | curl -sS -K - --max-time 15 \
        -H 'anthropic-beta: oauth-2025-04-20' -H 'Accept: application/json' \
        -w '\n%{http_code}' "$LG_API_URL" 2>/dev/null)"
  code="$(printf '%s' "$out" | tail -n 1)"
  body="$(printf '%s' "$out" | sed '$d')"
  case "$code" in
    200)
      lg_jq_update "$LG_HOME/samples/api.meta.json" --argjson now "$now" '.last_call = $now | .last_status = "ok" | .last_status_at = $now'
      printf '%s' "$body"; return 0 ;;
    401|403)
      lg_jq_update "$LG_HOME/samples/api.meta.json" --argjson now "$now" --arg c "$code" '.last_call = $now | .last_status = ("http_" + $c) | .last_status_at = $now'
      return 3 ;;
    429)
      lg_jq_update "$LG_HOME/samples/api.meta.json" --argjson now "$now" '.last_call = $now | .last_status = "http_429" | .last_status_at = $now | .backoff_until = ($now + 600)'
      return 4 ;;
    *)
      lg_jq_update "$LG_HOME/samples/api.meta.json" --argjson now "$now" --arg c "${code:-none}" '.last_call = $now | .last_status = ("http_" + $c) | .last_status_at = $now | .backoff_until = ($now + 120)'
      return 5 ;;
  esac
}

# ---- transcript estimate (low confidence) -------------------------------------

# Weighted tokens from local transcripts since $1 (epoch), de-duplicated by message id.
lg_estimate_tokens() {
  local start="$1" now mins
  now="$(lg_now)"
  mins=$(( (now - start) / 60 + 2 ))
  [ -d "$LG_PROJECTS_DIR" ] || { echo 0; return; }
  find "$LG_PROJECTS_DIR" -type f -name '*.jsonl' -mmin "-$mins" -print0 2>/dev/null \
    | xargs -0 cat 2>/dev/null \
    | jq -rR --argjson start "$start" "$LG_JQ_TO_EPOCH"'
        fromjson? // empty
        | select(.type == "assistant" and .message.usage != null and .message.id != null)
        | select((.timestamp | to_epoch) >= $start)
        | .message.usage as $u
        | [.message.id, (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0)
                         + ($u.output_tokens // 0) + (($u.cache_read_input_tokens // 0) * 0.1))]
        | @tsv' 2>/dev/null \
    | awk -F'\t' '!seen[$1]++ { s += $2 } END { printf "%d\n", s + 0 }'
}

# Learn tokens-per-100% for the 5h window from a high-confidence record.
lg_calibrate() {
  local rec="$1" now pct resets last tokens
  [ "$LG_ESTIMATE" = "1" ] || return 0
  now="$(lg_now)"
  pct="$(printf '%s' "$rec" | jq -r '.five_hour.pct // 0 | floor')"
  resets="$(printf '%s' "$rec" | jq -r '.five_hour.resets_at // empty')"
  [ -n "$resets" ] && [ "$pct" -ge 10 ] || return 0
  last="$(jq -r '.updated_at // 0' "$LG_HOME/calibration.json" 2>/dev/null || echo 0)"
  [ $((now - ${last:-0})) -ge "$LG_CALIBRATE_EVERY" ] || return 0
  tokens="$(lg_estimate_tokens $((resets - 18000)))"
  [ "${tokens:-0}" -gt 0 ] || return 0
  lg_jq_update "$LG_HOME/calibration.json" --argjson now "$now" --argjson t "$tokens" --argjson p "$pct" '
    ($t * 100 / $p) as $c
    | .ceiling_5h = (if .ceiling_5h then ((.ceiling_5h + $c) / 2) else $c end | floor)
    | .samples = ((.samples // 0) + 1) | .updated_at = $now'
  lg_log "calibrated 5h ceiling: tokens=$tokens pct=$pct -> $(jq -r .ceiling_5h "$LG_HOME/calibration.json")"
}

# Low-confidence record from transcripts, or nothing if uncalibrated.
lg_estimate_record() {
  local now prev ceiling tokens
  [ "$LG_ESTIMATE" = "1" ] || return 1
  ceiling="$(jq -r '.ceiling_5h // empty' "$LG_HOME/calibration.json" 2>/dev/null)"
  [ -n "$ceiling" ] && [ "$ceiling" -gt 0 ] || return 1
  now="$(lg_now)"
  prev="$(cat "$LG_HOME/usage.json" 2>/dev/null || echo '{}')"
  # Window start: the known 5h window if still current, else a rolling 5h.
  local start
  start="$(printf '%s' "$prev" | jq -r --argjson now "$now" \
    'if (.five_hour.resets_at // 0) > $now then .five_hour.resets_at - 18000 else $now - 18000 end')"
  tokens="$(lg_estimate_tokens "$start")"
  printf '%s' "$prev" | jq -c --argjson now "$now" --argjson t "${tokens:-0}" --argjson c "$ceiling" "$LG_JQ_ROLL"'
    {source: "estimate", confidence: "low", observed_at: $now, tokens_5h: $t, ceiling_5h: $c,
     five_hour: {pct: (($t * 10000 / $c) | round / 100),
                 resets_at: (if (.five_hour.resets_at // 0) > $now then .five_hour.resets_at else null end)},
     seven_day: (.seven_day | roll($now))}'
}

# ---- refresh: pick the best available source -----------------------------------

lg_newest_sample() {
  local f best='' best_t=0 t
  for f in "$LG_HOME/samples/statusline.json" "$LG_HOME/samples/stream.json"; do
    [ -s "$f" ] || continue
    t="$(jq -r '.observed_at // 0' "$f" 2>/dev/null)"
    if [ "${t:-0}" -gt "$best_t" ]; then best_t="$t"; best="$f"; fi
  done
  [ -n "$best" ] && cat "$best"
}

# Refresh usage.json and print it. Calls the API at most once.
lg_usage_refresh() {
  local now sample sample_t rec='' body rc prev
  now="$(lg_now)"
  prev="$(cat "$LG_HOME/usage.json" 2>/dev/null)"
  sample="$(lg_newest_sample)"
  sample_t=0
  [ -n "$sample" ] && sample_t="$(printf '%s' "$sample" | jq -r '.observed_at // 0')"

  if [ -n "$sample" ] && [ $((now - sample_t)) -le "$LG_SAMPLE_MAX_AGE" ]; then
    rec="$(printf '%s' "$sample" | lg_reroll "$now")"
  else
    body="$(lg_api_fetch)"; rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$body" ]; then
      rec="$(printf '%s' "$body" | lg_norm_api "$now")"
    else
      [ "$rc" -ne 4 ] && lg_log "usage api unavailable (rc=$rc)"
      if [ -n "$sample" ] && [ -n "$prev" ] && [ "$sample_t" -gt "$(printf '%s' "$prev" | jq -r '.observed_at // 0')" ]; then
        rec="$(printf '%s' "$sample" | lg_reroll "$now")"
      elif [ -n "$prev" ] && [ "$(printf '%s' "$prev" | jq -r .confidence)" = "high" ] \
           && [ $((now - $(printf '%s' "$prev" | jq -r '.observed_at // 0'))) -le $((LG_SAMPLE_MAX_AGE * 3)) ]; then
        rec="$(printf '%s' "$prev" | jq -c '.source = "cache"' | lg_reroll "$now")"
      else
        rec="$(lg_estimate_record)" || rec=''
        if [ -z "$rec" ] && [ -n "$prev" ]; then
          rec="$(printf '%s' "$prev" | jq -c 'if .source == "cache" then . else .source = "cache" end' | lg_reroll "$now")"
        fi
      fi
    fi
  fi

  [ -n "$rec" ] || return 1
  # Fill a window missing from the new record with the previous one if still current.
  if [ -n "$prev" ]; then
    rec="$(jq -cn --argjson r "$rec" --argjson p "$prev" --argjson now "$now" "$LG_JQ_ROLL"'
      $r | .five_hour = (.five_hour // ($p.five_hour | roll($now)))
         | .seven_day = (.seven_day // ($p.seven_day | roll($now)))')"
  fi
  rec="$(printf '%s' "$rec" | jq -c --argjson now "$now" --argjson max "$LG_SAMPLE_MAX_AGE" \
    '.stale = (($now - .observed_at) > ($max * 3)) | .checked_at = $now')"
  printf '%s\n' "$rec" | lg_write "$LG_HOME/usage.json"
  [ "$(printf '%s' "$rec" | jq -r .confidence)" = "high" ] && \
    [ "$(printf '%s' "$rec" | jq -r .source)" != "cache" ] && lg_calibrate "$rec"
  printf '%s\n' "$rec"
}
