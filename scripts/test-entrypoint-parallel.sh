#!/usr/bin/env bash
# test-entrypoint-parallel.sh — INSPECTION-only guard for entrypoint-parallel.sh.
#
# entrypoint-parallel.sh configures an iptables sandbox and launches a real
# `claude -p` Auto Mode session, so it is never executed here. This harness is a
# static regression guard for the F45.14.6 invariants:
#   * the session runs under `--permission-mode auto`;
#   * `--dangerously-skip-permissions` never appears (the iptables allowlist +
#     server-side classifier are the sandbox, not a skipped permission prompt);
#   * the pre-seeded Auto Mode allow rules (claude-settings-auto.json) are read
#     and merged into the dev user's settings.json.
#
# Run: ./scripts/test-entrypoint-parallel.sh   (offline; no container launched)
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
EP="$ROOT/entrypoint-parallel.sh"
AUTO_JSON="$ROOT/claude-settings-auto.json"

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

[[ -f "$EP" ]] || { echo "FAIL: entrypoint-parallel.sh not found at $EP" >&2; exit 1; }

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

# ── The allow file itself is well-formed Auto Mode config ──────────────────────
echo "--- claude-settings-auto.json shape ---"
if [[ -f "$AUTO_JSON" ]]; then
  pass "claude-settings-auto.json exists"
  if command -v jq >/dev/null 2>&1; then
    mode=$(jq -r '.permissions.defaultMode // empty' "$AUTO_JSON" 2>/dev/null)
    [[ "$mode" == "auto" ]] && pass "permissions.defaultMode == auto" \
      || fail "permissions.defaultMode is '$mode' (expected auto)"
    n=$(jq -r '.permissions.allow | length' "$AUTO_JSON" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] && pass "permissions.allow has $n pre-approved rules" \
      || fail "permissions.allow is empty or missing"
  else
    echo "  (jq unavailable — skipping JSON shape assertions)"
  fi
else
  fail "claude-settings-auto.json missing at $AUTO_JSON"
fi

# ── Smoke test is run before the session ───────────────────────────────────────
echo "--- pre-session smoke test ---"
if grep -q 'smoke_test.sh' "$EP"; then
  pass "runs smoke_test.sh before launching the session"
else
  fail "entrypoint-parallel.sh does not run smoke_test.sh"
fi

echo
echo "=============================================="
echo "Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "=============================================="
[[ $FAIL -eq 0 ]]
