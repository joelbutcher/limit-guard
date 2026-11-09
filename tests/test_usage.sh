# shellcheck shell=bash
R5=1794255000   # 2026-11-09T20:10:00Z
R7=1794621600   # 2026-11-14T02:00:00Z

test_statusline_epoch_and_iso_resets_normalise_to_epoch() {
  local a b
  a="$(echo "{\"five_hour\":{\"used_percentage\":23.5,\"resets_at\":$R5}}" | lg_norm_statusline "$LG_NOW")"
  b="$(echo '{"five_hour":{"used_percentage":23.5,"resets_at":"2026-11-09T20:10:00.847069+00:00"}}' | lg_norm_statusline "$LG_NOW")"
  assert_eq "$(jqv "$a" .five_hour.resets_at)" "$R5"
  assert_eq "$(jqv "$b" .five_hour.resets_at)" "$R5"
  assert_eq "$(jqv "$a" .five_hour.pct)" "23.5"
  assert_eq "$(jqv "$a" .seven_day)" "null"
  # millisecond epochs and non-UTC offsets also land on the same instant
  b="$(echo "{\"five_hour\":{\"used_percentage\":1,\"resets_at\":${R5}000}}" | lg_norm_statusline "$LG_NOW")"
  assert_eq "$(jqv "$b" .five_hour.resets_at)" "$R5"
  b="$(echo '{"five_hour":{"used_percentage":1,"resets_at":"2026-11-09T21:10:00+01:00"}}' | lg_norm_statusline "$LG_NOW")"
  assert_eq "$(jqv "$b" .five_hour.resets_at)" "$R5"
}

test_stream_event_utilization_fraction_becomes_percent() {
  local r
  r="$(echo "{\"unifiedWindows\":{\"five_hour\":{\"utilization\":0.36,\"resetsAt\":$R5},\"seven_day\":{\"utilization\":0.11,\"resetsAt\":$R7}}}" | lg_norm_stream "$LG_NOW")"
  assert_eq "$(jqv "$r" .five_hour.pct)" "36"
  assert_eq "$(jqv "$r" .seven_day.pct)" "11"
  assert_eq "$(jqv "$r" .source)" "stream"
}

test_a_window_whose_reset_has_passed_reads_as_zero() {
  local r
  r="$(api_body 99 "2026-11-09T17:00:00Z" 40 "2026-11-14T02:00:00Z" | lg_norm_api "$LG_NOW")"
  assert_eq "$(jqv "$r" .five_hour.pct)" "0"
  assert_eq "$(jqv "$r" .five_hour.rolled)" "true"
  assert_eq "$(jqv "$r" .seven_day.pct)" "40"
}

test_fresh_statusline_sample_is_used_without_calling_the_api() {
  set_token $((LG_NOW + 3600)); set_api "$(api_body 10 x 10 x)"
  statusline_input 55 "$R5" 20 "$R7" | "$LG" statusline >/dev/null
  local r; r="$(lg_usage_refresh)"
  assert_eq "$(jqv "$r" .source)" "statusline"
  assert_eq "$(jqv "$r" .five_hour.pct)" "55"
  assert_not_contains "$(cat "$STUB_LOG")" "curl" "api must not be called"
}

test_stale_sample_falls_back_to_one_api_call_with_token_on_stdin_only() {
  set_token $((LG_NOW + 3600))
  set_api "$(api_body 37.0 "2026-11-09T20:10:00.847069+00:00" 12.0 "2026-11-14T02:00:00.847089+00:00")"
  statusline_input 55 "$R5" 20 "$R7" | LG_NOW=$((LG_NOW - 1000)) "$LG" statusline >/dev/null
  local r; r="$(lg_usage_refresh)"
  assert_eq "$(jqv "$r" .source)" "api"
  assert_eq "$(jqv "$r" .five_hour.pct)" "37"
  assert_eq "$(jqv "$r" .five_hour.resets_at)" "$R5"
  assert_eq "$(grep -c '^curl ARGS' "$STUB_LOG")" "1"
  assert_not_contains "$(grep '^curl ARGS' "$STUB_LOG")" "SECRET" "token must not be in curl argv"
  assert_contains "$(cat "$STUB_DIR/curl.stdin")" "Bearer sk-ant-oat-SECRET-TOKEN"
  assert_contains "$(grep '^curl ARGS' "$STUB_LOG")" "anthropic-beta: oauth-2025-04-20"
  assert_not_contains "$(cat "$LG_HOME"/*.json "$LG_HOME"/samples/* "$LG_HOME/limit-guard.log" 2>/dev/null)" "SECRET" "token must not be persisted"
}

