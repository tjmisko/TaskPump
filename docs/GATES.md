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
the filesystem. A gate is a child of the pump, so it inherits the whole resolved
configuration — every `TASKPUMP_*` key everything else sees, already discovered,
already promoted from its legacy spelling.

The pump additionally exports a handful of keys *derived from this run's flags*,
so a gate reads the value actually in force rather than the one in the file:

| Exported | Why a gate cares |
|---|---|
| `TASKPUMP_USAGE_CEILING` | `--usage-ceiling 80` reaches the gate as `80`; nothing wrote it to a conf. |
| `TASKPUMP_HEALTH_GATE`, `TASKPUMP_USAGE_GATE`, `TASKPUMP_DISK_GATE` | The run's own enable switches, so a gate kept in a custom chain can still honour them (§2.1 — note the pump *overwrites* two of these). |
| `TASKPUMP_HEALTH_WINDOW`, `TASKPUMP_USAGE_RESET_FILE`, `TASKPUMP_DISK_WATCHDOG` | The shipped gates' plumbing: `net-health`'s journal window, and two paths the pump has already resolved so a gate never has to guess where they are. |
| `TASKPUMP_CREDENTIALS` | Derived from the agent home **only when unset** — an operator's own value is never clobbered by a derivation of itself. |

None of that is required of your gate. It is what is *there*, and a third-party
gate that wants the run's ceiling rather than the file's should read the first
row.

**Output:** one line of human-readable reason on stdout or stderr, naming *what*
is wrong and, where possible, *what clears it*. Both streams are captured
together — the tools that predate this contract write their reason to stderr —
so it does not matter which you pick. The pump surfaces this line to the
operator and in the monitor, so it is the entire explanation anyone gets for
why a run stopped feeding. `disk 7GB free, below the 10GB floor` is a good
reason. `gate failed` is not.

A leading `<toolname>: ` is stripped before display, and only when it is a bare
token — so a tool that prefixes every diagnostic it emits does not have to
special-case this path, while a reason that merely *contains* a colon is left
intact. A gate that **fed** but had something to say is not lost either: its
line is collected and printed indented under the `GATE:` line in `--dry-run`
(§4), not into the tick log, because a persistent condition that logged every
tick would print for days.

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

### 1.0 How `TASKPUMP_GATES` is spelled, and how it fails

**`TASKPUMP_GATES` is a newline-separated list of command lines, and each
entry's first word must be an executable path.** Not a name, not a
comma-separated list. An entry whose first word is not an executable is
**skipped with a warning** and never consulted — which, on the gate seam, reads
as the gate having passed.

```bash
# Right — one per line, each an executable path, arguments after it. A relative
# path is resolved against the directory you run the pump from.
TASKPUMP_GATES="$HOME/code/TaskPump/gates/disk-low
$HOME/code/TaskPump/gates/claude-usage --gate --ceiling 80
./scripts/my-gate"
```

```bash
# Wrong, and silently so. Each of these consults ZERO gates:
TASKPUMP_GATES='disk-low,my-gate,claude-usage'   # one entry, not three
TASKPUMP_GATES='disk-low'                        # a bare name; nothing searches PATH
```

Both wrong forms produce a `tp-pump: gate not executable, skipping: …` line on
stderr and then a cheerful `GATE: feed-ok` for the rest of the run. The comma
form is the worse of the two, because the pump reads the whole string as **one**
entry — so a chain an operator believed was three gates deep is a completely
unmetered pump, and nothing in the plan says so.

Nothing in the plan says so including the place you would look. `--dry-run`
prints the chain as a `gates:` line (§4), and that line is built from the same
strings *before* the executability check — so a wired gate and a skipped one
print identically:

```
$ tp pump --phases T1..T9 --dry-run
gates: disk-low,my-gate,claude-usage         ← looks like a chain
tp-pump: gate not executable, skipping: disk-low,my-gate,claude-usage
…
GATE: feed-ok                                ← nothing was consulted
```

So read the warning, not the `gates:` line. The confirmation that a gate is
genuinely wired is its own output appearing indented under `GATE:` (§4), or the
gate actually pausing.

The relative form deserves the same suspicion for the same reason. `GATES` is
not one of the keys the config core anchors to the conf's own directory, so
`scripts/my-gate` is resolved against `$PWD` — which means the identical
configuration runs the gate from the repository root and silently skips it from
a subdirectory, printing `gates: my-gate` either way:

```
$ cd ~/project     && tp pump --phases T1 --dry-run   # …  my-gate: <its reason>
$ cd ~/project/sub && tp pump --phases T1 --dry-run   # …  gate not executable, skipping: scripts/my-gate
```

An absolute path costs nothing and cannot do that.

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

