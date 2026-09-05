#!/usr/bin/env python3
"""
pm - a concurrency-safe ticket/PM system for fleets of Claude Code agents,
backed by GitHub Issues.

GitHub Issues IS the shared memory. Every agent reads the same board, so each
one always knows what is done, what is in progress, and what is open. State is
encoded with mutually-exclusive `pm:*` status labels; ownership and working
notes are recorded as structured issue comments.

No third-party dependencies. Requires the GitHub CLI (`gh`) to be installed and
authenticated (`gh auth login`).

Commands:
  pm init                    Create the required labels in the repo.
  pm create "Title" --area frontend|backend|both [opts]
                              Open a new ticket (defaults to pm:open).
  pm list [--status S]       Show the board (open / in-progress / blocked / done).
  pm status                  Alias for `pm list` with a summary header.
  pm next                    Show the next claimable ticket (does NOT claim).
  pm claim [N]               Atomically claim a ticket for this agent.
  pm log N "message"         Append a working-note comment to a ticket.
  pm block N "reason"        Move a ticket to blocked with a reason.
  pm unblock N               Move a blocked ticket back to open.
  pm done N ["summary"]      Mark a ticket done and close the issue.
  pm release N ["reason"]    Give up an in-progress ticket, back to open.
  pm reopen N "reason"       Reopen a done ticket for review (problem found).
  pm show N                  Print full ticket detail + history.
  pm area N frontend|backend|both
                             Flag whether a ticket touches the front-end,
                             back-end, or both.

Global options:
  -R, --repo OWNER/REPO      Target repo (default: repo of current directory,
                             or $PM_REPO).
  --agent NAME               This agent's identity (default: $PM_AGENT or
                             host-pid). Used for claims and ownership.

Environment:
  PM_REPO           default repo (OWNER/REPO)
  PM_AGENT          default agent identity
  PM_CLAIM_SETTLE   seconds to wait for competing claims to settle (default 3)
  PM_LABEL_PREFIX   status label prefix (default "pm")

Exit codes:
  0 success · 2 nothing to do (no claimable ticket / lost every race) · 1 error
"""

import argparse
import json
import os
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone

PREFIX = os.environ.get("PM_LABEL_PREFIX", "pm")

# Mutually-exclusive status labels. Exactly one should ever be set on a ticket.
S_OPEN = f"{PREFIX}:open"
S_INPROGRESS = f"{PREFIX}:in-progress"
S_BLOCKED = f"{PREFIX}:blocked"
S_DONE = f"{PREFIX}:done"
S_REVIEW = f"{PREFIX}:review"
STATUS_LABELS = [S_OPEN, S_INPROGRESS, S_BLOCKED, S_DONE, S_REVIEW]

# Priority labels. Lower number = higher priority; claimed first.
PRIORITIES = [f"{PREFIX}:p0", f"{PREFIX}:p1", f"{PREFIX}:p2", f"{PREFIX}:p3"]

# Area labels. Mutually exclusive, flag whether a ticket touches the
# front-end (UI/client), the back-end (data/services/server), or both.
AREA_FRONTEND = "area:frontend"
AREA_BACKEND = "area:backend"
AREA_BOTH = "area:both"
AREA_LABELS = [AREA_FRONTEND, AREA_BACKEND, AREA_BOTH]

# Structured comment markers (machine-readable, greppable, human-visible).
CLAIM_MARK = f"{PREFIX}-claim"     # a claim attempt (part of the claim race)
OWNER_MARK = f"{PREFIX}-owner"     # the confirmed owner after winning a claim
NOTE_MARK = f"{PREFIX}-note"       # a working note / log entry

LABEL_DEFS = [
    (S_OPEN, "1d76db", "Ticket ready to be picked up by an agent"),
    (S_INPROGRESS, "fbca04", "Ticket currently being worked by an agent"),
    (S_BLOCKED, "b60205", "Ticket blocked, needs attention before work continues"),
    (S_DONE, "0e8a16", "Ticket completed"),
    (S_REVIEW, "e99695", "Ticket reopened: a problem was found with completed work"),
    (PRIORITIES[0], "5319e7", "Priority 0 - highest, claim first"),
    (PRIORITIES[1], "8250df", "Priority 1"),
    (PRIORITIES[2], "a371f7", "Priority 2"),
    (PRIORITIES[3], "d2b3ff", "Priority 3 - lowest"),
    (AREA_FRONTEND, "c5def5", "Touches the front-end (UI/client)"),
    (AREA_BACKEND, "bfd4f2", "Touches the back-end (data/services/server)"),
    (AREA_BOTH, "9bc0e8", "Touches both the front-end and back-end"),
]


