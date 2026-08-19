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
# It closes the ways the caller's world can silently reconfigure a fixture —
# and the way a fixture was silently reconfiguring the caller's world:
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
# Run state (B16). The leak runs the other way: tp-pump resolves its dotfiles
# to $TASKPUMP_STATE_DIR, which defaults to the workspace root — and a suite
# that runs a real tick without pinning a workspace resolves that, through the
# cwd rung, to the TaskPump checkout the suites are running FROM. The pre-tick
# hook mark file is the one that actually moves: run_pre_tick_hooks WRITES it
# when the hooks have something to say and `rm -f`s it when they go quiet, so
# on 2026-08-19 a suite run deleted and then rewrote the operator's live
# .taskpump-fsguard.notified in the primary checkout. .gitignore lists that
# name, so run-all.sh's status diff could not see it; the state manifest there
# is the other half of this fix.
#
# Redirecting the mark file out of the tree is the default a new suite inherits
# without having to know any of this. Note the precedence, because it is the
# reverse of the obvious guess: tp-pump resolves HOOK_MARK_FILE as
# TASKPUMP_HOOK_MARK_FILE, then TASKPUMP_FSGUARD_MARK_FILE, then
# $STATE_DIR/.taskpump-fsguard.notified — so the export below OUTRANKS a suite's
# own TASKPUMP_STATE_DIR, and pinning the state dir does not move the mark file
# while this default stands. A suite that wants the mark file somewhere of its
# own sets one of the two mark-file keys after sourcing this; a suite that pins
# only the state dir moves the rest of the family and leaves this alone.
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
#   * the pre-tick hook mark file points outside any repository (above). Per
#     process, so two suites running side by side do not share a fingerprint.
#     The pump creates it only when a tick's hooks produce output and `rm -f`s
#     it when they go quiet, but a suite whose last tick still had something to
#     say leaves the file behind: run-all.sh removes the ones its own run left
#     (newer than its run stamp, no live process behind the pid) in its EXIT
#     trap, so a full run cleans up after itself. A suite run standalone can
#     still leave a one-line fingerprint in $TMPDIR. test-env-hermeticity.sh
#     pins that this default is absolute and outside the checkout, and that a
#     full run does not leave its own behind.
export TASKPUMP_NO_CONF=1
export TASKPUMP_NOTIFY_CMD=true
export ARACHNE_NOTIFY_CMD=true
export TASKPUMP_HOOK_MARK_FILE="${TMPDIR:-/tmp}/taskpump-suite-hookmark.$$"
