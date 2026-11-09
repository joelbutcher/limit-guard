# shellcheck shell=bash
R5=1794255000
R7=1794621600

test_end_to_end_pause_checkpoint_and_resume_after_reset() {
  set_token $((LG_NOW + 3600))
  # A tmux agent and a headless agent are working.
  TMUX="/tmp/sock,1,0" TMUX_PANE="%2" LG_TEST_PID=111 LG_TEST_ARGV="/x/claude" \
    run_hook < <(hook_input SessionStart tm) >/dev/null
  LG_TEST_PID=222 LG_TEST_ARGV="/x/claude -p build --model sonnet" \
    run_hook < <(hook_input SessionStart hl) >/dev/null
  mkdir -p "$TEST_ROOT/work"; echo '{"type":"assistant"}' > "$TEST_ROOT/work/hl.jsonl"

  # Usage climbs past the threshold (reported by the statusline).
  statusline_input 91 "$R5" 40 "$R7" | "$LG" statusline >/dev/null
  "$LG" tick >/dev/null
  assert_eq "$(lg_state_mode)" "paused"
  assert_eq "$(jq -r .resume_at "$LG_HOME/state.json")" "$((R5 + 120))"

  # Both agents try to keep working, get told to checkpoint, write it and stop.
  for s in tm hl; do
    out="$(hook_input PreToolUse $s '{"tool_name":"Edit","tool_input":{"file_path":"/w/x.php"}}' | run_hook)"
    assert_eq "$(jqv "$out" .hookSpecificOutput.permissionDecision)" "deny"
    out="$(hook_input PreToolUse $s "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$LG_HOME/checkpoints/$s.md\"}}" | run_hook)"
    assert_empty "$out"
    echo "# checkpoint" > "$LG_HOME/checkpoints/$s.md"
    hook_input Stop $s | run_hook >/dev/null
  done
  hook_input SessionEnd hl | run_hook >/dev/null
  assert_eq "$(jqv "$(lg_session_get tm)" .status)" "paused"
  assert_eq "$(jqv "$(lg_session_get hl)" .status)" "paused"

  # Before the reset nothing happens, and the API is not hammered.
  LG_NOW=$((R5 - 60)) "$LG" tick >/dev/null
  assert_eq "$(lg_state_mode)" "paused"

  # After the reset (token has expired meanwhile: no agent was running to refresh it).
  set_token $((R5 - 100))
  LG_NOW=$((R5 + 130)) LG_TEST_ALIVE=111 "$LG" tick >/dev/null
  assert_eq "$(lg_state_mode)" "running"
  assert_contains "$(cat "$STUB_LOG")" "send-keys -t %2 -l [limit-guard:resume]"
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do grep -q '^claude' "$STUB_LOG" && break; /bin/sleep 0.1; done
  assert_contains "$(grep '^claude' "$STUB_LOG")" "-p --resume hl --model sonnet"
  assert_eq "$(jqv "$(lg_session_get tm)" .status)" "active"
  assert_eq "$(jqv "$(lg_session_get hl)" .status)" "active"
}

test_manual_pause_and_resume() {
  "$LG" pause "going to lunch" >/dev/null
  assert_eq "$(lg_state_mode)" "paused"
  assert_eq "$(jq -r .manual "$LG_HOME/state.json")" "true"
  LG_NOW=$((R7 + 9999)) "$LG" tick >/dev/null
  assert_eq "$(lg_state_mode)" "paused"
  "$LG" resume >/dev/null
  assert_eq "$(lg_state_mode)" "running"
}

test_status_renders_without_data() {
  local out; out="$("$LG" status)"
  assert_contains "$out" "limit-guard: 5h – · 7d –"
  assert_contains "$out" "daemon: NOT RUNNING"
}

test_install_merges_hooks_idempotently_and_uninstall_restores() {
  export LG_SETTINGS="$HOME/.claude/settings.json" LG_PLIST="$TEST_ROOT/plist" LG_BIN_LINK="$HOME/.local/bin/limit-guard"
  cat > "$LG_SETTINGS" <<'EOF'
{"model":"opus","statusLine":{"type":"command","command":"~/my-status.sh"},
 "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"my-own-hook"}]}]}}
EOF
  lg_install_hooks; lg_install_statusline >/dev/null
  lg_install_hooks; lg_install_statusline >/dev/null
  local s; s="$(cat "$LG_SETTINGS")"
  assert_eq "$(jqv "$s" '.hooks.PreToolUse | length')" "2"
  assert_eq "$(jqv "$s" '[.hooks[][] .hooks[] | select(.command | test("limit-guard hook"))] | length')" "5"
  assert_eq "$(jqv "$s" .statusLine.command)" "$LG_BIN_LINK statusline"
  assert_eq "$(jqv "$s" .model)" "opus"
  ( . "$LG_HOME/config.env"; [ "$LG_STATUSLINE_CHAIN" = "~/my-status.sh" ] ) || fail "statusline not chained"

  launchctl() { :; }
  lg_load_config
  lg_uninstall >/dev/null
  s="$(cat "$LG_SETTINGS")"
  assert_eq "$(jqv "$s" '.hooks.PreToolUse | length')" "1"
  assert_eq "$(jqv "$s" '.hooks | keys | join(",")')" "PreToolUse"
  assert_eq "$(jqv "$s" .statusLine.command)" "~/my-status.sh"
  [ "$(ls "$HOME/.claude/" | grep -c 'settings.json.bak-limit-guard')" -ge 1 ] || fail "no backup written"
}