# --------------------------------------------------------------------------- #
# gh plumbing
# --------------------------------------------------------------------------- #

class PMError(Exception):
    pass


def run_gh(args, repo=None, check=True, capture=True):
    """Run a `gh` command. Returns stdout (str). Raises PMError on failure."""
    cmd = ["gh"] + args
    if repo:
        cmd += ["-R", repo]
    try:
        res = subprocess.run(
            cmd,
            check=False,
            text=True,
            capture_output=capture,
        )
    except FileNotFoundError:
        raise PMError("`gh` (GitHub CLI) not found. Install it: https://cli.github.com")
    if check and res.returncode != 0:
        msg = (res.stderr or res.stdout or "").strip()
        raise PMError(f"gh {' '.join(args)} failed: {msg}")
    return res.stdout if capture else ""


def gh_api(path, repo=None, method=None, fields=None):
    args = ["api", path.format(repo=repo)]
    if method:
        args += ["-X", method]
    for k, v in (fields or {}).items():
        args += ["-f", f"{k}={v}"]
    out = run_gh(args)
    return json.loads(out) if out.strip() else None


def detect_repo(cli_repo):
    repo = cli_repo or os.environ.get("PM_REPO")
    if repo:
        return repo
    try:
        out = run_gh(["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"])
        return out.strip()
    except PMError:
        raise PMError(
            "Could not determine repo. Run inside a git repo with a GitHub remote, "
            "pass -R OWNER/REPO, or set $PM_REPO."
        )


def agent_id(cli_agent):
    if cli_agent:
        return cli_agent
    env = os.environ.get("PM_AGENT")
    if env:
        return env
    import socket
    return f"{socket.gethostname()}-{os.getpid()}"


def now_iso():
    return datetime.now(timezone.utc).isoformat()


# --------------------------------------------------------------------------- #
# Ticket queries
# --------------------------------------------------------------------------- #

def list_issues(repo, labels=None, state="open", limit=200):
    args = ["issue", "list", "--state", state, "--limit", str(limit),
            "--json", "number,title,labels,createdAt,updatedAt"]
    for lb in (labels or []):
        args += ["--label", lb]
    out = run_gh(args, repo=repo)
    return json.loads(out or "[]")


def issue_label_names(issue):
    return [l["name"] for l in issue.get("labels", [])]


def issue_priority_rank(issue):
    names = issue_label_names(issue)
    for i, p in enumerate(PRIORITIES):
        if p in names:
            return i
    return len(PRIORITIES)  # unprioritised sorts last


def issue_comments(repo, number):
    """Return comments with databaseId, createdAt, body — chronological."""
    data = gh_api("repos/{repo}/issues/" + str(number) + "/comments", repo=repo)
    return data or []


def parse_marker(body, mark):
    """Extract 'key=value' pairs from a line starting with <mark>. Returns dict or None."""
    for line in body.splitlines():
        line = line.strip()
        if line.startswith(mark):
            rest = line[len(mark):].strip().lstrip(":").strip()
            kv = {}
            for tok in rest.split():
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    kv[k] = v
            return kv
    return None


def current_owner(repo, number):
    """Latest confirmed owner (from pm-owner comments). Returns agent or None."""
    owner = None
    for c in issue_comments(repo, number):
        kv = parse_marker(c["body"], OWNER_MARK)
        if kv is not None:
            owner = kv.get("agent")
    if owner in (None, "none", ""):
        return None
    return owner


# --------------------------------------------------------------------------- #
# Label transitions
# --------------------------------------------------------------------------- #

def set_status(repo, number, new_status):
    """Ensure exactly `new_status` among the status labels is present."""
    remove = [s for s in STATUS_LABELS if s != new_status]
    args = ["issue", "edit", str(number), "--add-label", new_status]
    for r in remove:
        args += ["--remove-label", r]
    run_gh(args, repo=repo)


