# Security Policy

TaskPump starts autonomous coding agents against a repository and keeps them
running for days with nobody watching. That is the product and the whole of the
security surface: the thing being supervised writes code, runs commands, and
holds the operator's credentials. This file is the reporting channel and the
trust boundary; the surface-by-surface accounting, and the posture tiers an
operator chooses between, are in
[docs/THREAT-MODEL.md](docs/THREAT-MODEL.md).

## Supported versions

Three versions have shipped and are tagged: `v0.1.0` (2026-08-13), `v0.2.0`
(2026-08-14) and `v0.2.1` (2026-08-19). The current one is in [VERSION](VERSION);
what changed in each is in [CHANGELOG.md](CHANGELOG.md).

| Version | Receives fixes |
|---|---|
| `0.2.1` (current) | Yes — on `main`, shipping at the next tag |
| `0.2.0` and earlier | No |

Nothing is backported: this is a pre-1.0 project on one line of development. The
one number in `VERSION` is the **ledger contract's** version as well as the
code's, and the contract is what decides which release a change may land in
([docs/LEDGER-CONTRACT.md §1](docs/LEDGER-CONTRACT.md#1-versioning)): a fix that
has to change the frontmatter schema, the status vocabulary, a state transition,
the eligibility predicate, the id grammar or an exit code is a MAJOR change and
waits for a release carrying one. Security work is milestoned on that basis; for
today's split, `gh issue list --label security --state open --json number,milestone`.

## Reporting a vulnerability

The intended channel is GitHub private vulnerability reporting: the **Report a
vulnerability** button on the repository's Security tab, which opens a draft
advisory only you and the maintainer can read.

**It is not switched on yet.** Checked 2026-08-19:

```
$ gh api repos/tjmisko/TaskPump/private-vulnerability-reporting
{"enabled":false}
```

Enabling it is a separate acceptance item on issue #66, the issue that asked for
this file. Until that button exists, open a public issue whose body is *"I have a
security report for TaskPump"* — no details, no reproduction — and wait to be
invited to a private advisory. There is no security email address, no PGP key, no
bounty, and no response-time commitment: this is one maintainer, and an SLA that
nobody is staffed to meet would be the defect this document exists to avoid.
Expect an acknowledgement in the advisory thread, a milestone against a release,
and credit in `CHANGELOG.md` if you want it. Reports travel best when they
reproduce against `tests/fixtures/generic-project/` rather than a real project.

## The security model, in one screen

**The runner is the boundary, and the easy one has none.** The default is
`runners/claude-docker` (`libexec/tp-pump:176`), the hardened path: the credential
file copied in with the refresh token stripped, so a container can authenticate
but never rotate the host's token
([RUNNERS.md §4.1](docs/RUNNERS.md#41-access-token-only-credentials)); an egress
allowlist ([§4.2](docs/RUNNERS.md#42-egress-allowlist)); and a read-only mount of
the primary *source tree*
([§4.3](docs/RUNNERS.md#43-read-only-primary-writable-workspace)) — narrower than
it sounds, and the full mount set is spelled out under "the kickoff brief" below.
It needs a container image TaskPump does not ship: with no `TP_IMAGE` set the
launch dies rather than guessing (`runners/claude-docker/runner.sh:194`).
`runners/local` needs nothing — "no image to build, no daemon to talk to"
(README.md:321-322) — and it is what the README's walkthrough configures at its
supervised first tick (`TASKPUMP_RUNNER=…/runners/local/runner.sh`,
README.md:381). It sandboxes nothing, and says so in its own header
(`runners/local/runner.sh:10-13`):

> ── IT DOES NOT SANDBOX ANYTHING ──
> The agent runs as you, with your permissions, your filesystem, your network and
> your credentials.

[RUNNERS.md §3.1](docs/RUNNERS.md#31-it-does-not-sandbox-anything) says it at
length. Under that runner nothing below is contained by anything. And two of the
hardened runner's layers are files carried by the repository being worked on
rather than by the runner: the pre-flight that installs the egress firewall is
pinned repo-relative (`taskpump.conf:75`, `TASKPUMP_PRE_FLIGHT=./hooks/agent-preflight`)
and runs as root with `--cap-add NET_ADMIN` (`runners/claude-docker/runner.sh:284`),
and the agent's permission ruleset is the repo's own root
`claude-settings-auto.json`, copied over the agent's `~/.claude/settings.json`
(`hooks/agent-preflight:64-70`). So the tree under audit configures the sandbox
meant to contain it (issue #78).

**TaskPump executes what the repository carries.** `taskpump.conf` is *sourced as
bash* with `allexport` on, not parsed (`lib/config.sh:176-184`), by every `tp` verb
before it looks at an argument — cloning a repository and running `tp task --help`
inside it runs whatever that file contains, as you (issue **#77**, milestone
`v0.3.0`). A ledger task id is interpolated into a command string that reaches a
host `eval` in `tp cleanup` (`libexec/tp-cleanup:263` into `:135`), and
`tp agent-watchdog` runs `tp cleanup --stuck` on a timer with no human present
(`libexec/tp-agent-watchdog:75`); a task file is a file an agent can write (issue
**#95**, milestone `v0.2.2`). With no build gate configured, the trunk gate runs
`cargo check --workspace` and then the worktree's own `./smoke_test.sh` when one
is executable (`libexec/tp-pump:1645-1647`), and a new worktree gets
`git submodule update --init --recursive` on the host unless a configured probe
file is present (`libexec/tp-pump:1521`), fetching whatever URLs the repository
names (#79).

**The kickoff brief asks; nothing enforces.** A launch is handed one of two
briefs — `templates/phase-drain-brief.md` at `--grain phase`,
`templates/task-brief.md` at `--grain task` (`templates/README.md`'s render map;
`--grain` is `libexec/tp-pump:351`) — and a consumer may point either key at its
own file. Both carry the same four boundaries — only your unit, never touch the
base branch, never write outside this worktree, the ledger has one writer — and
the task brief adds a fifth about its declared `files:`. Those are requests.
`runners/local` backs none of them, and `claude-docker`'s mount set
(`runners/claude-docker/runner.sh:251-269`) backs less than "read-only primary"
suggests:

- **Ledger in its own repository.** `$repo_root` is mounted `:ro`; the worktree,
  the ledger repo *and `$repo_root/.git`* are mounted read-write. The primary's
  source tree is protected, its ref database is not — one
  `git update-ref refs/heads/main HEAD` from inside the worktree moves the base
  branch every later worktree is cut from, no push and no credential involved.
  Reproduced in #82;
  [RUNNERS.md §4.3](docs/RUNNERS.md#43-read-only-primary-writable-workspace) says
  it outright: "an agent that wanted to could still move a ref".
- **Ledger inside the code repository** (`tasks/` in the same repo — TaskPump's
  own shape, and the README's walkthrough). The read-only primary mount and the
  read-write ledger mount name the same path, the runtime rejects duplicates, and
  the two collapse to a single read-write mount of the whole checkout. No part of
  the repository is read-only in this shape (#56).

So no shape backs "never write outside this worktree", and none backs "never
touch the base branch". The rest goes the same way: `tp task complete`, `block`
and `reopen` accept no claimant and read none (`libexec/tp-task:1077`, `:1146`,
`:1250`), so any agent can close a sibling's work (#83); the repository-root
`claude-settings-auto.json` the pre-flight installs allows `Bash(git:*)` and
`Bash(gh pr:*)` (`:9-10`), pre-approving the `git push` and `gh pr merge` the
brief forbids (#82); and `tp task claim` and `heartbeat` are self-service, so an
agent resets the turn budget and the failure-streak tripwires that constrain it
(#90). Read a brief as instructions to a cooperative agent, never as a control.

**Credentials.** Under `claude-docker` the agent's home is copied from the
operator's `~/.claude` in full — `cp -a "$HOST_CRED_MOUNT"/. "$AGENT_CLAUDE_DIR"/`
(`runners/claude-docker/entrypoint.sh:322`), transcripts from unrelated projects
included; only the OAuth *refresh* token is stripped (#81). `GITHUB_TOKEN`'s value
is passed in an `env` argv at every launch (`libexec/tp-pump:1579,1601`) and in a
`--setenv=` argv under `--detach` (`:2765`, `:2770`), which issue **#87**
(milestone `v0.2.2`) holds against the `/proc/<pid>/cmdline` rule that closing
issue #14 established and that the runner's own comments still cite
(`runners/claude-docker/entrypoint.sh:483`). Assume an agent you launch reads
every credential the launching user holds.

## Out of scope

- **`runners/local` running unsandboxed.** Documented design, stated in the
  runner's own header and in RUNNERS.md §3.1. Not a vulnerability.
- **A hostile repository executing its own `taskpump.conf`.** Known: issue #77,
  including its second variant, which needs no shell at all — under `set -a` a
  bare assignment to any name (`PATH=…`) is exported into the tool and every
  child it spawns. A new *instance* of the class — another repository-carried
  file that gets sourced or executed — is worth a report; a fresh reproduction of
  #77 is not.
- **An agent misbehaving inside permissions the operator granted it.** #82, #83
  and #90 already record that the brief's boundaries are unenforced.
- **Consumer-supplied gates, pre-flight hooks, images and agent commands** — the
  adopter's code, running in the adopter's posture.
- **Anything already on the tracker.** Check first:
  `gh issue list --label security --state open` (30 of them on 2026-08-19).

## Posture belongs to the operator

A tool that runs agents unattended has no security posture of its own; it has the
one its operator configured. The runner, the image, the pre-flight hook, the
permission ruleset, the egress profile and the repository you point it at are all
decided outside this repository, and they decide almost everything above. The
tiers those choices fall into are
[docs/THREAT-MODEL.md §5](docs/THREAT-MODEL.md#5-posture-guidance). Pick yours
before the first unattended drain, not after it.
