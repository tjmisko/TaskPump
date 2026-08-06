# arachne-monitor — colour system

Written 2026-08-05, after the monitor's two tabs were found disagreeing about
what green means.

Scope: `scripts/arachne-monitor` (both tabs) and the status palette it shares
with `scripts/arachne-dag-layout.awk`. Subordinate to
`DESIGN-monitor-dag-v2.md`, which owns the GRAPH tab's palette and the
attribute-leak rule. **The graph is the anchor**; everything else normalizes
onto it, and where the two documents disagree about a graph value, that one
wins.

## The defect this replaces

The monitor was running two colour vocabularies side by side.

One was deliberate: the 256-index `ST_*` status palette, mirrored by `hue()` in
the awk. The other was ~20 basic-ANSI one-offs — `36m` cyan ×6, `90m` ×5, `33m`
×2, `32m` ×2, `31m` ×2, plus `7m` reverse video — accumulated one render
function at a time.

Basic-ANSI numbers are not colours. They are indices into whatever the terminal
theme maps them to, so they cannot be reasoned about or contrast-checked. Under
Catppuccin Mocha `32m` is `#a6e3a1`, a bright pastel that cannot sit beside the
graph's `#5FAF5F`, and `33m` is `#f9e2af`, which does the same to the graph's
amber. The session dot was cyan sitting immediately left of a green `[running]`
— two hues for one fact.

The fix is not to retune individual values. It is to delete the second
vocabulary.

## Four families, and nothing outside them

A new surface picks its family by asking what the colour is *about*.

### STATE — where a task or agent is in its life

The only family permitted green, amber or red. Green is the progress axis and
has exactly **two** steps, settled and live. There is deliberately no third
green anywhere in the monitor.

| Meaning | Glyph | SGR | hex |
|---|---|---|---|
| settled, behind you | `✓` | `0;2;38;5;65` | `#5F875F` dimmed |
| live, an agent is on it now | `▶` | `0;38;5;71` | `#5FAF5F` |
| attention, not yet a problem | `⧗` | `0;38;5;179` | `#DFAF5F` |
| cannot proceed | `⊘` | `0;38;5;131` | `#AF5F5F` |
| act now | `!` | `0;1;38;5;203` | `#FF5F5F` |
| eligible, not started | `○` | `0;38;5;250` | `#BCBCBC` |
| ineligible, not started | `◌` | `0;2;38;5;244` | `#808080` dimmed |

The pump's own status is a STATE, not a fourth thing: `running` is the same fact
as "an agent is on it", `paused` is attention, `drained` is settled.

### RESOURCE — how much headroom is left

The usage and disk gauges. A gauge is not a task state, so it keeps its own
resting hue — Claude terracotta `173`, matching `~/.claude/claude-status` — but
its **escalation reuses STATE's amber and coral verbatim**. Amber means
"attention" and coral means "act now" screen-wide, whether the subject is a task
or a filesystem.

| Band | SGR |
|---|---|
| normal | `0;38;5;173` |
| warning | `0;38;5;179` — identical to STATE's `⧗` |
| critical | `0;1;38;5;203` — identical to STATE's `!` |

### CHROME — structure and text carrying no state

Greys only, never a hue.

| Token | SGR | hex | Used for |
|---|---|---|---|
| `C_STRONG` | `0;1;38;5;252` | `#D0D0D0` bold | titles, selected row, input prompt |
| `C_TEXT` | `0;38;5;252` | `#D0D0D0` | the datum you actually read |
| `C_MUTED` | `0;38;5;245` | `#8A8A8A` | labels, units, hints, log tails |
| `C_RULE` | `0;38;5;242` | `#6C6C6C` | rules, gauge troughs, inactive tab |
| `C_FAINT` | `0;2;38;5;244` | `#808080` dimmed | empty states and placeholders |

STATE's two neutral tiers are greys too. The overlap is intended rather than a
collision — grey here means "no colour information", which is what both families
are saying. They are told apart by attachment: **a state grey always sits on a
glyph; a chrome grey never does.**

### SELECTION — never a colour

Weight and glyph only: `▸` + bold on SESSIONS, the heavy border `┏━┓` on GRAPH,
bold weight on the tab bar's active label (its `┤ ├` brackets were dropped once
the weight was carrying the mark on its own; the label cells stay a fixed width
in both states so switching tabs shifts nothing). A selected node has to keep
showing its own status colour,
so a "selected" hue would either overwrite that or introduce a fifth family.

**Cyan is deleted.** It was the session dot, the pump status word, and the ready
count — three unrelated facts wearing one hue that meant nothing in the system,
from a family that appears nowhere else.

## Rules

**R1 — every sequence re-opens with `0;`.** SGR attributes are sticky: a bare
`\033[38;5;173m` sets only the foreground, so a `1` or `2` set earlier stays on.
This has produced two live bugs, both invisible until someone read the raw bytes:

- One `done` box's dim washed the entire DAG grey (see `DESIGN-monitor-dag-v2.md`).
- `BAR_CAP` opened with `2` and nothing cleared it, so **every gauge fill and
  trough in the UI rendered at half brightness** — the terracotta measuring
  ~2.9:1 against the background instead of ~5.9:1. Nothing looked broken, which
  is how it survived.

**R2 — state is never carried by colour alone.** Invariant I5. Every
state-coloured element pairs with a glyph, bracket or word. This is what makes
the palette safe to retune, and survivable on `--no-color` or for a colour-blind
reader.

**R3 — no basic-ANSI colour numbers and no reverse video.** `30`–`37`, `90`–`97`
and `7m` resolve through the theme. The only permitted forms are `0;38;5;N`,
`0;1;38;5;N`, `0;2;38;5;N`, and bare `0m`.

**R4 — one hue, one meaning.** Amber `179` is attention everywhere: a parked
claim, a paused pump, a gauge in its warning band. Coral `203` is act-now
everywhere: needs-review, stuck, a stalled queue, a stale log, a critical gauge.
Green `71` is live; green `65` is settled. A colour that fits none of those
sentences belongs in CHROME.

**R5 — the two palettes move together.** `hue()` in `arachne-dag-layout.awk` and
the `ST_*` constants in `arachne-monitor` are one vocabulary in two languages.
Changing either alone is a bug.

R1 and R3 are enforced by a test (`test-arachne-monitor.sh`, Test 23).

## Legibility

Nominal background is Catppuccin Mocha `#1e1e2e`, but the terminal runs at ~79%
opacity over a photo wallpaper, so the effective background is unpredictable and
often *lighter* than nominal — which lowers contrast for every light foreground.
The second column models a mid-grey wallpaper at 21%, roughly `#33333F`.

| Token | hex | vs `#1e1e2e` | blended | Verdict |
|---|---|---|---|---|
| `C_STRONG` / `C_TEXT` | `#D0D0D0` | 10.6:1 | 8.1:1 | safe |
| `ST_READY` | `#BCBCBC` | 8.6:1 | 6.6:1 | safe |
| edge rail, live | `#B2B2B2` | 7.7:1 | 5.9:1 | safe |
| `ST_PARK` / warn | `#DFAF5F` | 8.2:1 | 6.2:1 | safe |
| `ST_LIVE` | `#5FAF5F` | 6.1:1 | 4.6:1 | safe |
| gauge fill | `#D7875F` | 5.9:1 | 4.5:1 | safe *once R1 is honoured* |
| `ST_ALERT` / crit | `#FF5F5F` | 5.5:1 | 4.2:1 | safe |
| `C_MUTED` | `#8A8A8A` | 4.8:1 | 3.6:1 | **floor for readable text** |
| `ST_BLOCK` | `#AF5F5F` | 3.6:1 | 2.7:1 | at risk; glyph-backed |
| `C_RULE` | `#6C6C6C` | 3.1:1 | 2.4:1 | lines and troughs only, never text |
| `ST_DONE` | ~`#3F5A3F` | ~2.0:1 | ~1.5:1 | recessive by design, glyph-backed |
| `C_FAINT` | ~`#4D4D4D` | ~2.1:1 | ~1.6:1 | empty states only |

Three values sit below 3:1 through the wallpaper. `ST_DONE` and `C_FAINT` are
deliberately recessive and always glyph-backed. `ST_BLOCK` is the only one doing
real work at marginal contrast — leave it (graph anchor), but it is the first
thing to lift to `167` if blocked nodes prove hard to spot.

The removed `90m` was `#585b70`: 2.5:1 nominal, **1.9:1 blended**. That is why
the log tails — the largest block of text in the UI — were unreadable.

## What not to change

1. **The seven `ST_*` values and `hue()`.** They are the anchor.
2. **The `2` on `ST_DONE` and `ST_WAIT`.** It looks like the R1 bug and is not:
   it is the deliberate recede that makes the graph read as a progress gradient,
   and it is safe *because* those tokens open with `0;`.
3. **The two edge tiers, `249` and `65`.** The settled tier is *undimmed* 65 on
   purpose — a hairline needs more luminance than a filled label to read at the
   same weight. Do not "make it consistent" with the dimmed done boxes.
4. **The terracotta gauge fill `173`.** It matches `~/.claude/claude-status`, and
   the gauges are the one surface where a non-state hue is correct.
5. **Glyph redundancy.** Do not drop a glyph because the colour now says the same
   thing; R2 is why the palette can be tuned at all.
6. **The non-colour half of every selection marker** (`▸`, `┏━┓`, and the bold
   weight on the active tab). Dropping one leaves colour carrying state alone.
7. **The awk's `color ? … : ""` guard.** It is what makes the renderer testable
   and pipe-safe; every new token must respect it the same way.

## Known drift, not fixed here

On SESSIONS a container can be `running` while its task is an `in_progress`
claim that lost the newest-heartbeat election, so the row paints green while the
graph paints that same task amber `⧗`. Both are individually correct — the row
describes the *container*, the node describes the *task*. Colour cannot resolve
it; if it bites, the row should say which task the container is actually on.