test_api_is_called_at_most_once_per_interval() {
  set_token $((LG_NOW + 3600)); set_api "$(api_body 37 "2026-11-09T20:10:00Z" 12 "2026-11-14T02:00:00Z")"
  lg_usage_refresh >/dev/null
  LG_NOW=$((LG_NOW + 30)) lg_usage_refresh >/dev/null
  assert_eq "$(grep -c '^curl ARGS' "$STUB_LOG")" "1"
  LG_NOW=$((LG_NOW + 61)) lg_usage_refresh >/dev/null
  assert_eq "$(grep -c '^curl ARGS' "$STUB_LOG")" "2"
}

test_expired_token_is_never_used_or_refreshed() {
  set_token $((LG_NOW - 10)); set_api "$(api_body 37 x 12 x)"
  local r; r="$(lg_usage_refresh)"
  assert_not_contains "$(cat "$STUB_LOG")" "curl" "expired token must not hit the api"
  assert_eq "$(jq -r .last_status "$LG_HOME/samples/api.meta.json")" "token_expired"
  assert_empty "$r" "no source available yet"
}

test_expired_token_falls_back_to_the_last_good_reading() {
  set_token $((LG_NOW + 3600)); set_api "$(api_body 50 "2026-11-09T20:10:00Z" 12 "2026-11-14T02:00:00Z")"
  lg_usage_refresh >/dev/null
  set_token $((LG_NOW - 10))
  local r; r="$(LG_NOW=$((LG_NOW + 120)) lg_usage_refresh)"
  assert_eq "$(jqv "$r" .source)" "cache"
  assert_eq "$(jqv "$r" .five_hour.pct)" "50"
}

test_http_429_backs_off() {
  set_token $((LG_NOW + 3600)); set_api '{"error":"rate"}' 429
  lg_usage_refresh >/dev/null
  LG_NOW=$((LG_NOW + 300)) lg_usage_refresh >/dev/null
  assert_eq "$(grep -c '^curl ARGS' "$STUB_LOG")" "1"
}

test_stream_ingest_passes_through_and_records_usage() {
  local out
  out="$(printf '%s\n%s\n' '{"type":"system"}' \
    "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"unifiedWindows\":{\"five_hour\":{\"utilization\":0.5,\"resetsAt\":$R5}}}}" \
    | "$LG" ingest-stream)"
  assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2"
  assert_eq "$(jq -r .five_hour.pct "$LG_HOME/samples/stream.json")" "50"
}

test_sample_over_threshold_wakes_the_daemon() {
  statusline_input 95 "$R5" 20 "$R7" | "$LG" statusline >/dev/null
  [ -f "$LG_HOME/.wake" ] || fail "expected .wake"
}

write_transcript() { # file, id, iso ts, input, output
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0}}}\n' \
    "$3" "$2" "$4" "$5" >> "$1"
}

test_estimate_dedupes_messages_and_uses_the_calibrated_ceiling() {
  local t="$LG_PROJECTS_DIR/p/x.jsonl"; mkdir -p "$(dirname "$t")"
  local ts; ts="$(date -u -r $((LG_NOW - 600)) +%Y-%m-%dT%H:%M:%S.000Z)"
  write_transcript "$t" m1 "$ts" 100 400
  write_transcript "$t" m1 "$ts" 100 400            # streaming duplicate
  write_transcript "$t" m2 "$ts" 0 400
  write_transcript "$t" old "2026-11-01T00:00:00Z" 99999 99999   # outside window
  echo 'not json' >> "$t"
  assert_eq "$(lg_estimate_tokens $((LG_NOW - 18000)))" "1100"  # 500+100 + 400+100
  echo '{"ceiling_5h": 11000, "updated_at": 0}' > "$LG_HOME/calibration.json"
  local r; r="$(lg_estimate_record)"
  assert_eq "$(jqv "$r" .confidence)" "low"
  assert_eq "$(jqv "$r" .five_hour.pct)" "10"
}

test_calibration_learns_tokens_per_percent() {
  local t="$LG_PROJECTS_DIR/p/x.jsonl"; mkdir -p "$(dirname "$t")"
  write_transcript "$t" m1 "$(date -u -r $((LG_NOW - 600)) +%Y-%m-%dT%H:%M:%SZ)" 1900 0
  lg_calibrate "{\"five_hour\":{\"pct\":20,\"resets_at\":$R5}}"
  assert_eq "$(jq -r .ceiling_5h "$LG_HOME/calibration.json")" "10000"
}
