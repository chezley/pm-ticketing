# Agent work contract — the `pm` ticket system

You are one of several Claude Code agents working the same repository in
parallel. Tickets live as **GitHub Issues** and are driven entirely through the
`pm` CLI. GitHub is the shared memory: it is always the source of truth for what
is done, what is in progress, and what is open. Do **not** invent your own
tracking — read and write state only through `pm`.

## The loop you run

1. **See the board.** `pm list` — check what is already in progress (and who owns
   it) before doing anything. Never work a ticket another agent owns.
2. **Claim work.** `pm claim` — auto-picks the highest-priority open ticket and
   atomically assigns it to you. If it prints "No claimable tickets", stop.
   To target a specific one: `pm claim 42`.
3. **Read the ticket.** `pm show <N>` — read the full body and history before
   writing code.
4. **Work it.** Implement the requirements. As you make meaningful progress or
   decisions, record them: `pm log <N> "what you did / decided / found"`. These
   notes are how the next agent understands your work — log generously.
5. **Handle blockers.** If you cannot proceed (missing info, failing dependency,
   needs a human), run `pm block <N> "why"` and go back to step 1. Do not sit on
   a ticket you cannot finish.
6. **Finish.** When the ticket's requirements are fully implemented AND verified
   (tests pass, build is green), run `pm done <N> "one-line summary of what
   shipped"`. This marks it done and closes the issue.
7. **Repeat** from step 1 until `pm claim` reports nothing to do.

## Rules

- **One ticket at a time.** Finish, block, or release before claiming another.
- **Only mark done when it is truly done.** Never `pm done` with failing tests, a
  partial implementation, or unresolved errors. If unsure, `pm log` your state
  and keep it in-progress, or `pm release <N> "reason"` so another agent can pick
  it up.
- **Respect ownership.** `pm show` lists the owner. If a ticket is owned by
  someone else, leave it alone.
- **Log before you stop.** Whenever you pause, block, or release, leave a
  `pm log` note so no context is lost between agents.
- **Never edit issue labels or status by hand** (no `gh issue edit` for status).
  Always go through `pm` so the state machine stays consistent.
- **Found a problem with already-done work?** Don't open a new ticket —
  `pm reopen N "reason"` puts it back on the board as `pm:review`, claimable
  like any open ticket.

## Quick reference

```
pm list                     # the board: in-progress / open / blocked
pm next                     # next claimable ticket (does not claim)
pm claim [N]                # atomically take the next (or ticket N)
pm show N                   # full ticket + history
pm log N "message"          # append a working note
pm block N "reason"         # -> blocked
pm unblock N                # blocked -> open
pm release N ["reason"]     # give up an in-progress ticket -> open
pm done N ["summary"]       # -> done + close the issue
pm reopen N "reason"        # done ticket had a problem -> pm:review, reopened
```

Identify yourself with `--agent <name>` or the `PM_AGENT` env var so ownership in
the log is meaningful (e.g. `export PM_AGENT=agent-a`). If you omit it, `pm`
falls back to `host-pid`.
