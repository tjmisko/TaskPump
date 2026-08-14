# Review gates — reviewer tasks in the DAG (#12)

Design note for `feat/review-gates`. Enhancement #12: one agent implements a
task, a separate agent inspects the result with an adversarial eye, and work
downstream of the task stays blocked until the review passes — scaling from one
reviewer to N parallel reviewers plus an adjudicator.

The incident this answers is structural, not historical: today the only checks
on an agent's work are mechanical (the build gate, the task's own tests, the
trunk merge gate), and nothing stops a downstream task from building on
unreviewed work the moment `complete` runs. Every drain so far has relied on a
human noticing a bad completion before its dependents launched. That is a race,
and the human loses it at 3am.

## The shape: reviews are ordinary tasks

TaskPump already has everything a gate needs — blockers, the eligibility
predicate, the DAG renderer, a state machine with sanctioned doors. So a review
is **a task the CLI synthesizes**, and the graph and the gating fall out of
machinery that is already tested and already drawn:

1. **`tp task review <impl-id>`** creates, under one state lock: N reviewer
   tasks blocked by the implementation task; an adjudicator task blocked by all
   reviewers when N > 1; and — the gate — every task that listed the
   implementation as a blocker gains the chain's *gate task* (the adjudicator,
   or the lone reviewer) as an **additional** blocker. Ids come from the
   phase's own namespace (next free `.N`); the id grammar is untouched.
2. **Gating is blockers, nothing else.** The eligibility predicate (§6:
   `open ∧ blockers done`), the state machine, and `tp-dag-render` are not
   modified. Reviewers become eligible only when the implementation is `done`;
   the adjudicator only when every reviewer is; downstream only when the gate
   is.
3. **`tp task verdict <review-id>`** records the outcome through existing
   doors. `--approve` completes the review task. `--request-changes` (gate
   only, findings required) appends the findings to the *implementation*
   task's body, reopens it exactly as `reopen`-from-`done` would (completion
   markers shed, prior commits preserved in the note), and re-arms the whole
   chain back to `open`. Because the implementation is `open` again, the
   reviews are ineligible until the fix lands and `complete` runs — the loop
   closes through the eligibility predicate with zero new predicate logic.
4. **Bounded futility.** `review_round` on the implementation task counts the
   rounds; a change-request that would need a round past `review_max_rounds`
   (default 3) instead parks the implementation `needs-review` with
   `scrub_reason: review rounds exhausted (N/N)` and the findings intact. No
   unbounded adversarial ping-pong; a human renders the final call.
5. **Only the gate moves state.** Panel reviewers record findings and approve
   (their report); a panel reviewer calling `--request-changes` is refused
   with a pointer to the adjudicator. Reviewers are independent — nothing
   surfaces one reviewer's findings to another; only the adjudicator reads
   them all, and it may approve over a lone objection.

New frontmatter, all optional with defined absence (= plain task), so the
change is MINOR under LEDGER-CONTRACT §1: `review_of`, `review_role`
(`reviewer|adjudicator`), `review_prompt` on review tasks; `review_round`,
`review_max_rounds` on the implementation task.

## Two consequences that are policy, not accident

**Honest reviewers are kept off the tripwires.** `heartbeat --end` credits a
cycle by commits touching `files:` — an honest reviewer commits nothing, so
the unmodified tripwire would call every reviewer `stuck` after three cycles
of reading code, which punishes exactly the agent doing its job. For
`review_role` tasks, `--end` therefore does not run the commit-productivity
check at all and leaves `consecutive_failed_iterations` untouched: a meter
that measures nothing must not drive a tripwire. The plan's literal rule ("a
recorded verdict counts as the productive act") was rejected as the
*mechanism* — the verdict completes the task, so `--end` never observes it,
and a careful reviewer on its fourth reading cycle would still have been
scrubbed `stuck`. The intent survives: the verdict is the productive terminal
act, and a wedged reviewer is still bounded by the turn budget (scrub parks at
0) and by heartbeat staleness.

