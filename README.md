# pm — an agent-driven ticket system on GitHub Issues

A small, professional-grade project-management layer that lets a **fleet of
Claude Code agents** work a repository autonomously: they pick up open tickets,
flip them to *in progress*, do the work, and mark them *done* — with
concurrency-safe claiming so two agents never grab the same ticket, and shared
memory so every agent always knows the full state of the board.

The store is plain **GitHub Issues**, driven by a single dependency-free Python
CLI (`pm`) over the GitHub CLI (`gh`). Nothing else to run — no database, no
server.

## Why GitHub Issues is the memory

There is no separate state file to keep in sync. Every agent queries the same
issues, so the board *is* the shared memory:

| Concept        | How it is stored                                              |
|----------------|--------------------------------------------------------------|
| A ticket       | A GitHub Issue                                               |
| Status         | Exactly one mutually-exclusive label: `pm:open`, `pm:in-progress`, `pm:blocked`, `pm:done`, `pm:review` |
| Priority       | `pm:p0` (highest) … `pm:p3` (lowest)                         |
| Owner          | A structured `pm-owner:` comment (latest wins)              |
| Working memory | `pm-note:` comments — the running log of what was done/decided |
| Claim attempts | `pm-claim:` comments — used only to resolve races           |

Because state lives in issue labels and comments, any agent (or human, in the
GitHub UI) sees the same truth at any moment.

## Requirements

- `python3`
- GitHub CLI (`gh`) — installed and authenticated (`gh auth login`)
- A GitHub repository you can write issues to

## Install

```bash
./install.sh                 # installs pm to ~/.local/bin and creates labels
# or target a specific repo for label creation:
./install.sh -R owner/repo
```

Or install by hand:

```bash
chmod +x pm && cp pm ~/.local/bin/pm
pm -R owner/repo init        # create the pm:* labels once per repo
```

## Everyday use (a human seeding work)

```bash
pm create "Add rate limiting to the API" --priority 1 --area backend \
  --body "Cap at 100 req/min per token. Return 429 with Retry-After."
pm create "Fix flaky login test" --priority 0 --area backend
pm list                      # see the board
```

## Running a fleet of agents

Drop `AGENTS.md` into the repo (or paste it into your `CLAUDE.md`) so each agent
knows the contract. Give each agent an identity, then let it loop:

```bash
export PM_REPO=owner/repo
export PM_AGENT=agent-a       # unique per agent -> ownership in the log is clear

pm claim                      # take the top open ticket
pm show 42                    # read it
# ... implement ...
pm log 42 "added token-bucket middleware; wrote 3 tests"
pm done 42 "rate limiting live, 100/min, tests green"
```

Point several agents at the same repo at once — the claim protocol guarantees
each ticket goes to exactly one of them.

## Reopening for review

If a problem is found with work that was already marked `pm:done`, don't open
a fresh ticket — reopen the original one so its history stays attached:

```bash
pm reopen 42 "rate limiting doesn't apply to the /health endpoint"
```

This reopens the closed issue and flips it to `pm:review`. Review tickets are
claimable just like open ones (`pm claim` picks them up alongside `pm:open`
tickets), so any agent can pick it back up, fix it, and `pm done` it again.

## Running the fleet automatically

`run-agent.sh` wraps that loop into a single autonomous worker: it claims a
ticket, hands it to a headless Claude Code agent (`claude -p ...`) to
implement, waits for the agent to `pm done` / `pm block` it, then repeats
until there is nothing left to claim. If a run errors out or leaves a ticket
in-progress without closing it, the worker releases it back to the pool so it
isn't stranded.

```bash
PM_REPO=owner/repo PM_AGENT=agent-a ./run-agent.sh
```

Useful env vars: `PM_MAX` (stop after N tickets), `PM_IDLE_EXIT` (1 = exit
when the board is empty, default; 0 = poll and wait), `PM_POLL` (seconds
between polls when idle-waiting), `CLAUDE_BIN` / `CLAUDE_ARGS` (override the
Claude Code binary/flags, default `--dangerously-skip-permissions`).

`run-fleet.sh` launches several `run-agent.sh` workers at once, each with its
own agent identity, and tails their logs:

```bash
PM_REPO=owner/repo ./run-fleet.sh 4   # 4 parallel workers, logs in ./fleet-logs/
```

They all read and claim from the same board, so the concurrency-safe claim
protocol below is what keeps them from colliding.

## Concurrency model — how claiming stays safe

GitHub has no compare-and-swap on labels, and a fleet may even share one GitHub
account, so `pm claim` uses a **deterministic comment-ordering** protocol:

1. The agent posts a `pm-claim:` comment carrying a unique nonce.
2. It waits a short settle window (`PM_CLAIM_SETTLE`, default **3s**) for any
   competing claims to land.
3. It re-reads every claim comment. The **winner is the earliest comment**,
   ordered by `(createdAt, comment id)` — a total order that *every* agent
   computes identically, so they all agree on one winner.
4. The winner flips the label `pm:open → pm:in-progress` and records ownership.
   Losers back off and try the next ticket.

The settle window is what closes the race: it must exceed expected clock skew and
API latency between agents. Raise it for large, busy fleets:

```bash
export PM_CLAIM_SETTLE=5
```

This is a pragmatic, well-known distributed-claim pattern. It is safe for the
typical case of a handful of agents; if you scale to dozens of very aggressive
claimers, increase the settle window accordingly.

## Command reference

```
pm init                      Create the pm:* and area:* labels in the repo.
pm create "Title" --area frontend|backend|both [--body B] [--priority 0-3] [--label L ...]
pm list [--status open|in-progress|blocked|done|review]
pm status                    Alias for list.
pm next                      Show the next claimable ticket (no claim).
pm claim [N]                 Atomically claim the next open ticket (or N).
pm show N                    Full ticket detail + history.
pm log N "message"           Append a working-note comment.
pm block N "reason"          Move ticket to blocked.
pm unblock N                 Return a blocked ticket to open.
pm release N ["reason"]      Give up an in-progress ticket -> open.
pm done N ["summary"]        Mark done and close the issue.
pm reopen N "reason"         Reopen a done ticket for review -> pm:review.
pm area N frontend|backend|both
                              Flag whether a ticket touches the front-end,
                              back-end, or both.
```

Global: `-R owner/repo` (or `$PM_REPO`), `--agent name` (or `$PM_AGENT`).

Exit codes: `0` success · `2` nothing to do (no claimable ticket / lost every
race — useful for `while pm claim; do ...; done` loops) · `1` error.

## Files

- `pm` — the CLI (single file, no third-party deps).
- `install.sh` — installer + label bootstrap.
- `run-agent.sh` — one autonomous worker: claim -> dispatch to Claude Code -> repeat.
- `run-fleet.sh` — launches several `run-agent.sh` workers against one repo.
- `AGENTS.md` — the work contract to give your agents.
- `CLAUDE.md` — the same contract, read automatically by Claude Code.
- `README.md` — this file.

## Customising

- `PM_LABEL_PREFIX` changes the label namespace (default `pm`). Set it before
  `pm init` and keep it consistent.
- Every ticket must declare `--area frontend|backend|both` at creation time —
  it's a required flag, not optional. Use `pm area N <value>` to change it later.
- Add your own extra labels with `pm create --label some-label` — they ride
  alongside the `pm:*`/`area:*` labels without interfering.
```
