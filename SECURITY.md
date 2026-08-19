# Security Policy

TaskPump starts autonomous coding agents against a repository and keeps them
running for days with nobody watching. That is the product and the whole of the
security surface: the thing being supervised writes code, runs commands, and
holds the operator's credentials. This file is the reporting channel and the
trust boundary; the full accounting — every surface, every attacker, and the
posture tiers an operator chooses between — is
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
**ledger contract** is versioned separately from the code
([docs/LEDGER-CONTRACT.md §1](docs/LEDGER-CONTRACT.md#1-versioning)), so a fix
that must change behaviour can be held for a release permitted to change it — of
the 30 open issues labelled `security`, 10 are milestoned `v0.2.2` and 20 `v0.3.0`.

## Reporting a vulnerability

The intended channel is GitHub private vulnerability reporting: the **Report a
vulnerability** button on the repository's Security tab, which opens a draft
advisory only you and the maintainer can read.

**It is not switched on yet.** Checked while writing this file:

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
allowlist ([§4.2](docs/RUNNERS.md#42-egress-allowlist)); a read-only primary
checkout ([§4.3](docs/RUNNERS.md#43-read-only-primary-writable-workspace)) — that
last one only where the ledger is a repository of its own, since the ordinary
single-repo shape collapses both mounts into one read-write mount of the checkout
(`runners/claude-docker/runner.sh:257-261`, issue #56). It needs a container image
TaskPump does not ship, so a real run aborts until you build one. `runners/local`
needs nothing, which is why the README's adoption walkthrough configures it and
why a first drain tends to run under it. It sandboxes nothing, and says so in its
own header (`runners/local/runner.sh:10-13`):

> ── IT DOES NOT SANDBOX ANYTHING ──
> The agent runs as you, with your permissions, your filesystem, your network and
> your credentials.

[RUNNERS.md §3.1](docs/RUNNERS.md#31-it-does-not-sandbox-anything) says it at
length. Under that runner nothing below is contained by anything. And half of
§4.2 belongs to the consumer rather than the runner: the egress firewall and the
agent's permission ruleset are both files carried by the repository being worked
on, so a repository can configure the sandbox meant to contain it (issue #78).

**TaskPump executes what the repository carries.** `taskpump.conf` is *sourced as
bash* with `allexport` on, not parsed (`lib/config.sh:176`), by every `tp` verb
before it looks at an argument — cloning a repository and running `tp task --help`
inside it runs whatever that file contains, as you (issue **#77**, milestone
`v0.3.0`). A ledger task id reaches a host `eval` in `tp cleanup`
(`libexec/tp-cleanup:135`), and `tp agent-watchdog` runs `tp cleanup --stuck` on a
timer with no human present; a task file is a file an agent can write (issue
**#95**, milestone `v0.2.2`). The trunk build gate runs the worktree's own
`./smoke_test.sh` when one is executable (`libexec/tp-pump:1646`), and every
worktree gets `git submodule update --init --recursive` on the host
(`libexec/tp-pump:1521`), fetching whatever URLs the repository names (#79).

**The kickoff brief asks; nothing enforces.** The Boundaries section of
`templates/phase-drain-brief.md` is what every launched agent is handed: only this
phase, never touch the base branch, never write outside this worktree, the ledger
has one writer. Those are requests. The filesystem backs the worktree boundary
only under the container runner and only in the two-repository shape above, never
under `runners/local` (#56, #92); `tp task complete`, `block` and `reopen` check
no claimant, so any agent can close a sibling's work (#83); the shipped
`claude-settings-auto.json` allows `Bash(git:*)` and `Bash(gh pr:*)` (lines 9-10),
pre-approving the `git push` and `gh pr merge` the brief forbids (#82); and the
turn budget and heartbeat tripwires are writable by the agent they constrain
(#90). Read a brief as instructions to a cooperative agent, never as a control.

**Credentials.** Under `claude-docker` the agent's home is copied from the
operator's `~/.claude` in full, transcripts from unrelated projects included
(#81), and `GITHUB_TOKEN`'s value is passed in `env` argv at launch and at
`--detach` (#87) — the `/proc/<pid>/cmdline` exposure that closed issue #14 set a
rule against, and that the runner's own comments still cite
(`runners/claude-docker/entrypoint.sh:483`). Assume an agent you launch reads
every credential the launching user holds.

## Out of scope

- **`runners/local` running unsandboxed.** Documented design, stated in the
  runner's own header and in RUNNERS.md §3.1. Not a vulnerability.
- **A hostile repository executing its own `taskpump.conf`.** Known: issue #77,
  including the variant that needs no shell metacharacters. A new *instance* of
  the class — another repository-carried file that gets sourced or executed — is
  worth a report; a fresh reproduction of #77 is not.
- **An agent misbehaving inside permissions the operator granted it.** #82, #83
  and #90 already record that the brief's boundaries are unenforced.
- **Consumer-supplied gates, pre-flight hooks, images and agent commands** — the
  adopter's code, running in the adopter's posture.
- **Anything already on the tracker.** Check first:
  `gh issue list --label security --state open` (30 at the time of writing).

## Posture belongs to the operator

A tool that runs agents unattended has no security posture of its own; it has the
one its operator configured. The runner, the image, the pre-flight hook, the
permission ruleset, the egress profile and the repository you point it at are all
decided outside this repository, and they decide almost everything above. The
tiers those choices fall into are in [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md).
Pick yours before the first unattended drain, not after it.
