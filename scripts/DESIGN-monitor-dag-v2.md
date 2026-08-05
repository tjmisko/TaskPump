# GRAPH tab v2 — placement algorithm restructure

Supersedes the layout section of `DESIGN-monitor-dag.md`. Written 2026-08-05
after reviewing v1 against the live F79 graph.

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

### P2 Dummy chains — new, and mandatory for I2
For every edge `u → v` where `lay[v] − lay[u] > 1`, insert a chain of dummy
nodes, one per intervening layer. A dummy is 1 column wide (not a box) and
renders as a vertical segment. This fixes the dropped edges *and* is what lets
P3 and P4 see long edges at all — today they participate in neither.

### P3 Crossing reduction — median + actual scoring
Median heuristic, alternating down/up sweeps, **keeping the best-scoring
permutation** — v1 blindly takes the last sweep and never counts anything. Add
a bilayer crossing counter (count inversions between adjacent layers) so
"best" is measured, not assumed. Dummies participate as ordinary vertices.

### P4 X-coordinate assignment — new; this is the core of v2
Priority method:

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

## Clutter reduction

With every node shown and full ids, the graph gets *wider*, not smaller — so
clutter has to come from somewhere other than hiding nodes:

- **Straightness** (O2) is the main lever: laced rails become vertical stems.
- **Edge emphasis follows status.** Edges between two done nodes render dim;
  edges touching the live frontier render at normal weight. The completed
  history recedes without disappearing.
- **Fewer crossings** (O1, now actually measured).

## Node rendering

Boxes stay narrow: full id + status glyph, e.g. `│ F79.24 ◌ │`.

| State | Glyph | Colour |
|---|---|---|
| done | `✓` | dark green |
| running (live container) | `▶` | **bright green, bold** |
| in_progress, no container | `⧗` | amber |
| open, eligible | `○` | bright neutral |
| open, waiting on a blocker | `◌` | dim grey |
| blocked | `⊘` | orange |
| needs-review / stuck | `!` | red |

The cursor-selected node is drawn with a **heavy border** (`┏━┓`), so selection
is not colour-dependent (I5).

## Cursor + top status bar

Arrow keys navigate the graph; they no longer switch tabs (Tab / Shift-Tab
still do).

| Key | Action |
|---|---|
| `←` `→` / `h` `l` | previous / next node within the layer |
| `↑` `↓` / `k` `j` | nearest node in the layer above / below, **preferring a connected one** (blocker or dependent) over nearest-by-x |
| `Tab` / `S-Tab` | switch tab |
| `PgUp` / `PgDn` | page the viewport without moving the cursor |
| `.` | recentre on the running node |
| `g` / `G` | first / last layer |
| `q` | quit |

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
