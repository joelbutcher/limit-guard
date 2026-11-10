# shellcheck shell=bash

pause_now() { lg_pause "5h 91%" 1794255120 false '[]' >/dev/null; }

test_running_mode_hooks_are_silent() {
  local out
  out="$(hook_input PreToolUse s1 '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | run_hook)"
  assert_empty "$out"
  out="$(hook_input UserPromptSubmit s1 '{"prompt":"hi"}' | run_hook)"
  assert_empty "$out"
}

test_session_start_registers_kind_pid_and_tmux_pane() {
  TMUX="/private/tmp/tmux-502/default,123,0" TMUX_PANE="%7" LG_TEST_PID=4242 LG_TEST_ARGV="/x/claude --model opus" \
    run_hook < <(hook_input SessionStart s1 '{"source":"startup"}') >/dev/null
  local s; s="$(lg_session_get s1)"
  assert_eq "$(jqv "$s" .kind)" "tmux"
  assert_eq "$(jqv "$s" .pid)" "4242"
  assert_eq "$(jqv "$s" .tmux_pane)" "%7"
  assert_eq "$(jqv "$s" .tmux_socket)" "/private/tmp/tmux-502/default"
  assert_eq "$(jqv "$s" .status)" "active"
}

test_sessions_are_classified_by_command_line() {
  assert_eq "$(lg_classify '/x/claude -p do things --model haiku')" "headless"
  assert_eq "$(lg_classify '/x/claude --print hi')" "headless"
  assert_eq "$(lg_classify '/x/claude --output-format stream-json --verbose --input-format stream-json')" "desktop"
  assert_eq "$(TMUX_PANE=%1 lg_classify '/x/claude')" "tmux"
  assert_eq "$(lg_classify '/x/claude')" "terminal"
}

test_paused_pretooluse_denies_with_checkpoint_instructions() {
  pause_now
  local out
  out="$(hook_input PreToolUse s1 '{"tool_name":"Bash","tool_input":{"command":"make"}}' | run_hook)"
  assert_eq "$(jqv "$out" .hookSpecificOutput.hookEventName)" "PreToolUse"
  assert_eq "$(jqv "$out" .hookSpecificOutput.permissionDecision)" "deny"
  assert_contains "$(jqv "$out" .hookSpecificOutput.permissionDecisionReason)" "$LG_HOME/checkpoints/s1.md"
  assert_eq "$(jqv "$(lg_session_get s1)" .status)" "checkpoint_requested"
}

test_paused_pretooluse_allows_writing_the_checkpoint_and_todos() {
  pause_now
  local out
  out="$(hook_input PreToolUse s1 "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$LG_HOME/checkpoints/s1.md\"}}" | run_hook)"
  assert_empty "$out"
  out="$(hook_input PreToolUse s1 '{"tool_name":"TodoWrite","tool_input":{}}' | run_hook)"
  assert_empty "$out"
  out="$(hook_input PreToolUse s1 '{"tool_name":"Write","tool_input":{"file_path":"/tmp/elsewhere.md"}}' | run_hook)"
  assert_eq "$(jqv "$out" .hookSpecificOutput.permissionDecision)" "deny"
}

test_stop_marks_only_interrupted_sessions_as_paused() {
  hook_input SessionStart busy | run_hook >/dev/null
  hook_input SessionStart idle | run_hook >/dev/null
  pause_now
  hook_input PreToolUse busy '{"tool_name":"Bash"}' | run_hook >/dev/null
  hook_input Stop busy '{"stop_hook_active":false}' | run_hook >/dev/null
  hook_input Stop idle '{"stop_hook_active":false}' | run_hook >/dev/null
  assert_eq "$(jqv "$(lg_session_get busy)" .status)" "paused"
  assert_eq "$(jqv "$(lg_session_get idle)" .status)" "active"
}

test_prompts_while_paused_are_blocked_and_saved_but_resume_prompts_pass() {
  pause_now
  local out
  out="$(hook_input UserPromptSubmit s1 '{"prompt":"refactor the parser"}' | run_hook)"
  assert_eq "$(jqv "$out" .decision)" "block"
  assert_contains "$(jqv "$out" .reason)" "limit-guard resume --force"
  local s; s="$(lg_session_get s1)"
  assert_eq "$(jqv "$s" .status)" "deferred"
  assert_eq "$(jqv "$s" .deferred_prompt)" "refactor the parser"
  out="$(hook_input UserPromptSubmit s1 '{"prompt":"[limit-guard:resume] go on"}' | run_hook)"
  assert_empty "$out"
}

test_a_human_prompt_after_resume_cancels_the_pending_auto_resume() {
  hook_input SessionStart s1 | run_hook >/dev/null
  lg_session_update s1 '.status = "paused"'
  hook_input UserPromptSubmit s1 '{"prompt":"I will take it from here"}' | run_hook >/dev/null
  assert_eq "$(jqv "$(lg_session_get s1)" .status)" "active"
}

