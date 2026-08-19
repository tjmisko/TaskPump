#!/usr/bin/env bash
# tty-safe.sh — the one rule for text that reaches an operator's terminal.
#
# This file is sourced, never executed — no `set -e`, no top-level side effects.
#
# ── Why it exists ────────────────────────────────────────────────────────────
#
# Almost everything TaskPump prints is written by somebody else: a task's title
# and goal come out of the ledger, a branch name out of a claim, a feed line out
# of an agent's log, a Bash tool result out of whatever command an agent ran over
# whatever a repository contains. All of it lands on the terminal of the human
# supervising a multi-day drain — and a terminal is an interpreter, not a canvas.
# A CSI sequence in a task title repaints a `blocked` row green; `\033[2K\r` in a
# log line erases the line the operator is reading and writes a different one;
# `\033[1A` walks back over a real failure; an OSC sets the window title. The
# dashboard is exactly what the operator uses to decide whether the fleet is
# healthy, so forging it is the whole attack. (PI-D8, PI-E1, PI-E2.)
#
# ── The contract ─────────────────────────────────────────────────────────────
#
#   tp_display_safe <string>
#
# Sets TP_SAFE to a version of <string> that cannot steer a terminal:
#
#   * TAB (0x09) becomes ONE space. It is the only C0 byte carrying content
#     rather than control, and a space keeps the word break — while removing the
#     one byte that would also split a TSV cache record or shift a column.
#   * every other C0 byte (0x00-0x1F, so ESC, CR, LF, BEL) and DEL (0x7F) is
#     dropped, along with the C1 range (U+0080-U+009F, which is a CSI introducer
#     on a terminal that decodes it). What is left is inert text.
#   * nothing else is touched: UTF-8 stays UTF-8, and the *words* survive, so a
#     sanitised line still says what it said. Only its ability to act is gone.
#
# It writes a variable instead of printing, on purpose: the callers are paint
# loops running per row per frame, and `$(...)` would fork for every one of them.
#
# WHAT THIS IS NOT: it is not an escaper for the colour a tool emits itself. A
# caller composes its own SGR sequences AROUND the sanitised value — sanitise the
# datum, then wrap it — never the other way round, or the tool erases its own
# palette. And it is not for machine output: `--json` and cache *keys* keep the
# original bytes, because a JSON consumer escapes them itself and a key that was
# rewritten no longer matches the thing it names.
tp_display_safe() {  # $1 = raw text -> TP_SAFE
  TP_SAFE="${1-}"
  TP_SAFE="${TP_SAFE//$'\t'/ }"
  # C1 as UTF-8 (0xC2 0x80-0x9F) first, explicitly: [[:cntrl:]] only covers it
  # in a UTF-8 locale, and the tools have no say in the locale they run under.
  TP_SAFE="${TP_SAFE//$'\302'[$'\200'-$'\237']/}"
  TP_SAFE="${TP_SAFE//[[:cntrl:]]/}"
}
