# shellcheck shell=bash
R5=1794255000
R7=1794621600

usage_rec() { # 5h pct, 7d pct, [observed_at], [source]
  jq -cn --argjson a "$1" --argjson b "$2" --argjson o "${3:-$LG_NOW}" --arg s "${4:-api}" --argjson r5 "$R5" --argjson r7 "$R7" \
    '{source: $s, confidence: "high", observed_at: $o, five_hour: {pct: $a, resets_at: $r5}, seven_day: {pct: $b, resets_at: $r7}}'
}

test_below_thresholds_keeps_running_with_slow_heartbeat_when_far_away() {
  local d
  d="$(lg_decide "$(usage_rec 20 10)" '{"mode":"running"}' "$LG_NOW")"
  assert_eq "$(jqv "$d" .action)" "none"
  assert_eq "$(jqv "$d" .next)" "900"
}

test_heartbeat_tightens_as_usage_approaches_the_threshold() {
  assert_eq "$(jqv "$(lg_decide "$(usage_rec 75 10)" '{"mode":"running"}' "$LG_NOW")" .next)" "300"
  assert_eq "$(jqv "$(lg_decide "$(usage_rec 85 10)" '{"mode":"running"}' "$LG_NOW")" .next)" "120"
  assert_eq "$(jqv "$(lg_decide "$(usage_rec 90 10)" '{"mode":"running"}' "$LG_NOW")" .next)" "60"
  assert_eq "$(jqv "$(lg_decide "$(usage_rec 20 90)" '{"mode":"running"}' "$LG_NOW")" .next)" "60"
  # no data: check again soon
  assert_eq "$(jqv "$(lg_decide null '{"mode":"running"}' "$LG_NOW")" .next)" "60"
}

test_five_hour_at_threshold_pauses_until_its_reset_plus_grace() {
  local d
  d="$(lg_decide "$(usage_rec 95 50)" '{"mode":"running"}' "$LG_NOW")"
  assert_eq "$(jqv "$d" .action)" "pause"
  assert_eq "$(jqv "$d" .resume_at)" "$((R5 + 120))"
  assert_eq "$(jqv "$d" .reason)" "5h 95%"
}

test_both_windows_tripped_waits_for_the_later_reset() {
  local d
  d="$(lg_decide "$(usage_rec 95 96)" '{"mode":"running"}' "$LG_NOW")"
  assert_eq "$(jqv "$d" .resume_at)" "$((R7 + 120))"
  assert_eq "$(jqv "$d" .reason)" "5h 95%, 7d 96%"
}

test_paused_before_reset_waits_and_sleeps_until_then() {
  local st d
  st="{\"mode\":\"paused\",\"resume_at\":$((R5 + 120))}"
  d="$(lg_decide "$(usage_rec 91 50)" "$st" "$LG_NOW")"
  assert_eq "$(jqv "$d" .action)" "none"
  assert_eq "$(jqv "$d" .next)" "900"
  d="$(lg_decide "$(usage_rec 91 50)" "$st" $((R5 + 100)))"
  assert_eq "$(jqv "$d" .next)" "60"
}

test_weekly_tripping_during_a_five_hour_pause_extends_it() {
  local d
  d="$(lg_decide "$(usage_rec 91 97)" "{\"mode\":\"paused\",\"resume_at\":$((R5 + 120))}" "$LG_NOW")"
  assert_eq "$(jqv "$d" .action)" "extend"
  assert_eq "$(jqv "$d" .resume_at)" "$((R7 + 120))"
}

test_after_reset_without_fresh_data_the_clock_is_trusted() {
  local d
  # last reading is from before the reset (observed at LG_NOW), now is after resume_at
  d="$(lg_decide "$(usage_rec 91 50 "$LG_NOW" cache)" "{\"mode\":\"paused\",\"resume_at\":$((R5 + 120))}" $((R5 + 130)))"
  assert_eq "$(jqv "$d" .action)" "resume"
}

test_after_reset_fresh_data_still_over_with_a_future_reset_extends() {
  local d u
  u="$(jq -cn --argjson o $((R5 + 125)) --argjson r7 "$R7" \
    '{source: "api", confidence: "high", observed_at: $o, five_hour: {pct: 3, resets_at: null}, seven_day: {pct: 96, resets_at: $r7}}')"
  d="$(LG_PAUSE_7D=95 lg_decide "$u" "{\"mode\":\"paused\",\"resume_at\":$((R5 + 120))}" $((R5 + 130)))"
  assert_eq "$(jqv "$d" .action)" "extend"
  assert_eq "$(jqv "$d" .resume_at)" "$((R7 + 120))"
}

test_after_reset_fresh_data_below_threshold_resumes() {
  local d u
  u="$(jq -cn --argjson o $((R5 + 125)) '{source: "api", confidence: "high", observed_at: $o, five_hour: {pct: 0, resets_at: null}, seven_day: {pct: 51, resets_at: null}}')"
  d="$(lg_decide "$u" "{\"mode\":\"paused\",\"resume_at\":$((R5 + 120))}" $((R5 + 130)))"
  assert_eq "$(jqv "$d" .action)" "resume"
}

test_manual_pause_never_auto_resumes() {
  local d
  d="$(lg_decide "$(usage_rec 1 1)" '{"mode":"paused","manual":true,"resume_at":null}' $((R7 + 99999)))"
  assert_eq "$(jqv "$d" .action)" "none"
}

test_unknown_reset_time_rechecks_in_thirty_minutes() {
  local d u
  u='{"source":"estimate","confidence":"low","observed_at":1794247000,"five_hour":{"pct":96,"resets_at":null},"seven_day":null}'
  d="$(lg_decide "$u" '{"mode":"running"}' "$LG_NOW")"
  assert_eq "$(jqv "$d" .action)" "pause"
  assert_eq "$(jqv "$d" .resume_at)" "$((LG_NOW + 1800))"
}

test_five_hour_pauses_at_95_by_default_not_90() {
  assert_eq "$LG_PAUSE_5H" "95"
  assert_eq "$(jqv "$(lg_decide "$(usage_rec 94 50)" '{"mode":"running"}' "$LG_NOW")" .action)" "none"
}