**The frontier hides review tasks from ordinary pickups.** `next` and the
eligible walks of `ready` skip `review_role` tasks unless `--include-reviews`.
At phase grain, the same in-context agent that implemented `G3.1` would
otherwise run `next --phase G3` and claim the review of its own work in its
own session — a self-review, which is the one shape of review that is worse
than none because it *looks* like independent scrutiny. `ready --count` (the
drain test) still counts them: a pending review is open work, and a supervisor
that cannot dispatch reviews must read the range as **stalled, loudly** —
never as drained. Until pump dispatch lands (see below), a pump whose range
hits a review gate will report exactly that stall; that is the correct loud
behaviour, not a bug.

## Round semantics, precisely

`review` sets `review_round: 1` — round 1 is in progress from the moment the
chain exists. A change-request in round N with `N + 1 <= review_max_rounds`
appends findings (`## Review findings (round N, …)`), reopens the
implementation, re-arms the chain, and sets `review_round = N + 1`. A
change-request in round N with `N + 1 > review_max_rounds` appends the
findings, completes the gate task (its verdict is delivered), and parks the
implementation `needs-review` — `review_round` stays N, because no round N+1
ever begins. With the default of 3: at most three review rounds, at most two
automatic reopens, and the third rejection goes to a human.

## Alternatives rejected

- **A `review` status / new state-machine states.** A seventh status is a
  MAJOR bump (§1) and a tax on every consumer that reads the ledger — the
  monitor, the renderer, scrub, and every re-implementation would all learn a
  new vocabulary to express something blockers already express. Rejected.
- **A feed gate (`gates/review-pending`).** Feed gates govern the whole
  pump's *feed* and deliberately **fail open** (GATES.md §1.1). A review gate
  must hold one specific edge of the DAG shut and must *never* fail open — a
  review that fails open is not a review. Wrong seam entirely; the overlap in
  the word "gate" is why GATES.md now carries a disambiguation note.
- **Verdicts in a side file** (a `reviews/` index, state outside frontmatter).
  Breaks the ledger's core property — the directory is the whole state, it
  diffs, it merges, it survives the tools being deleted. Rejected on §2.
- **Rewiring downstream by *replacing* the implementation blocker with the
  gate.** Then a later `reopen` of the implementation would leave downstream
  gated only on a chain that is already `done` — open work building on
  reopened work. The gate is **added**; the implementation edge stays. This is
  the same class of scar as the workspace-first resolution: both sides look
  fine while the state drifts.
- **Shipping pump dispatch, briefs, and monitor badges now.** Dispatch of
  review units rides #11's task-grain unit abstraction (still open), and
  `libexec/tp-pump` is owned by a concurrent lane of this drain. Templates
  without a renderer and badges without a dispatcher are dead weight.

## Extension points (deliberate, documented, not speculative)

- **Pump dispatch of review units** (#12 stage 5, after #11): review tasks
  become always-task-grain dispatch units, worktree cut from the
  implementation branch, `review/` branch prefix, `TASKPUMP_REVIEW_*` config
  keys. `--include-reviews` on `next`/`ready` is the query surface a
  review-aware dispatcher uses; nothing else needs to change ledger-side.
- **Briefs** (stage 4): `templates/review-brief.md` /
  `adjudicator-brief.md`, spliced with the recorded `review_prompt`. The
  prompt path is already validated and recorded at chain creation so the
  ledger carries the review lens from day one.
- **Monitor affordances** (stage 6): a `[R]`/`[A]` badge from `review_role`,
  `review_of` in the header. Pure affordance — layout already falls out of
  `blockers:`.
- **Incremental findings.** If a findings-append verb ever exists, a recorded
  append since `--start` becomes the reviewer's productive act and the
  heartbeat inertness above narrows. Until then there is no within-cycle
  signal to measure, and pretending otherwise would be a silent wrong answer.

## What fsck says about all this

`tp task fsck` accepts ledgers that never heard of reviews (the fields are
verb-added: legal to omit, never stamped by `--fix`) and validates the surface
where it exists: `review_role` outside `reviewer|adjudicator` is a violation,
`review_of` naming no task in the ledger is a violation (the verdict verb
could never find the implementation), a review task reviewing itself is a
violation, and the `review_round`/`review_max_rounds` counters must be
integers. The conventions the verb establishes (a reviewer blocks on its
subject) are *not* checked — fsck checks the contract, and a hand-imported
chain wired differently fails loudly at `verdict` time, not silently.
