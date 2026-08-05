# arachne-monitor — tabbed UI + layered task-DAG view

Design note for the `feat/monitor-dag-view` branch. Validated against the live
F79 ledger (24 tasks, 7 layers, widest layer 12) on 2026-08-05.

## 1. Tabs

Two tabs, switched with `Tab` / `Shift-Tab` and `←` / `→`:

| # | Name     | Contents |
|---|----------|----------|
| 1 | `SESSIONS` | today's view — usage gauges, disk gauge, notes, scrollable session list. **Change: two transcript lines per session instead of one.** |
| 2 | `GRAPH`    | layered boxed DAG of the pump's phase range. |

The tab bar is one row, rendered above the existing content, and is the only
chrome the SESSIONS tab gains. Inactive tab dim, active tab bold, never
colour-alone — bold weight is the non-colour half of the mark. (It was once
bracketed too; the brackets were dropped in 2026-08, and because a bracket was
also padding the cell, both labels now sit in fixed-width cells so the row does
not reflow when the selection changes.)

```
  SESSIONS    GRAPH     :help
```

`--tab sessions|graph` selects the initial tab and, in one-shot (non-`--watch`)
mode, renders just that tab. This is what makes the DAG testable headlessly in
`test-arachne-monitor.sh`, matching how the existing tests pin geometry with
`ARACHNE_MONITOR_COLS` / `_LINES`.

## 2. Layered DAG — algorithm

Implemented as a standalone renderer, `scripts/arachne-dag-render`, so graph
layout stays off the monitor's redraw path and can be tested on its own. The
monitor shells out to it, caches the result like the disk gauge does, and pans a
viewport over the output.

Input: one row per task, `id \t status \t comma-separated-blockers`, scoped to
the pump's phase range (from `.arachne-pump.state`'s `phases`), plus
out-of-range blockers pulled in as stub nodes.

Four passes:

1. **`layer()`** — longest-path layering over `blockers:`. `layer(n) = 0` if no
   in-scope blocker, else `1 + max(layer(blockers))`. Iterate to a fixpoint
   (bounded), so input order doesn't matter.
2. **`order()`** — barycentre sweeps to cut edge crossings, alternating **down**
   (place each layer at the mean position of its parents) and **up** (mean
   position of its children). The up sweep is load-bearing: without it a small
   side branch stays stranded mid-layer while its child sits at the far edge,
   dragging one rail across the entire band.
3. **`place()`** — column assignment; each node gets a box origin and a port
   column at its centre.
4. **`channels()`** — greedy interval routing. Each parent contributes one
   interval spanning its own port and all its children's ports; a parent takes
   the lowest rail row whose intervals don't overlap its own. Disjoint sibling
   groups therefore **share** a rail row instead of stacking, which is what
   keeps the band 4 rows tall instead of 10 on the F79 graph.

A parent whose children all sit directly beneath it (`lo == hi`) skips the rail
entirely and draws a straight `│` stem.

### Measured output (live F79)

```
┌───────┐
│ .1  ✓ │
└───┬───┘
    ┴─────────┬
┌───────┐ ┌───┴───┐
│ .2  ✓ │ │ .6  ✓ │
└───┬───┘ └───┬───┘
    ┴─────────┬─────────┬─────────┬─────────┬─────────┬─────────┬───────
    │         ┴─────────┼─────────┼─────────┼─────────┼─────────┼───────
┌───┴───┐ ┌───────┐ ┌───┴───┐ ┌───┴───┐ ┌───┴───┐ ┌───┴───┐ ┌───┴───┐
│ .3  ✓ │ │ .17 ✓ │ │ .18 ✓ │ │ .4  ▶ │ │ .9  ✓ │ │ .11 ✓ │ │ .12 ✓ │
└───┬───┘ └───┬───┘ └───┬───┘ └───┬───┘ └───┬───┘ └───┬───┘ └───┬───┘
```

24 nodes → **119 cols × 31 rows**. Fits width on any reasonable terminal; needs
vertical scrolling only. Crossings render as `┼`.

### Compact labels

Inside a single-phase range the `F79.` prefix is dropped (`.12`), since the
phase is already in the header — this is what gets the widest layer (12 nodes)
down to ~119 columns. Multi-phase ranges show full ids and widen the box.

## 3. Status encoding

Never colour-alone — every state is a distinct glyph *and* a distinct colour,
reusing the monitor's existing palette (terracotta `38;5;173`, amber `33`,
red `1;31`):

| State | Glyph | Colour |
|---|---|---|
| done | `✓` | dim green |
| in_progress, live container | `▶` | terracotta, bold |
| in_progress, no container (parked/orphan) | `⧗` | amber |
| open, eligible | `○` | default |
| open, waiting on a blocker | `◌` | dim |
| blocked | `⊘` | amber |
| needs-review / stuck | `!` | red |

Boxes for `done` use a dim border so the live frontier is what the eye lands on.

## 4. Transcript lines

Under each running box, up to two lines prefixed `⟩`, truncated to the box's
column span, sourced the same way the SESSIONS tab sources them. This is the
same two-line budget the SESSIONS tab moves to, so one extraction path serves
both.

## 5. Keys

| Key | Action |
|---|---|
| `Tab` / `S-Tab`, `←` / `→` | switch tab |
| `j` / `k`, `↓` / `↑` | scroll |
| `h` / `l` | pan horizontally (wide graphs) |
| `.` | recentre on the running layer |
| `g` / `G` | top / bottom |
| `n`, `C-g` | notes (unchanged) |
| `q` | quit |

The viewport auto-anchors on the shallowest running layer so "done above,
running here, queued below" holds without manual scrolling; any manual scroll
sticks until `.` recentres.

## Implementation note — awk

Every counter used as an **array subscript** must be explicitly zeroed. An
uninitialised awk variable stringifies to `""` in subscript context, so
`id[n] = $1` on the first record writes `id[""]` and silently drops the node.
This bit the prototype three separate times (`n`, `cnt[l]`, and `lay[i]` — the
last because `lay` is only *assigned* when a longer path is found, so every
layer-0 node kept an uninitialised value and the entire root layer vanished).
`BEGIN { n = 0 }` plus an explicit `for (i…) lay[i] = 0`.
