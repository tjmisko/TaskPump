# Gates

A gate answers one question, every tick, before the pump launches anything:

> Is starting **new** work right now a bad idea?

That is the entire scope. A gate never stops work already running, never fails a
task, and never decides anything about correctness. It governs the *feed*.

> **Not to be confused with review gates.** A *feed* gate (this document)
> pauses the whole pump's launching, and deliberately fails open (§1.1). A
> *review* gate holds specific downstream tasks shut until a reviewer task in
> the DAG renders its verdict — it is made of ordinary tasks and `blockers:`,
> not of this plugin seam, and it must never fail open: a review that fails
> open is not a review. See
> [LEDGER-CONTRACT.md §5.12](LEDGER-CONTRACT.md#512-review--verdict--review-gates).

---

## 1. The contract

A gate is **an executable**. Anything runnable works — a shell script, a compiled
binary, a Python file — because the interface is the process interface.

**Input:** none required. A gate reads whatever it needs from the environment and
the filesystem. The pump passes its configuration through, so a gate sees the
same `TASKPUMP_*` keys everything else does.

**Output:** one line of human-readable reason on stdout or stderr, naming *what*
is wrong and, where possible, *what clears it*. The pump surfaces this line to
the operator and in the monitor, so it is the entire explanation anyone gets for
why a run stopped feeding. `disk 7GB free, below the 10GB floor` is a good
reason. `gate failed` is not.

**Exit code:**

| Exit | Meaning | Pump's response |
|---|---|---|
| `10` | **Pause launching.** The condition named on stdout holds. | Stop launching new agents. Running agents are untouched. Re-ask next tick. |
| `0` | **Feed.** | Launch as normal, up to the pool cap. |
| anything else | **Broken gate.** | **Fail open** — feed anyway, with a warning naming the gate and its exit code. |

Gates are consulted in the order given by `TASKPUMP_GATES`. The **first** gate to
return 10 short-circuits: its reason becomes the pause reason, and later gates are
not run. Order gates cheapest-first, so a local file check runs before a network
probe.

### 1.1 Two rules that are not negotiable

**A gate never kills a running agent.** Pausing costs a run some throughput.
Killing an in-flight agent destroys the most expensive thing in the system —
possibly hours of work that was never committed. Every condition a gate measures
is a statement about the *near future* ("we are nearly out of X"), and none of
them are improved by discarding work already done. If you find yourself wanting a
gate that kills, what you actually want is a watchdog, and it belongs outside the
feed path.

**A gate fails open.** A gate that errors, times out, or is missing lets the run
proceed. This is deliberate and it is the part people want to change.

The argument: a meter that cannot be read is not evidence of a problem. If an
unreachable usage endpoint paused the pump, every transient network blip would
wedge a multi-day unattended run — and the failure mode of the safety mechanism
would be strictly worse than the failure it prevents, because at least the
original failure is visible. Gates are **governors, not interlocks**. The thing
that enforces safety is the sandbox the agent runs in; the gate only decides
whether now is a good moment.

A corollary for gate authors: **handle your own errors and return 0.** A gate
that cannot reach its meter should say so on stdout and exit 0, not propagate a
curl failure. Fail-open is the pump's backstop, not your error handling.

---

## 2. The shipped gates

With no `TASKPUMP_GATES` configured, the pump consults **the default chain**:

> `claude-token-fresh` → `claude-usage` → `disk-low`

— credential freshness, plan utilization, free disk, in that order, each
droppable via its own `--no-*-gate` flag or enable key. `net-health` also ships,
but as **consumer-enabled** hardware policy: it joins the chain (first) only
when `TASKPUMP_HEALTH_GATE=1` — see its section below. `tp pump --dry-run`
prints the active chain as a `gates:` line, so what is actually wired is one
command away.

### `claude-usage` — plan utilization

Reads the OAuth usage endpoint (the same meter the Claude Code status toolbar
reads) and pauses at a configured utilization ceiling, default 95%.

The binding figure is the maximum across the windows that actually constrain the
run — the 5-hour session window and the relevant weekly windows — so whichever
limit is closest to biting is the one that governs. A cache with a short TTL
keeps the tick cheap and shares state with the toolbar.

Also honors a **reset-backstop window**: a hard pause until a known reset time,
which can be set from an agent log that reported hitting a limit. Belt and
suspenders for the case where the meter and reality disagree.

This gate is what makes a multi-day drain self-throttling rather than
plan-exhausting. It fails open — offline, missing token, absent `curl`/`jq`, or
no fresh cache all report utilization as unknown and feed.

Configured by `TASKPUMP_USAGE_CEILING` and the `TASKPUMP_USAGE_*` plumbing keys.
No token ever appears on a command line or in output.

**On a host with no Claude credentials it skips**, feeding with one line:

```
claude-usage: skipped: no claude credentials at ~/.claude/.credentials.json (usage gate feeds; nothing to meter)
```

That is a different sentence from the fail-open line (`bind_percent unknown —
meter unreachable`) on purpose. "There is no meter here" is permanent and
expected — it is what a consumer driving a non-Claude agent should see — while
"the meter is unreachable" is transient and worth watching. An operator who
cannot tell them apart waits for a recovery that is never coming.

Nothing is cached on either path: the usage cache is only ever written from a
payload that parsed, so an unread meter can never later be mistaken for a
reading.

### `claude-token-fresh` — credential expiry

Pauses when the host's OAuth access token is within a margin (default 600s) of
expiring, or already expired.

This exists because of the runner's credential model: containers receive an
**access-token-only** copy of the credentials and are physically unable to
refresh (see [RUNNERS.md §4](RUNNERS.md#4-the-claude-docker-reference-runner)).
The host owns rotation. Launching a container against an about-to-expire token
produces an agent that 401s immediately and dies, burning a relaunch cycle and a
workspace for nothing.

The gate clears as soon as a host-side session writes a fresh token. During a
long **headless** run this is the gate most likely to pause you, and the fix is
on the host, not in the pump.

**On a host with no Claude credentials it skips**, feeding with one line on
stderr and never exit 10:

```
claude-token-fresh: skipped: no claude credentials at ~/.claude/.credentials.json
```

The same for a file that is unreadable, is not valid JSON, or carries no OAuth
expiry — all of them are *absent input*, not a stale token. A credentials file
that is present and readable is measured exactly as before.

The skip is loud on purpose. This gate is in the default chain, so it runs on
hosts driving some other agent entirely; a silent feed there would be
indistinguishable from a gate that looked and approved, and those are opposite
facts about how protected the run is. The line goes to **stderr** because stdout
is reserved for the pause reason (§1) — a skip is not a pause.

### Where a skip shows up

`tp pump --dry-run` prints what a *feeding* gate had to say, indented under the
gate line:

```
GATE: feed-ok
  claude-token-fresh: skipped: no claude credentials at /home/you/.claude/.credentials.json
  claude-usage: skipped: no claude credentials at /home/you/.claude/.credentials.json (usage gate feeds; nothing to meter)
```

The tick loop stays quiet about it: a persistent condition — and "this host has
no Claude credentials" is as persistent as they get — would otherwise print
every tick for days. The plan is the mode whose job is explaining what the chain
decided; that is where the explanation belongs.

### `disk-low` — free space

Pauses when free space on the working filesystem drops below a floor. Agents
generate build output prodigiously; a multi-day run with several workspaces can
fill a disk, and every failure that follows is confusing.

It shares its threshold with the disk watchdog, so the "pause launching" floor
and the "reclaim now" floor are one knob rather than two that can disagree.
Reclaim is separate from the gate: pausing buys time, reclaiming buys space.

### `net-health` — host network wedge (shipped, consumer-enabled)

Pauses when the kernel journal shows a driver wedge signature within a recent
window.

**This gate is host-hardware policy, so it ships off**: it is not in the default
chain, and stays inert until a consumer sets `TASKPUMP_HEALTH_GATE=1`, which
puts it at the head of the chain. It stays shipped because its detection logic
is a worked example of a real gate — and because of where it comes from: it
matches `brcmfmac` firmware-hang signatures specific to Apple-Silicon WiFi,
where the aggregate packet load of many simultaneous streaming agents starves
the RX ring and hangs the firmware until the device is reset. Nothing about
that generalizes; on other hardware the gate would match nothing and cost a
journal read per tick, which is exactly why enabling it is the consumer's call
(the reference consumer pins `TASKPUMP_HEALTH_GATE=1` in
`examples/arachne.conf`). Note the key gates the *probe*, not just the chain
entry: a `net-health` line in a custom `TASKPUMP_GATES` also needs
`TASKPUMP_HEALTH_GATE=1` to actually look.

Its **recovery half deliberately lives consumer-side.** Detecting a wedge and
pausing is a feed decision, so it belongs in a gate. Reloading a kernel module
requires root, touches the host, and is specific to one driver — so it stays in
the consumer's own tooling (Arachne keeps a separate watchdog for it). TaskPump
observes; the consumer intervenes. Keeping that split is what stops a task
supervisor from acquiring the right to `modprobe`.

### `example-gate` — the template

A minimal, commented gate that demonstrates the protocol and does nothing. Copy
it to write your own.

---

## 3. Writing a gate

```bash
#!/usr/bin/env bash
# my-gate — pause launching while the release branch is red.
set -euo pipefail

# Fail open on anything we cannot determine.
command -v gh >/dev/null 2>&1 || exit 0

status="$(gh api repos/:owner/:repo/commits/main/status \
            --jq .state 2>/dev/null || true)"
[[ -n "$status" ]] || exit 0        # could not read the meter: feed

if [[ "$status" == "failure" ]]; then
  echo "main is red; not starting new work until CI is green"
  exit 10
fi

exit 0
```

Then add it to the ordered list:

```bash
TASKPUMP_GATES='disk-low,my-gate,claude-usage'
```

Checklist for a gate you intend to run unattended:

- **Cheap.** It runs every tick, for days. Cache anything expensive.
- **Silent when feeding.** Output only when pausing; a gate that prints on the
  happy path floods the log.
- **Specific in its reason.** Name the measurement and the threshold. The
  operator reading it at 3am has no other context.
- **Self-clearing.** A gate must be able to return 0 again on its own. A gate
  that requires manual intervention to clear should say so in its reason, so the
  pause does not look like a stall.
- **Fails open by construction.** Every path that cannot determine an answer
  exits 0.

---

## 4. Testing a gate

Gates are ordinary executables, so test them by running them:

```bash
./gates/my-gate; echo "exit=$?"
```

Against the pump, `--dry-run` prints the active chain, the plan including the
gate decision, and its reason — and launches nothing:

```bash
tp pump --phases T1..T9 --dry-run
# gates: claude-token-fresh -> claude-usage -> disk-low
```

That is the fastest way to confirm a gate is wired, ordered where you expect, and
saying what you think it says.
