---
name: multi-account-happy-setup
description: Set up one or more Claude Code accounts, each in its own claude-pod Docker sandbox, each reachable as an independent session from the Happy Coder mobile app, persisted across restarts via systemd user services. Use when the user wants to add a new claude-pod + Happy account, set up multiple parallel Claude accounts/profiles, or run claude-pod as a persistent background/systemd service reachable from the Happy mobile app.
---

# Multi-Account Happy Coder + claude-pod Setup

Sets up N independent accounts, each isolated (own Claude login, own Happy
pairing, own project directory) and kept running persistently by systemd.
This has real gotchas that aren't obvious from `claude-pod --help` or the
README — see `REFERENCE.md` for the *why* behind every step marked "(see
REFERENCE.md)". Don't skip those steps or improvise around them; each one
maps to a specific failure mode that was hit and diagnosed empirically.

## Step 0: Gather requirements

Ask the user (don't assume):
1. How many accounts, and what identifier should each use (e.g. `tessero`,
   `personal`, `client-a`)? These identifiers become directory suffixes and
   the Happy Coder "machine name" shown in the mobile app.
2. Do any accounts already have host-side state (an existing
   `~/.claude-<id>` from prior setup)? Check before creating — don't clobber.
3. Which of the tests in Step 7 do they want to run? Default recommendation:
   run everything except 7.6 (reboot) and 7.9 (concurrent load) unless they
   want the full suite — those two need the user's direct involvement
   (an actual reboot, or sending prompts from the phone).

## Step 1: Verify the tool supports this before wiring anything up

```bash
grep -n "CLAUDE_CONFIG_DIR\|CLAUDE_POD_HOME\|HAPPY_HOME_DIR\|HAPPY_MACHINE_NAME" ~/tools/claude-pod/claude-pod
```
Confirm all four appear with `${VAR:-default}` fallbacks. `HAPPY_MACHINE_NAME`
is what makes containers get a stable `--hostname`/`--name` instead of a
random one per run (see REFERENCE.md) — if it's missing, this is likely an
older clone; add it before continuing rather than working around its absence.

Rebuild the image if the Dockerfile changed: `cd ~/tools/claude-pod && ./install.sh`

## Step 2: Directory layout, per account

```
~/code/<id>/            # project folder (CLAUDE_POD_HOME's cwd)
~/.claude-<id>/         # CLAUDE_CONFIG_DIR
~/.claude-pod-<id>/     # CLAUDE_POD_HOME
~/.happy-<id>/          # HAPPY_HOME_DIR
```
Create only what's missing (`mkdir -p`, safe to re-run). Don't assume these
should reuse an existing `CLAUDE_CONFIG_DIR` from prior setup — confirm per
account.

## Step 3: Seed config BEFORE the first run (see REFERENCE.md)

Two failures only show up on first run and both are avoidable up front:
1. **MCP whitelist**: `claude-pod` whitelists MCP servers (default
   `codegraph`) by reading them out of *this account's own* `.claude.json`,
   not the host's. A freshly-seeded profile has no `mcpServers` key at all →
   hard failure before Docker even starts. Copy the relevant entries from
   the host's real `~/.claude.json` into each account's `~/.claude-<id>/.claude.json`.
2. **Bypass-permissions confirmation dialog**: with no human present to
   click "Yes, I accept", this blocks forever under systemd. Add
   `"skipDangerousModePermissionPrompt": true` to each account's
   `~/.claude-<id>/settings.json`.

## Step 4: First run per account — manual, interactive, one at a time

Before assuming any example invocation is correct, run
`docker run --rm --entrypoint happy claude-pod --help` and use whatever
flag syntax it actually reports — `happy-coder`'s CLI has changed shape
before (an older `--claude-arg <arg>` wrapper flag no longer exists; flags
now pass straight through). Then:

```bash
cd ~/code/<id>
CLAUDE_CONFIG_DIR=~/.claude-<id> CLAUDE_POD_HOME=~/.claude-pod-<id> \
HAPPY_HOME_DIR=~/.happy-<id> HAPPY_MACHINE_NAME=<id> \
  ~/tools/claude-pod/claude-pod happy --dangerously-skip-permissions
```

Inside the session: complete Claude login if prompted, scan the Happy QR
and confirm the session shows up in the mobile app, send one trivial prompt
to trigger and accept the workspace trust dialog, then exit. **Expect to
need two runs** the first time — the first often surfaces login/pairing,
the second confirms it's actually live (this was true even after Step 3's
fixes). Repeat for every account before moving to systemd.

## Step 5: Verify state actually persisted, per account

Check (see REFERENCE.md for exact commands): `.credentials.json` is
non-empty in `~/.claude-pod-<id>`, `hasTrustDialogAccepted: true` for the
right project path, and `~/.happy-<id>` has pairing state (`access.key`,
`sessions.json`). If any of these is missing/empty, don't proceed to
systemd — fix it here first.

## Step 6: systemd unit per account

Use the exact template in `REFERENCE.md`, not a simplified guess — it wraps
`ExecStart` in a pty allocator (`script`) because Claude Code's CLI silently
assumes non-interactive `--print` mode with no TTY and crash-loops, and it
sets an explicit `ExecStop=docker stop <id>` because signal propagation
through a foregrounded, pty-attached `docker run` does not reliably stop
the container otherwise (verified: without it, `systemctl restart` leaves
a duplicate container running under the old process, silently, forever).

```bash
mkdir -p ~/.config/systemd/user ~/.happy-logs
loginctl enable-linger $USER   # once, ever, per user
```
Write one unit per account from the template, `daemon-reload`, then
`systemctl --user enable --now happy@<id>` **one account at a time** —
confirm each is stable (`NRestarts` not climbing) before starting the next.

## Step 7: Tests (see REFERENCE.md for exact commands per test)

Run whatever the user opted into from Step 0. Recommended defaults:

| # | Test | Needs user? | Default |
|---|------|:---:|---|
| 7.1 | Basic liveness | no | run |
| 7.2 | No name/hostname collisions | no | run |
| 7.3 | Credential isolation | no | run |
| 7.4 | Mobile app shows all sessions, correctly labeled | yes (phone) | run |
| 7.5 | Persists across `systemctl restart` | no | run |
| 7.6 | Persists across host reboot | yes (reboot) | ask first |
| 7.7 | Workspace trust holds (no re-prompt) | no | run |
| 7.8 | Crash recovery (`docker kill` → auto-restart) | no | run |
| 7.9 | Concurrent load from phone, no cross-talk | yes (phone) | ask first |

After each test, report pass/fail plainly — don't declare the whole setup
done until every test the user opted into has actually been run and shown
to pass.

## Residual risks to flag once everything passes

State these explicitly rather than silently accepting them — they're the
same tradeoffs the original design doc flagged, still true after all fixes:
- `--dangerously-skip-permissions` on N unattended, auto-restarting
  containers is a materially larger blast radius than one interactive
  session. Confirm the user actually wants this per account.
- No network restriction on these containers by default (`NET=none` is
  available but not applied automatically).
- No resource limits (`MEMORY=`/`CPUS=`) by default — worth setting if
  running many accounts concurrently on constrained hardware.