test_session_end_keeps_paused_headless_sessions_resumable() {
  hook_input SessionStart a | run_hook >/dev/null
  hook_input SessionStart b | run_hook >/dev/null
  lg_session_update a '.status = "paused"'
  hook_input SessionEnd a '{"reason":"other"}' | run_hook >/dev/null
  hook_input SessionEnd b '{"reason":"other"}' | run_hook >/dev/null
  assert_eq "$(jqv "$(lg_session_get a)" .status)" "paused"
  assert_eq "$(jqv "$(lg_session_get a)" .exited)" "true"
  assert_eq "$(jqv "$(lg_session_get b)" .status)" "ended"
}

test_session_start_while_paused_injects_context() {
  pause_now
  local out
  out="$(hook_input SessionStart s1 '{"source":"startup"}' | run_hook)"
  assert_contains "$(jqv "$out" .hookSpecificOutput.additionalContext)" "paused"
}

test_bad_input_and_disable_switch_never_block() {
  pause_now
  local out
  out="$(echo 'garbage{' | run_hook)"; assert_eq "$?" "0"; assert_empty "$out"
  out="$(printf '' | run_hook)"; assert_empty "$out"
  out="$(hook_input PreToolUse s1 '{"tool_name":"Bash"}' | LIMIT_GUARD_DISABLE=1 run_hook)"
  assert_empty "$out"
}

test_hook_survives_unwritable_state_dir() {
  pause_now
  chmod 500 "$LG_HOME/sessions"
  local out rc
  out="$(hook_input PreToolUse s9 '{"tool_name":"Bash"}' | run_hook)"; rc=$?
  chmod 700 "$LG_HOME/sessions"
  assert_eq "$rc" "0"
  # still denies (state is readable) even though the registry write failed
  assert_eq "$(jqv "$out" .hookSpecificOutput.permissionDecision)" "deny"
}

register_desktop() { # $1 session id
  LG_TEST_PID=4242 LG_TEST_ARGV="/x/claude --output-format stream-json --verbose --input-format stream-json" \
    run_hook < <(hook_input SessionStart "$1") >/dev/null
}

test_desktop_sessions_are_not_promised_an_automatic_resume() {
  register_desktop d1
  pause_now
  local out
  out="$(hook_input PreToolUse d1 '{"tool_name":"Bash"}' | run_hook)"
  assert_contains "$(jqv "$out" .hookSpecificOutput.permissionDecisionReason)" "the user will continue this session"
  assert_not_contains "$(jqv "$out" .hookSpecificOutput.permissionDecisionReason)" "automatically"
  out="$(hook_input UserPromptSubmit d1 '{"prompt":"ship it"}' | run_hook)"
  assert_contains "$(jqv "$out" .reason)" "send any message"
  assert_not_contains "$(jqv "$out" .reason)" "automatically"
}

test_tmux_sessions_are_still_promised_an_automatic_resume() {
  TMUX="/tmp/s,1,0" TMUX_PANE="%2" LG_TEST_PID=111 LG_TEST_ARGV="/x/claude" \
    run_hook < <(hook_input SessionStart t1) >/dev/null
  pause_now
  local out
  out="$(hook_input PreToolUse t1 '{"tool_name":"Bash"}' | run_hook)"
  assert_contains "$(jqv "$out" .hookSpecificOutput.permissionDecisionReason)" "resume this session automatically"
}

test_continuing_a_desktop_session_by_hand_hands_it_the_checkpoint_and_saved_prompt() {
  register_desktop d1
  echo "# checkpoint" > "$LG_HOME/checkpoints/d1.md"
  lg_session_update d1 '.status = "resume_failed" | .needs_manual = true | .deferred_prompt = "also bump the version"'
  local out ctx
  out="$(hook_input UserPromptSubmit d1 '{"prompt":"continue"}' | run_hook)"
  assert_eq "$(jqv "$out" .hookSpecificOutput.hookEventName)" "UserPromptSubmit"
  ctx="$(jqv "$out" .hookSpecificOutput.additionalContext)"
  assert_contains "$ctx" "$LG_HOME/checkpoints/d1.md"
  assert_contains "$ctx" "also bump the version"
  local s; s="$(lg_session_get d1)"
  assert_eq "$(jqv "$s" .status)" "active"
  assert_eq "$(jqv "$s" '.needs_manual // false')" "false"
  assert_eq "$(jqv "$s" '.deferred_prompt // "none"')" "none"
  # Handed over once only.
  out="$(hook_input UserPromptSubmit d1 '{"prompt":"thanks"}' | run_hook)"
  assert_empty "$out"
}

test_an_idle_session_gets_no_resume_context() {
  register_desktop d1
  local out
  out="$(hook_input UserPromptSubmit d1 '{"prompt":"hello"}' | run_hook)"
  assert_empty "$out"
}