def set_area(repo, number, area):
    """Ensure exactly `area` among the area labels is present."""
    remove = [a for a in AREA_LABELS if a != area]
    args = ["issue", "edit", str(number), "--add-label", area]
    for r in remove:
        args += ["--remove-label", r]
    run_gh(args, repo=repo)


def add_comment(repo, number, body):
    run_gh(["issue", "comment", str(number), "--body", body], repo=repo)


# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #

def cmd_init(args):
    repo = detect_repo(args.repo)
    print(f"Creating pm labels in {repo} ...")
    for name, color, desc in LABEL_DEFS:
        # --force updates the label if it already exists.
        try:
            run_gh(["label", "create", name, "--color", color,
                    "--description", desc, "--force"], repo=repo)
            print(f"  ok  {name}")
        except PMError as e:
            print(f"  !!  {name}: {e}", file=sys.stderr)
    print("Done. Create your first ticket with:  pm create \"My first ticket\"")


def cmd_create(args):
    repo = detect_repo(args.repo)
    labels = [S_OPEN]
    if args.priority is not None:
        labels.append(f"{PREFIX}:p{args.priority}")
    if args.area:
        labels.append(f"area:{args.area}")
    for lb in (args.label or []):
        labels.append(lb)
    cmd = ["issue", "create", "--title", args.title,
           "--body", args.body or "_Created via pm._"]
    for lb in labels:
        cmd += ["--label", lb]
    out = run_gh(cmd, repo=repo)
    print(out.strip())


def _board(repo):
    issues = list_issues(repo, state="open")
    # done tickets are closed, so query them separately (recent 30)
    done = list_issues(repo, labels=[S_DONE], state="closed", limit=30)
    buckets = {S_INPROGRESS: [], S_BLOCKED: [], S_REVIEW: [], S_OPEN: [], "other": []}
    for i in issues:
        names = issue_label_names(i)
        if S_INPROGRESS in names:
            buckets[S_INPROGRESS].append(i)
        elif S_BLOCKED in names:
            buckets[S_BLOCKED].append(i)
        elif S_REVIEW in names:
            buckets[S_REVIEW].append(i)
        elif S_OPEN in names:
            buckets[S_OPEN].append(i)
        else:
            buckets["other"].append(i)
    return buckets, done


AREA_TAGS = {AREA_FRONTEND: "FE", AREA_BACKEND: "BE", AREA_BOTH: "FE+BE"}


def _fmt_line(repo, i, with_owner=False):
    names = issue_label_names(i)
    prio = next((p.split(":")[1] for p in PRIORITIES if p in names), "--")
    area = next((AREA_TAGS[a] for a in AREA_LABELS if a in names), None)
    line = f"  #{i['number']:<5} [{prio}]"
    line += f" [{area}]" if area else " [--]"
    line += f" {i['title']}"
    if with_owner:
        owner = current_owner(repo, i["number"])
        if owner:
            line += f"   (@{owner})"
    return line


def cmd_list(args):
    repo = detect_repo(args.repo)
    buckets, done = _board(repo)
    if args.status:
        key = {"open": S_OPEN, "in-progress": S_INPROGRESS,
               "blocked": S_BLOCKED, "done": S_DONE, "review": S_REVIEW}.get(args.status)
        if key == S_DONE:
            print(f"DONE ({len(done)})")
            for i in sorted(done, key=lambda x: -x["number"]):
                print(_fmt_line(repo, i))
        else:
            items = buckets.get(key, [])
            print(f"{args.status.upper()} ({len(items)})")
            for i in items:
                print(_fmt_line(repo, i, with_owner=(key == S_INPROGRESS)))
        return

    print(f"Board for {repo}")
    print(f"  in-progress: {len(buckets[S_INPROGRESS])}   "
          f"open: {len(buckets[S_OPEN])}   "
          f"blocked: {len(buckets[S_BLOCKED])}   "
          f"review: {len(buckets[S_REVIEW])}   "
          f"done(recent): {len(done)}\n")
    print("IN PROGRESS")
    for i in sorted(buckets[S_INPROGRESS], key=issue_priority_rank):
        print(_fmt_line(repo, i, with_owner=True))
    print("\nOPEN")
    for i in sorted(buckets[S_OPEN], key=lambda x: (issue_priority_rank(x), x["number"])):
        print(_fmt_line(repo, i))
    if buckets[S_REVIEW]:
        print("\nREVIEW")
        for i in buckets[S_REVIEW]:
            print(_fmt_line(repo, i))
    if buckets[S_BLOCKED]:
        print("\nBLOCKED")
        for i in buckets[S_BLOCKED]:
            print(_fmt_line(repo, i))


