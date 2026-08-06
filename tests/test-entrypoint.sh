#!/usr/bin/env bash
# test-entrypoint.sh — INSPECTION-only guard for the claude-docker runner's
# entrypoint.
#
# The entrypoint configures an iptables sandbox and launches a real
# `claude -p` Auto Mode session, so it is never executed here. This harness is a
# static regression guard for the F45.14.6 invariants:
#   * the session runs under `--permission-mode auto`;
#   * `--dangerously-skip-permissions` never appears (the iptables allowlist +
#     server-side classifier are the sandbox, not a skipped permission prompt);
#   * the pre-seeded Auto Mode allow rules (claude-settings-auto.json) are read
#     and merged into the dev user's settings.json.
#
# Run: ./tests/test-entrypoint.sh   (offline; no container launched)
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
EP="$TP_ROOT/runners/claude-docker/entrypoint.sh"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

[[ -f "$EP" ]] || { echo "FAIL: entrypoint not found at $EP" >&2; exit 1; }

# ── Permission posture ─────────────────────────────────────────────────────────
echo "--- permission posture ---"
if grep -qE -- '--permission-mode[[:space:]]+auto' "$EP"; then
  pass "launches claude with --permission-mode auto"
else
  fail "entrypoint-parallel.sh does not pass --permission-mode auto"
fi

# Strip full-line comments first: the header legitimately *names* the flag to say
# it is NOT used. The invariant is that no EXECUTABLE line passes it to claude.
if grep -vE '^[[:space:]]*#' "$EP" | grep -q -- '--dangerously-skip-permissions'; then
  fail "an executable line of entrypoint-parallel.sh passes --dangerously-skip-permissions (must NOT)"
else
  pass "no --dangerously-skip-permissions on any executable line"
fi

# ── Pre-seeded allow rules are read + applied ──────────────────────────────────
echo "--- pre-seeded Auto Mode allow rules ---"
if grep -q 'claude-settings-auto.json' "$EP"; then
  pass "references claude-settings-auto.json (the pre-seeded allow list)"
else
  fail "entrypoint-parallel.sh never references claude-settings-auto.json"
fi
# It must actually WRITE the merged result to the session's settings.json.
if grep -q 'settings.json' "$EP"; then
  pass "writes a merged settings.json for the session"
else
  fail "entrypoint-parallel.sh never writes settings.json"
fi

# ── The merge itself, against a fixture allow file ─────────────────────────────
# The real claude-settings-auto.json is an Arachne-side artifact and does not
# ship with TaskPump, so there is nothing at the repo root to inspect. What is
# TaskPump's to guarantee is the *merge semantics* the entrypoint applies, so
# that is what gets exercised: a fixture MCP config and a fixture Auto Mode
# config, combined by the entrypoint's own jq expression, must yield a
# settings.json that keeps the MCP servers and lets the Auto settings win every
# conflicting key.
echo "--- Auto Mode settings merge ---"
MERGE_EXPR='.[0] * .[1]'
if grep -qF -- "jq -s '$MERGE_EXPR'" "$EP"; then
  pass "entrypoint merges MCP + Auto settings with jq -s '$MERGE_EXPR'"
else
  fail "entrypoint no longer merges with jq -s '$MERGE_EXPR' (update this test with it)"
fi

FIX_MCP="$WORK/claude-mcp.json"
FIX_AUTO="$WORK/claude-settings-auto.json"
cat >| "$FIX_MCP" <<'EOF'
{
  "mcpServers": { "context7": { "command": "npx", "args": ["-y", "@upstash/context7-mcp"] } },
  "permissions": { "defaultMode": "default", "allow": ["Bash(ls:*)"] }
}
EOF
cat >| "$FIX_AUTO" <<'EOF'
{
  "permissions": {
    "defaultMode": "auto",
    "allow": ["Bash(cargo test:*)", "Bash(git commit:*)"]
  }
}
EOF

