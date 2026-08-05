# GRAPH tab v2 — placement algorithm restructure

Supersedes the layout section of `DESIGN-monitor-dag.md`. Written 2026-08-05
after reviewing v1 against the live F79 graph.

**Status: built.** Two deviations from this document were made during
implementation and are recorded in the sections they affect — P2 merges dummy
chains per *target* rather than per edge, and P4 is Brandes–Köpf rather than the
priority method. Both are marked **AMENDED** below with the reason. Everything
else shipped as specified.

## Why v1 fails

**1. There is no x-coordinate assignment phase.** Layered graph drawing is four
phases — layer, order, **assign x**, route. v1 collapses the middle two: after
ordering picks a permutation, x is `ordinal × fixed pitch` from the left margin.
That is the "even line growing left to right", and it causes every complaint:

- `.10` cannot sit under `.6`, because its ordinal put it in column 11.
- `.2`'s and `.6`'s subtrees cannot separate — there are no variable gaps.
- `.6 → .10` must cross the full width, lacing through `.2`'s 11-way fan.

**2. Edges spanning more than one layer are silently dropped.** The router only
joins layer L to L+1. `F79.24` depends on `.7`, `.8`, `.10` (layer 2 → layer 6);
none of those three edges are drawn. `.7`, `.8`, `.10` are the only boxes in the
graph with no bottom port — visible in the 2026-08-05 screenshot. The graph
under-reports dependencies today.

## Invariants (never traded away)

- **I1** Every in-scope node drawn exactly once.
- **I2** Every dependency edge drawn, including multi-layer spans.
- **I3** A node is drawn strictly below all of its blockers.
- **I4** No overlapping boxes; minimum separation always preserved.
- **I5** Status readable without colour — glyph carries state, colour reinforces.
- **I6** Deterministic: same ledger → same picture. No randomness; stable
  tie-breaks by task id.

## Objectives, in priority order

When these conflict, the earlier one wins.

- **O1 Edge unambiguity.** Minimize crossings. Where a crossing is unavoidable
  it must render as a crossing (`┼`), never as a junction (`┬`/`┴`).
- **O2 Straightness.** Maximize pure-vertical edges. A parent with a single
  child sits directly above it. Multi-layer edges are straight columns.
- **O3 Subtree separation.** Sibling subtrees get a visible gutter; unrelated
  blocks never interleave.
- **O4 Compactness.** Last, deliberately. Width is cheaper than a tangle —
  the viewport pans.

## Pipeline

### P1 Layering — unchanged
Longest path over `blockers`. Fixpoint iteration, explicit zeroing.

### P2 Dummy chains — new, and mandatory for I2 — **AMENDED**
For every edge `u → v` where `lay[v] − lay[u] > 1`, insert dummy nodes, one per
intervening layer. A dummy is 1 column wide (not a box) and renders as a
vertical segment. This fixes the dropped edges *and* is what lets P3 and P4 see
long edges at all — before this they participated in neither.

**Amendment: one trunk per TARGET, not one chain per edge.** All of `v`'s far
blockers converge on a single column that descends into `v`; each far blocker
joins that trunk at the layer below itself. Every segment of a trunk carries
edges with one destination, so the merge costs no ambiguity — a reader tracing
down from any parent reaches `v` and nothing else. It also costs O(layers)
dummies per target instead of O(edges × layers): `F79.24` has 7 far blockers
spanning up to 4 layers, which is 3 dummies merged versus 18 unmerged. O4 ranks
last, but this is not a width-for-tangle trade — merging strictly *reduces*
edges and therefore crossings.

### P3 Crossing reduction — median + actual scoring
Median heuristic, alternating down/up sweeps, **keeping the best-scoring
permutation** — v1 blindly takes the last sweep and never counts anything. Add
a bilayer crossing counter (count inversions between adjacent layers) so
"best" is measured, not assumed. Dummies participate as ordinary vertices.

### P4 X-coordinate assignment — new; this is the core of v2 — **AMENDED**

**Amendment: Brandes–Köpf, not the priority method described below.** The
priority sketch re-lays every layer from scratch on each sweep, so the result
swings with sweep direction and no single sweep is right for the whole graph: a
down-sweep hangs the roots over the wrong end of a wide fan (`.2` landed above
its 11th child rather than its median), an up-sweep strands the leaves, and
scoring "keep the best sweep" just picks whichever lopsided one wins on the
cheaper direction. Measured on live F79, every down-sweep scored better than
every up-sweep and the accepted layout put `.1`/`.2`/`.6` over the right-hand
edge of a 130-column fan.

Brandes–Köpf targets the same objectives and makes **O2 a guarantee rather than
a tendency**: marking type-1 conflicts keeps inner (dummy-to-dummy) segments
strictly vertical, so trunks are straight columns by construction. It is
deterministic, and averaging the four (up/down × left/right) candidate layouts
removes the direction bias entirely rather than choosing a side. O3 rides on the
same separation function described below, which BK consumes directly.