def _claimable(repo):
    issues = list_issues(repo, labels=[S_OPEN], state="open")
    issues += list_issues(repo, labels=[S_REVIEW], state="open")
    issues = [i for i in issues
              if S_INPROGRESS not in issue_label_names(i)
              and S_BLOCKED not in issue_label_names(i)]
    issues.sort(key=lambda x: (issue_priority_rank(x), x["number"]))
    return issues


def cmd_next(args):
    repo = detect_repo(args.repo)
    items = _claimable(repo)
    if not items:
        print("No claimable tickets.")
        sys.exit(2)
    i = items[0]
    print(f"Next: #{i['number']}  {i['title']}")
    print(f"Claim it with:  pm claim {i['number']}")


def _attempt_claim(repo, number, agent, settle):
    """Concurrency-safe claim of a single ticket.

    Protocol (deterministic winner even under a shared GitHub account):
      1. Snapshot the highest existing comment id (the baseline) so stale
         claim markers left over from an earlier, already-resolved race
         (claimed-then-released, blocked, done, reopened, ...) can never be
         mistaken for a live competitor.
      2. Post a claim marker comment with a unique nonce.
      3. Wait `settle` seconds for any competing claims to land.
      4. Re-read comments newer than the baseline; the winner is the
         earliest one (by createdAt, tie-broken by comment id -> a total
         order all agents compute identically).
      5. Winner flips labels open->in-progress and records ownership.
         Losers back off.
    Returns True if this agent won the ticket.
    """
    # Bail early if it is already taken.
    if S_INPROGRESS in issue_label_names_now(repo, number):
        return False

    # Anything already on the issue predates this attempt and belongs to a
    # previous race (won or lost, resolved or abandoned) — never a
    # competitor in this one, no matter how long it's been sitting there.
    baseline_id = max((c["id"] for c in issue_comments(repo, number)), default=0)

    nonce = uuid.uuid4().hex
    add_comment(repo, number,
                f"{CLAIM_MARK}: agent={agent} nonce={nonce} ts={now_iso()}\n"
                f"_Attempting to claim this ticket._")
    time.sleep(max(0.0, settle))

    claims = []
    for c in issue_comments(repo, number):
        if c["id"] <= baseline_id:
            continue
        kv = parse_marker(c["body"], CLAIM_MARK)
        if kv and "nonce" in kv:
            claims.append((c["created_at"], c["id"], kv["nonce"], kv.get("agent")))
    if not claims:
        return False
    claims.sort(key=lambda t: (t[0], t[1]))  # total order: (createdAt, comment id)
    winner_nonce = claims[0][2]

    if winner_nonce != nonce:
        return False  # lost the race

    # Double-check nobody flipped it to in-progress meanwhile.
    if S_INPROGRESS in issue_label_names_now(repo, number):
        return False

    set_status(repo, number, S_INPROGRESS)
    add_comment(repo, number,
                f"{OWNER_MARK}: agent={agent} ts={now_iso()}\n"
                f"**@{agent} is now working on this ticket.**")
    return True


def issue_label_names_now(repo, number):
    out = run_gh(["issue", "view", str(number), "--json", "labels",
                  "-q", "[.labels[].name]"], repo=repo)
    try:
        return json.loads(out or "[]")
    except json.JSONDecodeError:
        return []


