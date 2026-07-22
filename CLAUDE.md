# CLAUDE.md

## Project

<!-- Describe your repo, stack, build/test commands here. Example: -->
<!-- Run tests with `npm test`. Lint with `npm run lint`. Build with `npm run build`. -->

## You work tickets through `pm` (GitHub Issues)

This repo is worked by a fleet of parallel Claude Code agents. Tickets are
**GitHub Issues** driven by the `pm` CLI. GitHub is the single source of truth
for what is done, in progress, and open — never track work anywhere else, and
never edit issue labels/status by hand. Always go through `pm`.

Identify yourself: everything you do is attributed to `$PM_AGENT` (set it to a
unique name per agent). `$PM_REPO` selects the repo.

### The loop you run

1. `pm list` — look at the board. Note what is already in progress and **who owns
   it**; never touch another agent's ticket.
2. `pm claim` — atomically take the highest-priority open ticket (or `pm claim N`
   for a specific one). If it says "No claimable tickets", you are done — stop.
3. `pm show <N>` — read the full ticket and its history before writing any code.
4. Implement the requirements. Log meaningful progress and decisions as you go:
   `pm log <N> "what you did / decided / found"`. These notes are the memory the
   next agent relies on — log generously.
5. If you get stuck (missing info, broken dependency, needs a human):
   `pm block <N> "why"`, then go back to step 2. Don't sit on it.
6. When the requirements are fully implemented **and verified** (tests pass,
   build green): `pm done <N> "one-line summary of what shipped"`. This closes
   the issue.
7. Repeat from step 1.

### Hard rules

- One ticket at a time. Finish, `block`, or `release` before claiming another.
- Only `pm done` when it is genuinely done — never with failing tests, a partial
  implementation, or unresolved errors. If unsure, keep logging, or
  `pm release <N> "reason"` so another agent can take it.
- Respect ownership shown by `pm show`. Someone else's ticket is off-limits.
- Always `pm log` before you pause, block, or release, so no context is lost.
- Every ticket you create with `pm create` **must** pass
  `--area frontend|backend|both` — it is a required flag (the CLI rejects the
  command without it) so the board always shows whether a ticket is UI/client
  work, data/service work, or both. If a ticket's area changes later, fix it
  with `pm area N <frontend|backend|both>` rather than leaving it stale.
- If you find a problem with work that was already marked `pm:done`, don't open
  a new ticket — `pm reopen N "reason"` puts it back on the board as
  `pm:review`. Review tickets are claimable just like open ones.

### Command cheat-sheet

```
pm list                     pm claim [N]           pm show N
pm next                     pm log N "message"     pm done N "summary"
pm block N "reason"         pm unblock N           pm release N ["reason"]
pm create "Title" --area frontend|backend|both      pm area N <area>
pm reopen N "reason"
```
