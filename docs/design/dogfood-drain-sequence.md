# The G-plan drain sequence

How the generalization ledger (`tasks/G*.md`) gets drained, stage by stage.
Each stage names its operator — the pump, or a hand — because three of these
phases must never run unattended. Written 2026-08-12, alongside the G0 tasks.

The standing rule, borrowed from Arachne's F90.4: **anything that pushes to a
remote, cuts a release, or works outside this repository is hand-run.** The
pump's job here is the mechanical middle.

## Stage 0 — readiness (hand)

Work `G0.1` and `G0.2` by hand or with a directly-supervised session. The pump
cannot be trusted with this ledger until both are done:

- `G0.1` — `tp pump` cannot parse a `G1..G5` range today, and the failure is
  swallowed into an "idling green" empty plan. Interim workaround for any
  pump invocation before the fix: **comma lists** (`--phases G1,G2`), which
  take the code path that works.
- `G0.2` — the launch path still assumes Arachne artifacts (an `ops/` ledger,
  `scripts/arachne-task`, the `arachne` image). Until the conf pins land, a
  real launch fails after the plan looks fine.

**Exit criteria:** `tp pump --phases G1..G5 --dry-run` prints a five-phase
plan with no warnings, and one supervised `--once` tick has taken a real agent
through claim → work → complete on this repository.

## Stage 1 — G1, neutral defaults (pump, supervised start)

```bash
tp pump --phases G1 --dry-run     # read it first, every time
tp pump --phases G1 --jobs 1
tp monitor --watch                # second terminal
```

One phase, one agent, sequential tasks: G1.1 → G1.2 → the five flips →
G1.8. Watch the first two tasks complete before leaving it unattended — they
are docs/test tasks, cheap to verify, and they prove the loop. The pump exits
0 when `tp task ready --phases G1 --count` reaches zero, or 3 on a genuine
deadlock.

`G5.1` (the F90 addenda draft) can be worked by hand any time during this
stage — it needs the Arachne exploration context more than it needs the pump.

**Do not run the pump across the end of this stage.** G1 changes the tools'
own defaults; the running supervisor keeps its old code, but a restart
mid-merge picks up flipped defaults against un-flipped state files. Drain,
exit, merge, then proceed.

## Stage 2 — G2, release (hand only, pump stopped)

G2.1 (docs reconcile, commit the README rewrite), G2.2 (full suite + CI), then
G2.3 (`VERSION`, annotated `v0.1.0`, push). Never through the pump: this stage
pushes to origin and cuts the tag that Arachne pins. Verify no pump process
survives from stage 1 before starting (`tp cleanup --dry-run` shows what is
live).

**Exit criteria:** `git ls-remote --tags origin` shows `v0.1.0`; Arachne's
F90.4 notified.

## Stage 3 — G3 + G4, runner v2 and adoption (pump)

```bash
tp pump --phases G3,G4 --dry-run     # G3..G4 once G0.1 has landed
tp pump --phases G3,G4 --jobs 2
```

Two independent phases, so two agents are safe — the file overlap between
them is one doc (`docs/RUNNERS.md`), and the trunk gate absorbs it. Both
phases are additive post-tag work; this is the stage the pump was built for,
and by its end the pump is strictly better at this job (runner-list liveness,
a local runner, `tp init`/`fsck`).

**Exit criteria:** `tp task ready --phases G3,G4 --count` is 0; CHANGELOG's
Still-Arachne-shaped list is empty.

## Stage 4 — G5, the Arachne handoff (hand)

- File the `G5.1` addenda into Arachne's ops ledger (`arachne-task create`
  from the Arachne checkout), then delete the addenda doc here per its spec.
- Work `G5.2` from the Arachne checkout: the byte-equivalence re-check of the
  F80 dry-run against tagged v0.1.0. The pump cannot do this — it operates on
  the wrong repository by construction.

**Exit criteria:** the equivalence record is in Arachne's ops handoff thread,
and F90.4/F90.5 are unblocked with the result. From there the baton is
Arachne's: submodule pin, shims, canary drain.

## Standing cautions

- **Self-hosting skew.** Agents in worktrees run the worktree's copy of the
  tools against the shared ledger; the supervisor runs the primary's copy.
  Inside one stage that skew is bounded by the phase's own changes; across
  stage boundaries it is not — hence the drain-exit-merge discipline at every
  stage edge, and never restarting a pump over a half-merged tree.
- **Usage governor.** The default 95% ceiling and the token/disk gates apply
  as on any drain; `tp pump` pauses feeding, never kills in-flight work. A
  multi-day unattended stretch is only expected in stage 3.
- **This document retires** when stage 4's exit criteria are met; the ledger
  and CHANGELOG carry the durable record.