def cmd_claim(args):
    repo = detect_repo(args.repo)
    agent = agent_id(args.agent)
    settle = float(os.environ.get("PM_CLAIM_SETTLE", "3"))

    if args.number:
        candidates = [{"number": int(args.number)}]
    else:
        candidates = _claimable(repo)

    if not candidates:
        print("No claimable tickets.")
        sys.exit(2)

    for i in candidates:
        n = i["number"]
        if _attempt_claim(repo, n, agent, settle):
            if args.quiet:
                # machine-readable: just the ticket number on stdout
                print(n)
                return
            title = run_gh(["issue", "view", str(n), "--json", "title", "-q", ".title"],
                           repo=repo).strip()
            print(f"Claimed #{n} as @{agent}: {title}")
            print(f"  work on it, then:  pm log {n} \"...\"   and   pm done {n} \"summary\"")
            return
        else:
            print(f"  #{n} already taken, trying next ...", file=sys.stderr)

    print("Could not claim any ticket (lost all races or none free).")
    sys.exit(2)


def _require_owner_or_warn(repo, number, agent):
    owner = current_owner(repo, number)
    if owner and owner != agent:
        print(f"  note: #{number} is owned by @{owner}, not @{agent}.", file=sys.stderr)


def cmd_log(args):
    repo = detect_repo(args.repo)
    agent = agent_id(args.agent)
    add_comment(repo, args.number,
                f"{NOTE_MARK}: agent={agent} ts={now_iso()}\n{args.message}")
    print(f"Logged note on #{args.number}.")


def cmd_block(args):
    repo = detect_repo(args.repo)
    agent = agent_id(args.agent)
    set_status(repo, args.number, S_BLOCKED)
    add_comment(repo, args.number,
                f"{NOTE_MARK}: agent={agent} ts={now_iso()}\n:no_entry: **Blocked:** {args.reason}")
    print(f"#{args.number} -> blocked.")


def cmd_unblock(args):
    repo = detect_repo(args.repo)
    agent = agent_id(args.agent)
    set_status(repo, args.number, S_OPEN)
    add_comment(repo, args.number,
                f"{OWNER_MARK}: agent=none ts={now_iso()}\nUnblocked and returned to the open pool.")
    print(f"#{args.number} -> open.")


def cmd_release(args):
    repo = detect_repo(args.repo)
    agent = agent_id(args.agent)
    set_status(repo, args.number, S_OPEN)
    reason = args.reason or "released back to the pool"
    add_comment(repo, args.number,
                f"{OWNER_MARK}: agent=none ts={now_iso()}\n@{agent} released this ticket: {reason}")
    print(f"#{args.number} -> open (released).")


def cmd_done(args):
    repo = detect_repo(args.repo)
    agent = agent_id(args.agent)
    _require_owner_or_warn(repo, args.number, agent)
    set_status(repo, args.number, S_DONE)
    summary = args.summary or "Completed."
    add_comment(repo, args.number,
                f"{OWNER_MARK}: agent=none ts={now_iso()}\n"
                f":white_check_mark: **Done by @{agent}:** {summary}")
    run_gh(["issue", "close", str(args.number), "--reason", "completed"], repo=repo)
    print(f"#{args.number} -> done (closed).")


def cmd_reopen(args):
    repo = detect_repo(args.repo)
    agent = agent_id(args.agent)
    run_gh(["issue", "reopen", str(args.number)], repo=repo)
    set_status(repo, args.number, S_REVIEW)
    add_comment(repo, args.number,
                f"{OWNER_MARK}: agent=none ts={now_iso()}\n"
                f":warning: **Reopened for review by @{agent}:** {args.reason}")
    print(f"#{args.number} -> review (reopened).")


def cmd_area(args):
    repo = detect_repo(args.repo)
    area = f"area:{args.area}"
    set_area(repo, args.number, area)
    print(f"#{args.number} -> area:{args.area}.")