One implementation note that cost a debugging pass: **BK must run in port-column
space, not left-edge space.** Aligning left edges lines a 9-column box up with a
1-column dummy at their left corners, so a straight trunk entering a box jogged
sideways by half a box width. Separation is expressed centre-to-centre
(`rgt(u) + 1 + gap + lft(w)`), and the mirrored runs swap the two half-widths.

The original priority-method design, retained for the record:

1. Seed each layer at minimum separation in its P3 order.
2. Assign priority: **dummy > high-degree > leaf**. Dummies rank highest so
   long edges stay straight columns (O2).
3. Iterate alternating down/up passes. Each node, in descending priority, is
   pulled toward the **median x of its neighbours in the adjacent layer**,
   displacing lower-priority nodes only as far as separation allows.
4. Repeat to a fixpoint or a pass cap.

This alone produces `.6` directly above `.10` (single child → vertical), and
lets `.2` centre over its 11-child block.

**Separation rule (realizes O3).** The gap between horizontally adjacent nodes
in a layer is `base_gap + bonus` where the bonus applies when the two nodes
**share no parent**. That is the cheap, direct expression of "don't let the
`.6` chain lace through the `.2` fan" — unrelated neighbours get pushed apart,
related siblings stay tight.

### P5 Routing — mostly unchanged
The existing greedy channel router, but it now only ever handles adjacent
layers (P2 guarantees it). Most edges become vertical stems needing no rail at
all, so the rail bands shrink on their own.

Two refinements landed with it:

**Rails are allocated per connected component, not per parent.** A pure fan-out
(one parent, many children) and a pure fan-in (many parents, one child) each
collapse to a single rail row; a component that fans both ways takes one row per
node on its *narrower* side. Either way a row carries exactly one node on the
routed side, so a row is never a which-goes-where guess (O1). On F79 this took
the layer-2→3 band from 6 rows to 4, and made `.11`/`.12 → .13` a single
`└┬─────────┘` instead of two stacked rails.

**Edge cells accumulate a direction bitmask (U/D/L/R) and are rendered to glyphs
once, after every edge is laid down.** Merging glyphs incrementally cannot
express "a vertical passes through a join": a trunk collecting four parents on
four rows drew a column of `┬` stubs that read as four disconnected edges. The
mask gives `├`/`┤` there, a genuine `┼` for a crossing, and corner glyphs at rail
ends — so a fan-out renders as `┌──────┴──────┐` rather than `┬──────┴──────┬`.

## Clutter reduction

With every node shown and full ids, the graph gets *wider*, not smaller — so
clutter has to come from somewhere other than hiding nodes:

- **Straightness** (O2) is the main lever: laced rails become vertical stems.
- **Edge emphasis follows status.** An edge whose *both* endpoints are done
  wears the done nodes' green (`0;38;5;65`), so a finished parent joined to
  finished children reads as one settled green subtree instead of a green box,
  a grey line, another green box. Everything touching unfinished work renders on
  the bright rail (`0;38;5;249`).

  **Per edge, not per rail component.** A band is one component, but it
  routinely carries a finished link alongside a dummy trunk heading for
  something still open; at component granularity that one unfinished target
  dragged the settled links back to the bright tier — which is what kept
  `F79.1 → F79.2` grey while both were done. Cells shared by several edges
  resolve to bright automatically, since `addm()` marks a cell normal when *any*
  edge through it is undimmed.

  Both tiers must stay legible. The first implementation used a dimmed 238,
  which on a dark background is indistinguishable from no edge at all — and on a
  nearly-finished phase that is most of the graph. The distinction says "behind
  you" vs "ahead of you", never "not drawn".
- **Fewer crossings** (O1, now actually measured).

## Node rendering

Boxes stay narrow: id + status glyph.

