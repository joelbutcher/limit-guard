# shellcheck shell=bash
# Test helpers: isolated LG_HOME/HOME, PATH stubs, fixed clock, assertions.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LG="$REPO/bin/limit-guard"

setup_env() {
  TEST_ROOT="$(mktemp -d "$(t="${TMPDIR:-/tmp}"; echo "${t%/}")/lg-test.XXXXXX")"
  export HOME="$TEST_ROOT/home"
  export LG_HOME="$HOME/.claude/limit-guard"
  export STUB_DIR="$TEST_ROOT/stubs"
  export STUB_LOG="$TEST_ROOT/stub.log"
  export LG_NOW=1794247000
  export LG_NOTIFY=0
  export LG_PROJECTS_DIR="$HOME/.claude/projects"
  export LG_CLAUDE_BIN="claude"
  unset TMUX TMUX_PANE LIMIT_GUARD_DISABLE LG_TEST_PID LG_TEST_ARGV LG_TEST_ALIVE
  mkdir -p "$HOME/.claude" "$STUB_DIR" "$LG_PROJECTS_DIR"
  : > "$STUB_LOG"
  write_stubs
  export PATH="$STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
  # Load the library into this shell too, for unit-level calls.
  # shellcheck disable=SC1090
  for f in common usage sessions guard hooks resume install; do . "$REPO/lib/$f.sh"; done
  lg_status_short() { echo stub; }
  lg_init
}

teardown_env() { rm -rf "$TEST_ROOT"; }

write_stubs() {
  cat > "$STUB_DIR/security" <<'EOF'
#!/bin/bash
echo "security $*" >> "$STUB_LOG"
[ -f "$STUB_DIR/keychain.json" ] && cat "$STUB_DIR/keychain.json" && exit 0
exit 44
EOF
  cat > "$STUB_DIR/curl" <<'EOF'
#!/bin/bash
echo "curl ARGS: $*" >> "$STUB_LOG"
echo "curl STDIN: $(cat)" >> "$STUB_DIR/curl.stdin"
cat "$STUB_DIR/curl.body" 2>/dev/null
printf '\n%s' "$(cat "$STUB_DIR/curl.code" 2>/dev/null || echo 200)"
EOF
  cat > "$STUB_DIR/tmux" <<'EOF'
#!/bin/bash
echo "tmux $*" >> "$STUB_LOG"
case "$*" in
  *'#{pane_id}'*) [ -f "$STUB_DIR/tmux.nopane" ] && exit 1; echo "%1" ;;
  *'#{pane_current_command}'*) cat "$STUB_DIR/tmux.cmd" 2>/dev/null || echo claude ;;
esac
exit 0
EOF
  cat > "$STUB_DIR/claude" <<'EOF'
#!/bin/bash
echo "claude CWD=$(pwd) ARGS: $*" >> "$STUB_LOG"
EOF
  cat > "$STUB_DIR/osascript" <<'EOF'
#!/bin/bash
echo "osascript $*" >> "$STUB_LOG"
EOF
  cat > "$STUB_DIR/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$STUB_DIR"/*
}

set_token() { # $1 = expiresAt epoch seconds
  jq -n --argjson e "$(( $1 * 1000 ))" '{claudeAiOauth: {accessToken: "sk-ant-oat-SECRET-TOKEN", expiresAt: $e}}' > "$STUB_DIR/keychain.json"
}

set_api() { # $1 = body, $2 = http code
  printf '%s' "$1" > "$STUB_DIR/curl.body"
  echo "${2:-200}" > "$STUB_DIR/curl.code"
}

api_body() { # $1 = 5h pct, $2 = 5h reset ISO, $3 = 7d pct, $4 = 7d reset ISO
  jq -n --argjson a "$1" --arg ar "$2" --argjson b "$3" --arg br "$4" \
    '{five_hour: {utilization: $a, resets_at: $ar}, seven_day: {utilization: $b, resets_at: $br}, extra_usage: {is_enabled: true}}'
}

statusline_input() { # $1 = 5h pct, $2 = 5h resets epoch, $3 = 7d pct, $4 = 7d resets
  jq -n --argjson a "$1" --argjson ar "$2" --argjson b "$3" --argjson br "$4" \
    '{session_id: "s", rate_limits: {five_hour: {used_percentage: $a, resets_at: $ar}, seven_day: {used_percentage: $b, resets_at: $br}}}'
}

hook_input() { # $1 event, $2 session id, [$3 extra json]
  local extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  jq -cn --arg e "$1" --arg id "$2" --arg cwd "$TEST_ROOT/work" --argjson x "$extra" \
    '{hook_event_name: $e, session_id: $id, cwd: $cwd, transcript_path: ($cwd + "/" + $id + ".jsonl")} + $x'
}

run_hook() { # stdin json -> stdout of the hook via the real CLI
  "$LG" hook
}

# ---- assertions ----------------------------------------------------------------

FAILS=0
fail() { echo "    ✗ $*"; FAILS=$((FAILS + 1)); }
assert_eq() { [ "$1" = "$2" ] || fail "${3:-expected} '$2', got '$1'"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "${3:-expected to contain} '$2' in: $(printf '%s' "$1" | head -c 400)" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "${3:-expected not to contain} '$2'" ;; esac; }
assert_empty() { [ -z "$1" ] || fail "${2:-expected empty}, got: $(printf '%s' "$1" | head -c 300)"; }
jqv() { printf '%s' "$1" | jq -r "$2"; }