if command -v jq >/dev/null 2>&1; then
  mode=$(jq -r '.permissions.defaultMode // empty' "$FIX_AUTO" 2>/dev/null)
  [[ "$mode" == "auto" ]] && pass "fixture allow file declares permissions.defaultMode == auto" \
    || fail "fixture permissions.defaultMode is '$mode' (expected auto)"
  n=$(jq -r '.permissions.allow | length' "$FIX_AUTO" 2>/dev/null)
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] && pass "fixture permissions.allow has $n pre-approved rules" \
    || fail "fixture permissions.allow is empty or missing"

  MERGED="$WORK/settings.json"
  jq -s "$MERGE_EXPR" "$FIX_MCP" "$FIX_AUTO" >| "$MERGED" 2>/dev/null

  got=$(jq -r '.mcpServers.context7.command // empty' "$MERGED" 2>/dev/null)
  [[ "$got" == "npx" ]] && pass "merge keeps the MCP servers from claude-mcp.json" \
    || fail "merge lost mcpServers (context7.command = '$got')"

  got=$(jq -r '.permissions.defaultMode // empty' "$MERGED" 2>/dev/null)
  [[ "$got" == "auto" ]] && pass "merge lets Auto Mode win defaultMode over the MCP config" \
    || fail "merged defaultMode is '$got' (expected auto to win)"

  got=$(jq -r '.permissions.allow | index("Bash(cargo test:*)") // empty' "$MERGED" 2>/dev/null)
  [[ -n "$got" ]] && pass "merge carries the Auto Mode allow rules into settings.json" \
    || fail "merged permissions.allow lost the Auto Mode rules"

  got=$(jq -r '.permissions.allow | index("Bash(ls:*)") // empty' "$MERGED" 2>/dev/null)
  [[ -z "$got" ]] && pass "Auto Mode's allow list replaces the MCP config's, not appends" \
    || fail "merged permissions.allow still carries the MCP config's rules"
else
  echo "  (jq unavailable — skipping the merge assertions)"
fi

# Both single-sided fallbacks must exist, or a run with only one of the two files
# silently launches with no settings.json at all.
if grep -qF 'cp "$AUTO_JSON" /home/dev/.claude/settings.json' "$EP" \
   && grep -qF 'cp "$MCP_JSON" /home/dev/.claude/settings.json' "$EP"; then
  pass "entrypoint falls back to whichever config exists when only one is present"
else
  fail "entrypoint is missing a single-sided fallback for MCP-only / Auto-only"
fi

# ── Smoke test is run before the session ───────────────────────────────────────
echo "--- pre-session smoke test ---"
if grep -q 'smoke_test.sh' "$EP"; then
  pass "runs smoke_test.sh before launching the session"
else
  fail "entrypoint-parallel.sh does not run smoke_test.sh"
fi

# ── Access-token-only credentials (no refresh-token rotation by containers) ─────
# The container must strip .claudeAiOauth.refreshToken from its credential copy so
# it can never rotate the host's shared OAuth token and log the host out.
echo "--- access-token-only credentials ---"
if grep -q "del(.claudeAiOauth.refreshToken)" "$EP"; then
  pass "strips refreshToken from the container credential copy (access-token-only)"
else
  fail "entrypoint-parallel.sh never strips .claudeAiOauth.refreshToken"
fi
# The strip must happen at STARTUP, not only in the periodic refresher — otherwise
# a refresh in the first CRED_REFRESH_INTERVAL_S window rotates the host token.
if grep -c "install_access_only_credentials" "$EP" | awk '{exit !($1>=2)}'; then
  pass "install_access_only_credentials used at startup AND in the refresher"
else
  fail "install_access_only_credentials must be called at startup and in the refresher"
fi
# The full host credentials.json must never be plain-copied into the dev home as
# the live token (that would carry the refresh token). The only cp of a
# .credentials.json path would be a regression.
if grep -vE '^[[:space:]]*#' "$EP" | grep -E 'cp[[:space:]].*\.credentials\.json'; then
  fail "an executable line plain-copies .credentials.json (carries the refresh token)"
else
  pass "no plain cp of .credentials.json (only the stripped install path)"
fi

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]]