**Full ids, in every range** (reversed 2026-08-05; this section previously
retained v1's compact labels). Dropping the `F79.` prefix inside a single-phase
range was worth ~4 columns per box — 48 on F79's widest layer — and the argument
was that a shortened *label* hides nothing while the status bar carries the full
id. In use that traded the wrong thing: `.17` is not something you can say out
loud, paste into `arachne-task`, or match against the pump's log without
mentally re-attaching the phase every time, and you do that far more often than
you run out of width. `--compact` still asks for the short form when width
genuinely binds.

Green is the progress axis, so a glance at the graph reads as *how far along is
this*: landed work recedes, the one task an agent is on right now stands out,
and anything not yet started is neutral.

| State | Glyph | Colour | SGR |
|---|---|---|---|
| done | `✓` | dark faded green | `0;2;38;5;65` |
| running (live, elected) | `▶` | mid green | `0;38;5;71` |
| in_progress, not running | `⧗` | amber | `0;38;5;179` |
| open, eligible | `○` | grey | `0;38;5;250` |
| open, waiting on a blocker | `◌` | dim grey | `0;2;38;5;244` |
| blocked | `⊘` | muted red | `0;38;5;131` |
| needs-review / stuck | `!` | bright red | `0;1;38;5;203` |

**Every sequence re-opens with `0;`, and that is load-bearing.** SGR attributes
are sticky: a bare `\033[38;5;245m` sets only the foreground, so the `2` (dim)
belonging to one `done` box stays on for every cell painted after it. The first
implementation emitted this whole palette correctly and still looked uniformly
grey, because on a mostly-done phase the first dim box washed out the rest of
the frame. The same applies to the rail/gutter colours in `flush()`, which
alternate with node colours cell by cell.

The palette is duplicated between `hue()` in `arachne-dag-layout.awk` (the
canvas) and the `ST_*` constants in `arachne-monitor` (the legend, the status
bar, the session rows) — two languages, one vocabulary; they must move together.

The cursor-selected node is drawn with a **heavy border** (`┏━┓`), so selection
is not colour-dependent (I5).

## Cursor + top status bar

Arrow keys navigate the graph; on the GRAPH tab they no longer switch tabs
(Tab / Shift-Tab still do). On the SESSIONS tab `←` / `→` keep their existing
tab-switch meaning — there is nothing there to navigate, and the muscle memory
is worth more than the symmetry.

Navigation is testable headlessly: `--cursor <id>` pins the selection and
`--moves <hjklgG.o>` replays keystrokes in one-shot mode, so the assertions run
without a pty — the same trick `--tab` plays for the graph itself.

| Key | Action |
|---|---|
| `←` `→` / `h` `l` | previous / next node within the layer |
| `↑` `↓` / `k` `j` | nearest node in the layer above / below, **preferring a connected one** (blocker or dependent) over nearest-by-x |
| `o` / `Enter` | open the selected task's file in a new editor window |
| `Tab` / `S-Tab` | switch tab |
| `PgUp` / `PgDn` | page the viewport without moving the cursor |
| `.` | recentre on the running node |
| `g` / `G` | first / last layer |
| `q` | quit |

`o` exists because the status bar can only ever hold the *summary* — goal,
budget, blockers. The moment a node raises a real question the answer is in its
markdown, and re-deriving `ops/task-loop/tasks/<id>.md` by hand from a node
labelled `.4` is exactly the friction the tab was built to remove.

It spawns a **new terminal window** (wezterm, `--class arachne-task` so a
Hyprland windowrule can float or place it), fully detached via `setsid` so the
dashboard keeps painting at its 1s cadence and the editor outlives it. With no
display — a plain tty, ssh — there is no window to open, so it falls back to
handing over *this* terminal, which the notes popout already knows how to do
and undo. `ARACHNE_MONITOR_OPEN_CMD` replaces the spawn wholesale.

`Enter` needs naming explicitly in `read_key`: it is `read`'s own delimiter, so
it arrives as an empty *successful* read, which is otherwise indistinguishable
from the interval timeout.

The cursor's default landing spot is the live agent's task, falling back to the
shallowest ready task, then the root. `.` returns to it.

**The viewport follows the cursor** — auto-pan and auto-scroll to keep the
selection visible. This is what makes a graph wider than the terminal usable,
and it is why panning stays viable as the overflow policy.

Selecting a node fills a **top status bar** (under the pump summary, above the
rule) with its detail — the legend renders there when nothing is selected:

```
 SESSIONS ┤ GRAPH ├    Tab switch · ↑↓←→ move · q quit
pump[F79]: running  |  2 ready · 4 open
F79.5   ○ ready · 3 turns · blockers F79.3 ✓ F79.4 ✓ · feat/f79
  missing_const_for_fn (515) + redundant_clone (81) — need human judgement
────────────────────────────────────────────────────────────────────────
```

Detail fields: id, status, turn budget, resume attempts, claimed branch,
blockers with their statuses, and the task's `goal` (falling back to `title`).

## Viewport clipping

A whole-corpus graph is ~9000 columns wide. Building those lines in full costs
seconds of string reallocation for output nothing can show, so the renderer
takes `--cols` and the monitor passes its terminal width. This is what keeps the
all-phases fallback at 279ms instead of 7.9s; F79 renders in 52ms.

## Test obligations

Beyond the existing 25 renderer cases:

- **I2 guard:** a fixture with a 3-layer edge span asserts the edge is drawn —
  the exact bug v1 shipped. Assert the source box has a bottom port and the
  target has a top port.
- **O2 guard:** single-child parent is x-aligned with its child (assert equal
  port columns), and a dummy chain is a straight column.
- **O3 guard:** two nodes in a layer sharing no parent are separated by more
  than the base gap.
- **O1 guard:** crossing count on a known fixture does not regress.
- **Determinism:** two runs byte-identical.
- Cursor: movement stays in bounds; `↑`/`↓` prefer a connected node; viewport
  follows the selection.
