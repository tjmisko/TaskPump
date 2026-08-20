#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Tristan Misko
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
#     dropped.
#   * C1 (U+0080-U+009F — CSI, OSC, DCS and friends in their 8-bit form) is
#     dropped in BOTH encodings it can arrive in: the UTF-8 one, 0xC2 followed by
#     0x80-0x9F, and a bare 8-bit byte 0x80-0x9F standing outside any UTF-8
#     sequence. The bare form is the one a UTF-8 terminal renders as a
#     replacement character and an 8-bit terminal reads as the control itself, so
#     it means nothing except as an attack and is dropped outright.
#   * nothing else is touched: well-formed UTF-8 stays byte-for-byte itself, and
#     the *words* survive, so a sanitised line still says what it said. Only its
#     ability to act is gone.
#
# WHAT IS NOT COVERED, stated plainly: a byte in 0x80-0x9F that is part of a
# well-formed multi-byte character is KEPT — `→` is 0xE2 0x86 0x92, and deleting
# its 0x86 would corrupt the character rather than protect anything. On a
# terminal decoding UTF-8 that byte is not a control and never was. On a terminal
# running in 8-bit mode it is, but so is every non-ASCII glyph these tools print
# themselves (`▶` is 0xE2 0x96 0xB6), and an attacker can spell CSI as the middle
# byte of a perfectly legal character. There is no strip that keeps UTF-8 and
# also emits no C1 byte: the guarantee here is for a terminal that decodes UTF-8,
# plus the stray-byte case in every locale. A tool that must be safe on an 8-bit
# terminal has to drop non-ASCII entirely, which is not what this does.
#
# It writes a variable instead of printing, on purpose: the callers are paint
# loops running per row per frame, and `$(...)` would fork for every one of them.
#
# WHAT THIS IS NOT: it is not an escaper for the colour a tool emits itself. A
# caller composes its own SGR sequences AROUND the sanitised value — sanitise the
# datum, then wrap it — never the other way round, or the tool erases its own
# palette. And it is not for machine output: JSON and cache *keys* keep the
# original bytes, because a JSON consumer escapes them itself and a key that was
# rewritten no longer matches the thing it names.
tp_display_safe() {  # $1 = raw text -> TP_SAFE
  # C for the whole function, so every match below is a BYTE match and means the
  # same thing everywhere. Without it the tools would be at the mercy of a locale
  # they do not choose: [[:cntrl:]] classifies 0x80-0x9F as control in a latin-1
  # locale and not in a UTF-8 one, and ${#s}/${s:i:n} count characters in one and
  # bytes in the other. `local` restores the caller's locale on return.
  local LC_ALL=C
  TP_SAFE="${1-}"
  TP_SAFE="${TP_SAFE//$'\t'/ }"
  # C1 as UTF-8 (0xC2 0x80-0x9F). 0xC2 is never a continuation byte and no
  # character starts at 0x80-0x9F, so this pattern matches encoded C1 and
  # nothing else.
  TP_SAFE="${TP_SAFE//$'\302'[$'\200'-$'\237']/}"
  # C0 and DEL.
  TP_SAFE="${TP_SAFE//[[:cntrl:]]/}"
  # Bare 8-bit C1. Only walk the string when one of those bytes is present at
  # all — pure-ASCII text, which is nearly all of it, pays one glob and leaves.
  [[ "$TP_SAFE" == *[$'\200'-$'\237']* ]] || return 0
  local out='' rest="$TP_SAFE" run n
  while [[ -n "$rest" ]]; do
    # Everything up to the next non-ASCII byte is copied wholesale, so the loop
    # turns once per multi-byte character rather than once per byte.
    run="${rest%%[$'\200'-$'\377']*}"
    if [[ -n "$run" ]]; then
      out+="$run"; rest="${rest:${#run}}"
      [[ -n "$rest" ]] || break
    fi
    # A well-formed sequence is copied whole, C1 bytes and all; anything else at
    # this position is a lone byte, dropped when it is C1 and kept when it is not
    # (a latin-1 é is 0xE9 — mojibake is not this function's business).
    case "$rest" in
      [$'\302'-$'\337'][$'\200'-$'\277']*)                                     n=2 ;;
      [$'\340'-$'\357'][$'\200'-$'\277'][$'\200'-$'\277']*)                     n=3 ;;
      [$'\360'-$'\364'][$'\200'-$'\277'][$'\200'-$'\277'][$'\200'-$'\277']*)    n=4 ;;
      *)                                                                       n=0 ;;
    esac
    if (( n )); then
      out+="${rest:0:n}"; rest="${rest:n}"
    else
      [[ "$rest" == [$'\200'-$'\237']* ]] || out+="${rest:0:1}"
      rest="${rest:1}"
    fi
  done
  TP_SAFE="$out"
}