def cmd_show(args):
    repo = detect_repo(args.repo)
    n = args.number
    meta = run_gh(["issue", "view", str(n),
                   "--json", "number,title,state,labels,body,url"], repo=repo)
    m = json.loads(meta)
    names = [l["name"] for l in m["labels"]]
    status = next((s for s in STATUS_LABELS if s in names), "(no status)")
    area = next((a.split(":")[1] for a in AREA_LABELS if a in names), "(unset)")
    owner = current_owner(repo, n) or "-"
    print(f"#{m['number']}  {m['title']}")
    print(f"status: {status}   area: {area}   owner: @{owner}   state: {m['state']}")
    print(f"url: {m['url']}")
    print(f"labels: {', '.join(names) or '-'}")
    print("\n--- body ---")
    print(m["body"] or "(empty)")
    print("\n--- history ---")
    for c in issue_comments(repo, n):
        for mark in (CLAIM_MARK, OWNER_MARK, NOTE_MARK):
            kv = parse_marker(c["body"], mark)
            if kv is not None:
                who = kv.get("agent", "?")
                ts = kv.get("ts", c["created_at"])
                tail = c["body"].split("\n", 1)[1].strip() if "\n" in c["body"] else ""
                print(f"  [{mark:9}] @{who} {ts}  {tail}")
                break


# --------------------------------------------------------------------------- #
# CLI wiring
# --------------------------------------------------------------------------- #

def build_parser():
    p = argparse.ArgumentParser(prog="pm", description="Agent ticket system on GitHub Issues.")
    p.add_argument("-R", "--repo", help="OWNER/REPO (default: current repo or $PM_REPO)")
    p.add_argument("--agent", help="agent identity (default: $PM_AGENT or host-pid)")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("init", help="create pm labels in the repo")
    sp.set_defaults(func=cmd_init)

    sp = sub.add_parser("create", help="open a new ticket")
    sp.add_argument("title")
    sp.add_argument("--body", help="ticket description")
    sp.add_argument("--priority", type=int, choices=[0, 1, 2, 3], help="priority 0(high)-3(low)")
    sp.add_argument("--area", required=True, choices=["frontend", "backend", "both"],
                    help="required: does this ticket touch the front-end, back-end, or both?")
    sp.add_argument("--label", action="append", help="extra label (repeatable)")
    sp.set_defaults(func=cmd_create)

    sp = sub.add_parser("list", help="show the board")
    sp.add_argument("--status", choices=["open", "in-progress", "blocked", "done", "review"])
    sp.set_defaults(func=cmd_list)

    sp = sub.add_parser("status", help="show the board (alias for list)")
    sp.add_argument("--status", choices=["open", "in-progress", "blocked", "done", "review"])
    sp.set_defaults(func=cmd_list)

    sp = sub.add_parser("next", help="show the next claimable ticket")
    sp.set_defaults(func=cmd_next)

    sp = sub.add_parser("claim", help="atomically claim a ticket")
    sp.add_argument("number", nargs="?", help="specific ticket (default: auto-pick)")
    sp.add_argument("--quiet", action="store_true",
                    help="print only the claimed ticket number (for scripts)")
    sp.set_defaults(func=cmd_claim)

    sp = sub.add_parser("log", help="append a working note")
    sp.add_argument("number")
    sp.add_argument("message")
    sp.set_defaults(func=cmd_log)

    sp = sub.add_parser("block", help="move ticket to blocked")
    sp.add_argument("number")
    sp.add_argument("reason")
    sp.set_defaults(func=cmd_block)

    sp = sub.add_parser("unblock", help="return blocked ticket to open")
    sp.add_argument("number")
    sp.set_defaults(func=cmd_unblock)

    sp = sub.add_parser("release", help="give up an in-progress ticket")
    sp.add_argument("number")
    sp.add_argument("reason", nargs="?")
    sp.set_defaults(func=cmd_release)

    sp = sub.add_parser("done", help="mark ticket done and close")
    sp.add_argument("number")
    sp.add_argument("summary", nargs="?")
    sp.set_defaults(func=cmd_done)

    sp = sub.add_parser("reopen", help="reopen a done ticket for review")
    sp.add_argument("number")
    sp.add_argument("reason")
    sp.set_defaults(func=cmd_reopen)

    sp = sub.add_parser("show", help="print full ticket detail + history")
    sp.add_argument("number")
    sp.set_defaults(func=cmd_show)

    sp = sub.add_parser("area", help="flag whether a ticket touches front-end, back-end, or both")
    sp.add_argument("number")
    sp.add_argument("area", choices=["frontend", "backend", "both"])
    sp.set_defaults(func=cmd_area)

    return p


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        args.func(args)
    except PMError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
