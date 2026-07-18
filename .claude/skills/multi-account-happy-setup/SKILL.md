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
2. **What project folder should each account use?** Don't default to
   `~/code/<id>` silently — ask. Some accounts may want a fresh empty
   folder (suggest `~/code/<id>` as the convention), others may want to
   point at an existing repo or a folder that already holds several repos
   (this is one directory mounted whole into the container — see Step 2).
   Confirm the exact path per account.
3. **Does each account want `--dangerously-skip-permissions`, or manual
   per-action approval?** This is a real tradeoff, not a default — ask
   explicitly, per account:
   - **Bypass** (`--dangerously-skip-permissions`): required for true
     unattended background operation (no human needed to approve tool
     calls). This is the path fully built and tested in this skill —
     Steps 3/4/6 below assume it unless told otherwise.
   - **Manual approval**: Claude prompts before each tool call, presumably
     surfaced to the mobile app for the user to approve remotely, same as
     Happy's shared-terminal model in general. **This has not been
     empirically verified end-to-end in a headless/systemd context** the
     way the bypass path has (see REFERENCE.md) — treat it as needing its
     own first-run verification, and skip the `skipDangerousModePermissionPrompt`
     settings change in Step 3 and the flag in Steps 4/6 for that account.
4. Do any accounts already have host-side state (an existing
   `~/.claude-<id>` from prior setup)? Check before creating — don't clobber.
5. Which of the tests in Step 7 do they want to run? Default recommendation:
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
<project folder from Step 0>/   # the account's cwd -- mounted into the container at the same path
~/.claude-<id>/                 # CLAUDE_CONFIG_DIR
~/.claude-pod-<id>/             # CLAUDE_POD_HOME
~/.happy-<id>/                  # HAPPY_HOME_DIR
```
The project folder is whatever the user chose in Step 0 (create it with
`mkdir -p` if it's a fresh one; if it's an existing folder, leave its
contents alone). The other three are always `claude-pod`'s own state dirs
under `$HOME` — create only what's missing (`mkdir -p`, safe to re-run).
Don't assume these should reuse an existing `CLAUDE_CONFIG_DIR` from prior
setup — confirm per account.

## Step 3: Seed config BEFORE the first run (see REFERENCE.md)

Two failures only show up on first run and both are avoidable up front:
1. **MCP whitelist**: `claude-pod` whitelists MCP servers (default
   `codegraph`) by reading them out of *this account's own* `.claude.json`,
   not the host's. A freshly-seeded profile has no `mcpServers` key at all →
   hard failure before Docker even starts. Copy the relevant entries from
   the host's real `~/.claude.json` into each account's `~/.claude-<id>/.claude.json`.
2. **Bypass-permissions confirmation dialog** (only for accounts using
   `--dangerously-skip-permissions`, per Step 0): with no human present to
   click "Yes, I accept", this blocks forever under systemd. Add
   `"skipDangerousModePermissionPrompt": true` to each such account's
   `~/.claude-<id>/settings.json`. Skip this for accounts set up with
   manual approval instead — there's no bypass-mode dialog to suppress.

## Step 4: First run per account — manual, interactive, one at a time

Before assuming any example invocation is correct, run
`docker run --rm --entrypoint happy claude-pod --help` and use whatever
flag syntax it actually reports — `happy-coder`'s CLI has changed shape
before (an older `--claude-arg <arg>` wrapper flag no longer exists; flags
now pass straight through). Then:

```bash
cd <project folder from Step 0>
CLAUDE_CONFIG_DIR=~/.claude-<id> CLAUDE_POD_HOME=~/.claude-pod-<id> \
HAPPY_HOME_DIR=~/.happy-<id> HAPPY_MACHINE_NAME=<id> \
  ~/tools/claude-pod/claude-pod happy   # append --dangerously-skip-permissions only if Step 0 chose bypass for this account
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
Write one unit per account from the template, using each account's own
Step 0 choice — include `--dangerously-skip-permissions` in `ExecStart`
only for accounts that opted into bypass mode. `daemon-reload`, then
`systemctl --user enable --now happy@<id>` **one account at a time** —
confirm each is stable (`NRestarts` not climbing) before starting the next.
For a manual-approval account, also confirm during this step that
permission prompts actually surface somewhere reachable (e.g. the mobile
app) rather than silently hanging — this combination wasn't exercised
end-to-end when this skill was written, so verify it for real here.

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
- For any account using `--dangerously-skip-permissions` (per the Step 0
  choice): this is a materially larger blast radius on an unattended,
  auto-restarting container than in one interactive session. The user
  already made this choice explicitly in Step 0 — just remind them what
  it means now that it's actually live.
- No network restriction on these containers by default (`NET=none` is
  available but not applied automatically).
- No resource limits (`MEMORY=`/`CPUS=`) by default — worth setting if
  running many accounts concurrently on constrained hardware.
