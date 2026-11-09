# shellcheck shell=bash

make_session() { # id kind status [extra json]
  local extra="${4:-}"; [ -n "$extra" ] || extra='{}'
  mkdir -p "$TEST_ROOT/work"
  jq -cn --arg id "$1" --arg k "$2" --arg st "$3" --arg cwd "$TEST_ROOT/work" --argjson x "$extra" \
    '{session_id: $id, kind: $k, status: $st, cwd: $cwd, pid: 777, tmux_pane: "%3", tmux_socket: "/tmp/tmux-sock",
      transcript_path: ($cwd + "/t.jsonl"), argv: "/x/claude -p do-it --model opus --permission-mode acceptEdits --output-format stream-json --verbose --dangerously-skip-permissions --allowedTools Bash"} + $x' \
    > "$LG_HOME/sessions/$1.json"
}

test_tmux_session_gets_the_resume_prompt_typed_into_its_pane() {
  make_session t1 tmux paused
  echo "checkpoint" > "$LG_HOME/checkpoints/t1.md"
  LG_TEST_ALIVE=777 lg_resume_session t1
  assert_eq "$?" "0"
  local log; log="$(cat "$STUB_LOG")"
  assert_contains "$log" "tmux -S /tmp/tmux-sock send-keys -t %3 -l [limit-guard:resume]"
  assert_contains "$log" "Read your checkpoint at $LG_HOME/checkpoints/t1.md"
  assert_contains "$log" "send-keys -t %3 Enter"
  assert_eq "$(jqv "$(lg_session_get t1)" .status)" "active"
}

test_tmux_pane_whose_claude_exited_gets_a_resume_command() {
  make_session t1 tmux paused
  echo zsh > "$STUB_DIR/tmux.cmd"
  LG_TEST_ALIVE="" lg_resume_session t1
  assert_contains "$(cat "$STUB_LOG")" "claude --resume t1"
  assert_contains "$(cat "$STUB_LOG")" "cd $TEST_ROOT/work"
}

test_missing_tmux_pane_needs_a_human() {
  make_session t1 tmux paused
  touch "$STUB_DIR/tmux.nopane"
  LG_TEST_ALIVE=777 lg_resume_session t1
  assert_eq "$?" "3"
  assert_eq "$(jqv "$(lg_session_get t1)" .needs_manual)" "true"
}

test_headless_session_is_resumed_detached_with_its_original_flags() {
  make_session h1 headless paused
  echo '{"type":"assistant"}' > "$TEST_ROOT/work/t.jsonl"
  LG_TEST_ALIVE="" lg_resume_session h1
  assert_eq "$?" "0"
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do grep -q '^claude' "$STUB_LOG" && break; /bin/sleep 0.1; done
  local log; log="$(grep '^claude' "$STUB_LOG")"
  assert_contains "$log" "CWD=$TEST_ROOT/work"
  assert_contains "$log" "-p --resume h1 --model opus --permission-mode acceptEdits --output-format stream-json --verbose --dangerously-skip-permissions [limit-guard:resume]"
  assert_not_contains "$log" "do-it" "original prompt must not be replayed"
  assert_not_contains "$log" "allowedTools" "non-whitelisted flags are dropped"
}

test_headless_session_still_running_is_retried_not_duplicated() {
  make_session h1 headless checkpoint_requested
  LG_TEST_ALIVE=777 lg_resume_session h1
  assert_eq "$?" "2"
  assert_not_contains "$(cat "$STUB_LOG")" "claude CWD"
  assert_eq "$(jqv "$(lg_session_get h1)" .resume_attempts)" "1"
  assert_eq "$(jqv "$(lg_session_get h1)" .status)" "checkpoint_requested"
}

test_headless_blocked_before_its_first_turn_reruns_the_saved_prompt() {
  make_session h1 headless deferred '{"deferred_prompt":"write the report"}'
  LG_TEST_ALIVE="" lg_resume_session h1
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do grep -q '^claude' "$STUB_LOG" && break; /bin/sleep 0.1; done
  local log; log="$(grep '^claude' "$STUB_LOG")"
  assert_not_contains "$log" "--resume"
  assert_contains "$log" "write the report"
  assert_eq "$(jqv "$(lg_session_get h1)" .status)" "ended"
  assert_eq "$(jqv "$(lg_session_get h1)" .superseded)" "true"
}

test_desktop_and_plain_terminal_sessions_need_a_human() {
  make_session d1 desktop paused
  make_session p1 terminal paused
  lg_resume_session d1; assert_eq "$?" "3"
  lg_resume_session p1; assert_eq "$?" "3"
}

test_deferred_prompt_is_delivered_on_resume() {
  make_session t1 tmux deferred '{"deferred_prompt":"also bump the version"}'
  LG_TEST_ALIVE=777 lg_resume_session t1
  assert_contains "$(cat "$STUB_LOG")" "act on it now: also bump the version"
}