— credential freshness, plan utilization, free disk, in that order.
`net-health` also ships, but as **consumer-enabled** hardware policy: it joins
the chain (first) only when `TASKPUMP_HEALTH_GATE=1` — see its section below.
`tp pump --dry-run` prints the active chain as a `gates:` line, subject to
§1.0's caveat about what that line does and does not prove.

A configured `TASKPUMP_GATES` **replaces the whole chain** and is used verbatim.
The three disable flags still export their switches, so a gate that honours them
keeps working in a custom chain — which is also why a `net-health` entry you add
by hand still needs `TASKPUMP_HEALTH_GATE=1` to actually probe anything.

### 2.1 Turning a default gate off is not symmetric

Three different mechanisms hide behind "turn the gate off", and only one of them
does what the phrase suggests. This is the shape of it today, and it is worth a
minute because two of the three are traps:

| Gate | Flag | Conf key | What the key actually does |
|---|---|---|---|
| `net-health` | — | `TASKPUMP_HEALTH_GATE=1` | Works, and is the only way in: the gate is off by default and the key is what adds it to the chain. |
| `claude-usage` | `--no-usage-gate` | `TASKPUMP_USAGE_GATE` | **Nothing.** The pump initialises this switch to 1 unconditionally and re-exports it to every gate, overwriting whatever the conf or the environment said. |
| `disk-low` | `--no-disk-gate` | `TASKPUMP_DISK_GATE` | **Nothing**, for the same reason — and the flag additionally suppresses the background disk watchdog ([PUMP-MECHANISMS.md §3](PUMP-MECHANISMS.md#3-budget-gated-launching-that-never-kills-in-flight-work)). |
| `claude-token-fresh` | — | `TASKPUMP_TOKEN_GATE=0` | Reaches the gate, which then returns "feed" immediately. But there is **no `--no-token-gate` flag**, and the gate is emitted into the default chain unconditionally, so it stays on the `gates:` line and still prints its skip note. |

Demonstrated, not inferred: a run started with `TASKPUMP_DISK_GATE=0
TASKPUMP_USAGE_GATE=0 TASKPUMP_TOKEN_GATE=0` in its environment hands a probe
gate `disk_gate=1 usage_gate=1 token_gate=0`.

So: **to drop the usage or disk gate, pass the flag.** Setting the key looks
like it worked — no warning, no diagnostic — and the gate goes on metering. And
do not read a missing gate off the `gates:` line for the token gate: disabling
it leaves it in the chain, answering "feed" from inside.

This is a divergence between the tools and the keys `docs/CONFIG.md` documents,
not a design. It is filed as a bug; a patch release may not change which
switches work, but it can stop the documentation from promising the ones that
do not.

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

**It is also a user-runnable command**, and the only shipped gate that is:
`tp usage` execs it, so the meter behind a pause is readable by hand without
starting a pump. Besides `--gate` it answers `--percent` (the binding
utilization as an integer, or the literal `unknown`), `--json` (the full
reading — the per-window figures, their reset times, and the `windows[]` array
the monitor draws its bars from), and `--scan-logs <glob>`, which reads a
"limit reached / resets at" line out of agent logs and arms the reset backstop
from it. `tp usage --percent` is the fastest answer to "why did feeding stop";
[CLI-TOOLS.md](CLI-TOOLS.md) has the flag-level detail, and `tp usage --help`
is the copy that ships with the binary and cannot go stale.

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

Structurally it is the thinnest gate here — a delegate to
`tp disk-watchdog --gate`, which owns the threshold and answers it in one shot
with no loop, no cap-file write and no logging. Keeping one source for that
number is the point, because the watchdog *also* drives the live pool cap from
disk pressure, and a gate with its own private idea of "low" would fight it. It
fails open when the watchdog binary is missing or not executable, per §1.1.

The gate is only the polite half of the pump's disk discipline. The other half
is that a real run **starts that watchdog as a background process**, and at a
second, lower threshold it deletes build output rather than merely declining to
launch — see
[PUMP-MECHANISMS.md §3](PUMP-MECHANISMS.md#3-budget-gated-launching-that-never-kills-in-flight-work),
which is worth reading before an unattended drain.

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

Then add it to the ordered list — one command line per line, each starting with
an executable path (§1.0), and remember that naming the key at all replaces the
default chain, so anything you still want has to be named too:

```bash
TASKPUMP_GATES="/opt/taskpump/gates/disk-low
./scripts/my-gate
/opt/taskpump/gates/claude-usage --gate --ceiling 80"
```

Check it before you trust it. The gate you just added should appear in
`--dry-run` **and** produce no `gate not executable, skipping:` warning:

```bash
tp pump --phases T1..T9 --dry-run 2>&1 | grep -E 'gates:|skipping'
```

`gates/example-gate` is a working copy of the protocol with nothing in it —
start from that file rather than from this snippet if you would rather edit than
type.

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

Every shipped gate also answers `-h` / `--help` with its own header, which is
where its configuration keys and its fail-open conditions are written down.

Against the pump, `--dry-run` prints the active chain, the plan including the
gate decision, and its reason — and launches nothing:

```bash
tp pump --phases T1..T9 --dry-run
# gates: claude-token-fresh -> claude-usage -> disk-low
# GATE: feed-ok
#   claude-token-fresh: skipped: no claude credentials at /home/you/.claude/.credentials.json
```

The `gates:` line and the indented ones are different kinds of evidence, and
only one of them is worth much. `gates:` is the configured *list*, echoed back
before anything runs, so it proves you spelled the key in a form the pump could
split and nothing more — §1.0 shows it printing an entirely unwired chain. The
lines indented beneath `GATE:` come from gates that actually ran and had
something to say. That is the confirmation.

---

## 5. The third seam — pre-tick hooks

Gates and runners are the two seams everybody knows about. There is a third,
with the same shape — an executable, replaced by configuration — and it runs
every tick before the pump plans anything:

```bash
TASKPUMP_PRE_TICK_HOOKS="/opt/taskpump/hooks/gitignore-repair
/opt/taskpump/hooks/fs-guard"
```

**The contract:**

| | |
|---|---|
| **Input** | the repo root as `$1`, plus `TP_REPO_ROOT` in the environment and the whole inherited configuration |
| **Output** | anything worth telling the operator, on stdout or stderr (captured together) |
| **Exit `0`** | fine |
| **Non-zero** | the pump warns and carries on with the tick — a hook can never skip a tick |

The list is parsed by exactly the same rule as `TASKPUMP_GATES`
(§1.0): newline-separated command lines, first word an executable path, a
non-executable entry skipped with a warning.

**What is different from a gate is the output handling, and it is the part
worth copying.** A hook's output is logged, and it is sent to the notifier
**only when the text changes** since the last tick. The fingerprint lives in a
marker file, so the deduplication survives a supervisor restart, and a hook that
goes quiet clears the marker so the next occurrence notifies again. Without
that, a hook reporting a *persistent* condition — and every condition these
hooks report is persistent until a human fixes it — would fire a desktop
notification every tick for days. That is not a nuisance so much as a
correctness problem for the notifier: an operator who learns to dismiss the
pump's notifications will dismiss the one that mattered.

The two shipped hooks are the default chain, in this order:

- **`gitignore-repair`** — un-ignores the worktrees directory, from either
  direction. The `gh worktree` extension appends a bare `.worktrees/` line to
  `.gitignore` on every `worktree create`, which lands after the intentional
  negations and re-ignores every worktree; and an operator-global
  `core.excludesFile` can do the same from below, which it heals by appending
  negations to the repository's own `info/exclude`. It matters because **the
  pump refuses to launch into a gitignored worktree** — so without this hook the
  failure is a run that launches nothing, and the cause is in a file nobody
  edited on purpose.
- **`fs-guard`** — reads `git status --porcelain` on the primary checkout and
  reports every dirty path outside an allowlist: `.worktrees/`, the ledger
  checkout at `ops/`, and the integration trunk's lock and quarantine files.
  Agents work in worktrees and the reference runner mounts the primary
  read-only, so this should always be silent. It is the regression detector for
  that arrangement: if a future mount change hands a container a writable
  primary tree, edits start appearing where no agent should be able to make
  them, and this is what says so.

  Note what that allowlist is made of, because it decides how you fix a false
  alarm. It has **no entry for the supervisor's own state files** — those stay
  quiet only because `git status` does not report ignored paths, which is why
  README's adoption steps hand you an ignore list rather than an allowlist. So
  a new run file that nobody thought to ignore reports as primary
  contamination, every tick, and pushes a notification the first time. Adding
  it to `.gitignore` is usually the right repair; `TASKPUMP_FS_GUARD_ALLOWLIST`
  replaces the whole pattern and is the wrong tool for one file.

A third hook ships and is **not** in the default chain: `hooks/agent-preflight`
is TaskPump's own container pre-flight — the in-container, project-shaped half
of a launch, installing an `iptables` egress allowlist and smoke-testing the
image. It is a `TASKPUMP_PRE_FLIGHT` hook, run by the entrypoint inside the
container ([RUNNERS.md §4.4](RUNNERS.md#44-the-pre-flight-hook)), not a pre-tick
hook, and it is here as a worked example of what that other seam is for.

Setting `TASKPUMP_PRE_TICK_HOOKS` replaces the default chain, exactly as
`TASKPUMP_GATES` does — including replacing it with nothing.
