#!/usr/bin/env bash
# suite-prologue.sh — the shared hermeticity prologue. Not a suite: run-all.sh
# sources it before launching any suite (the central guard), and every
# tests/test-*.sh sources it at the top of its own prologue (the double-guard
# for standalone runs, the same shape TASKPUMP_NO_CONF established). A new
# suite inherits both guards by opening with:
#
#   SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
#   . "$SCRIPT_DIR/suite-prologue.sh"
#
# It closes the two ways the caller's world can silently reconfigure a fixture:
#
# Conf files. The tools discover taskpump.conf by walking up from $PWD, so the
# conf of whatever repo the suites happen to run from (TaskPump's own dogfood
# conf included) would leak into every fixture invocation — a foreign sigil
# failing range parses, and a TASKPUMP_BUILD_GATE of './tests/run-all.sh' that
# once re-entered the whole suite unboundedly. TASKPUMP_NO_CONF=1 turns
# ambient discovery off; a suite that tests discovery itself opts back in
# per-invocation (TASKPUMP_NO_CONF=0, or an explicit TASKPUMP_CONFIG, which
# outranks the switch). test-conf-hermeticity.sh pins that seam.
#
# Environment (issue #18). The pump/entrypoint export TASKPUMP_TASKS_DIR /
# TP_TASKS_DIR — pointing at the REAL ledger — into every agent session;
# necessarily, that is how an agent's tp finds its ledger. But lib/config.sh
# gives a canonical spelling the win over its legacy twin, so an inherited
# TASKPUMP_X silently outranks the ARACHNE_X a fixture sets: the 2026-08-13 G3
# drain agent saw 64 spurious failures across three suites, each reading the
# real ledger while believing it read its fixture. So every inherited
# TASKPUMP_*, TP_*, and ARACHNE_* variable is unset here, by enumeration — a
# hand-kept name list is how the next key added leaks through. A suite that
# needs one of these variables sets it explicitly AFTER sourcing this; none
# may inherit one. test-env-hermeticity.sh pins this seam.
#
# Exported names only: a suite's own unexported helpers (TP_ROOT,
# TP_ENV_UNSET, ...) are not environment, and are defined after this runs in
# any case.
while IFS= read -r _tp_scrub_var; do
  unset "$_tp_scrub_var"
done < <(compgen -e TASKPUMP_; compgen -e TP_; compgen -e ARACHNE_; true)
unset _tp_scrub_var

# The hermetic baseline, re-established after the scrub:
#
#   * ambient conf discovery stays off (above);
#   * notifications are stubbed to `true`, in both spellings — several suites
#     drive code paths that would otherwise fire a real desktop notification
#     per tick. A test that captures notifications overrides
#     TASKPUMP_NOTIFY_CMD per invocation.
export TASKPUMP_NO_CONF=1
export TASKPUMP_NOTIFY_CMD=true
export ARACHNE_NOTIFY_CMD=true
