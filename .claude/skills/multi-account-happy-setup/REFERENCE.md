# Reference: exact commands, templates, and the reasoning behind each fix

This documents what was actually discovered wiring up a real multi-account
setup, not assumptions. Every fix below was hit as a real failure first,
then root-caused before fixing — don't skip the diagnostic step just
because a fix is documented here; a future `happy-coder`/`claude` release
could change any of this, and the *cause* still needs re-confirming, not
just re-applying the fix blind.

## Step 3 detail: seeding config before first run

**MCP whitelist.** `claude-pod` reads its MCP whitelist from
`$CLAUDE_CONFIG_DIR/.claude.json` (or `$HOME/.claude.json` if unset) — this
account's own file, never the host's default profile. A freshly seeded
`~/.claude-<id>/.claude.json` has no `mcpServers` key at all, so the
default `MCP_SERVERS=codegraph` whitelist fails closed:
`✗ MCP_SERVERS entry 'codegraph' not found in .../.claude.json's mcpServers.`
Fix, per account:
```bash
f=~/.claude-<id>/.claude.json
perm=$(stat -c '%a' "$f")
jq '.mcpServers = (.mcpServers // {}) + {"codegraph": {"type":"stdio","command":"codegraph","args":["serve","--mcp"]}}' "$f" > "$f.tmp" \
  && mv "$f.tmp" "$f" && chmod "$perm" "$f"
```
Adjust the entry to match whatever `jq '.mcpServers.codegraph' ~/.claude.json`
actually returns on the host — don't hardcode the args blindly if the host
config differs.

**Bypass-permissions confirmation.** Even with `--dangerously-skip-permissions`,
Claude Code shows a one-time interactive "Yes, I accept" dialog per profile
(WARNING: Claude Code running in Bypass Permissions mode...). This blocks
forever with no human present. The gate (confirmed by reading the installed
`claude-code` binary's strings) is:
```
pq() = Cr("userSettings")?.skipDangerousModePermissionPrompt || ...localSettings... || ...flagSettings... || ...policySettings...
```
`userSettings` maps to the account's `settings.json`, which `claude-pod`
already bind-mounts read-only from `CLAUDE_CONFIG_DIR`. Fix, per account:
```bash
f=~/.claude-<id>/settings.json
perm=$(stat -c '%a' "$f")
jq '. + {"skipDangerousModePermissionPrompt": true}' "$f" > "$f.tmp" && mv "$f.tmp" "$f" && chmod "$perm" "$f"
```
This is safe specifically *because* claude-pod is already the sandbox
boundary the warning describes — don't set this on a host's regular
`~/.claude/settings.json` used for normal interactive sessions.

Also note: `--dangerously-skip-permissions` and `IS_SANDBOX=1` are **not**
related to this dialog. `IS_SANDBOX` only affects whether
`--dangerously-skip-permissions` is allowed to run as root/UID 0 — moot
here since `claude-pod` always runs as an unprivileged mapped user.

## Step 4 detail: don't trust `--claude-arg` or any other cached invocation

`happy-coder`'s own `--help` is the source of truth, not old docs:
```bash
docker run --rm --entrypoint happy claude-pod --help
```
At time of writing, Happy passes Claude flags straight through (no wrapper
flag needed): `happy --dangerously-skip-permissions`. A stale
`--claude-arg --dangerously-skip-permissions` invocation fails with
`error: unknown option '--claude-arg'` — from `claude` itself, since Happy
just forwards unrecognized args to it. If this resurfaces in a different
form later, re-check `--help` rather than assuming the flag rotted the
same way again.

## Step 5 detail: verification commands

```bash
for acct in <id1> <id2> ...; do
  echo "=== $acct ==="
  [ -s ~/.claude-pod-$acct/.credentials.json ] && echo "credentials: YES" || echo "credentials: NO"
  python3 -c "
import json
with open('$HOME/.claude-pod-$acct/.claude.json') as f: data = json.load(f)
for path, info in data.get('projects', {}).items():
    print(f'  {path}: hasTrustDialogAccepted={info.get(\"hasTrustDialogAccepted\")}')
"
  ls ~/.happy-$acct/access.key ~/.happy-$acct/sessions.json 2>/dev/null
done
```

## Step 6 detail: the systemd unit template

```ini
[Unit]
Description=Happy Coder + claude-pod sandbox for <id>
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=<project folder chosen in Step 0 -- NOT necessarily %h/code/<id>>
Environment=CLAUDE_CONFIG_DIR=%h/.claude-<id>
Environment=CLAUDE_POD_HOME=%h/.claude-pod-<id>
Environment=HAPPY_HOME_DIR=%h/.happy-<id>
Environment=HAPPY_MACHINE_NAME=<id>
ExecStart=/usr/bin/script -qec "%h/path/to/claude-pod happy" /dev/null
ExecStop=-/usr/bin/docker stop <id>
Restart=always
RestartSec=5
StandardOutput=append:%h/.happy-logs/<id>.log
StandardError=append:%h/.happy-logs/<id>.log

[Install]
WantedBy=default.target
```

Append ` --dangerously-skip-permissions` inside the quoted `script` command
only for accounts that chose bypass mode in Step 0 — for manual-approval
accounts, leave it off and confirm during Step 6 that permission prompts
actually surface somewhere reachable (mobile app) instead of hanging the
service with no way to respond; this combination is untested as of writing.

Three details that are easy to "simplify away" and shouldn't be:

1. **`After=network-online.target` only — deliberately no
   `Requires=docker.service`/`After=docker.service`.** A `systemctl --user`
   manager cannot reference a system-level unit at all (different manager
   namespace); adding it produces `Unit docker.service not found` and the
   service fails to start outright. `Restart=always`/`RestartSec=5` already
   covers any boot-order race with the real system Docker daemon.

2. **`ExecStart` is wrapped in `script -qec "..." /dev/null`, not called
   directly.** Under systemd there's no controlling terminal, so
   `claude-pod`'s own `[ -t 0 ]`/`[ -t 1 ]` checks (which decide whether to
   add Docker's `-i`/`-t` flags) both evaluate false. Without a pty, Claude
   Code's CLI silently assumes non-interactive `--print` mode and crash-loops
   with `Error: Input must be provided either through stdin or as a prompt
   argument when using --print`. `script` allocates a real pty pair on the
   host side (discarding the transcript to `/dev/null`), which makes those
   checks true and gets Docker's `-it` added normally. Confirm this is still
   needed by checking `claude-pod`'s own `-t`/`-i` detection logic before
   assuming a newer version doesn't still need it.

3. **`HAPPY_MACHINE_NAME` is also used as the container's `--name`, not
   just `--hostname`** (this needs `claude-pod` itself to set
   `DOCKER_FLAGS+=("--hostname" "$HAPPY_MACHINE_NAME" "--name" "$HAPPY_MACHINE_NAME")`
   when the var is set — add this if an older `claude-pod` clone only sets
   `--hostname`). Reasoning: `ExecStop=docker stop <id>` needs a name to
   target. Without one, `systemctl restart` (or crash-triggered
   `Restart=always`) does NOT reliably stop the old container — signal
   propagation through `script` → `claude-pod`'s `exec docker run` did not
   reliably reach a pty-attached container in testing, leaving the OLD
   container running indefinitely alongside a NEW one, both live,
   silently, under the same account. With an explicit `--name`, a stuck old
   container instead makes the new `docker run` fail loudly (Docker refuses
   to reuse a running name) — a visible failure instead of a silent
   duplicate. Confirm after ANY change here: `docker ps --filter
   ancestor=claude-pod` should show exactly one container per account,
   always — check this explicitly after every restart/crash test, not just
   that the systemd unit reports active.

## Step 7 detail: `docker attach` behavior, verified

Attaching to one of these containers (`docker attach <id>`) does show the
live session's real terminal output and accepts real keystrokes — the
container was started with `-i`/`-t` (see Step 6), so this works the same
as attaching to any interactive container. Two things confirmed by testing
against a real running account, not assumed:

1. **Killing the *attach client* process (even with `SIGKILL`) does not
   affect the container.** `docker attach` is a viewer/multiplexer, not the
   process owner — the container, and the live Claude/Happy session inside
   it, keeps running exactly as before. Confirmed by force-killing an
   attach client and checking the container was still `Up` and the
   session's `claude.exe` process was still alive immediately after.
2. **A plain `SIGTERM` to the `docker attach` client does *not* reliably
   make it exit** — in testing, `timeout 5 docker attach --no-stdin <id>`
   did not stop after 5 seconds; the client process was still running
   noticeably later and had to be killed with `SIGKILL`. If this is ever
   invoked from something non-interactive (a script, a health check), don't
   assume a `timeout`-wrapped `docker attach` will actually terminate on
   schedule — verify it, or kill it by PID afterward, same as here.

Interactively, the correct way to leave without disturbing anything is
Docker's own detach sequence: `Ctrl+P` then `Ctrl+Q`. `Ctrl+C` is not a
detach — it sends SIGINT into whatever's running in the container's
foreground (the live Claude session), which would interrupt it.

**`/exit` is a third, distinct way people reach for by habit, and it's not
a detach either.** It's Claude Code's own command to end its session —
since this is the same shared session the mobile app is connected to (not
a separate view), `/exit` ends that session for the phone too, not just
locally. What happens next follows directly from `Restart=always` having
no `RestartPreventExitStatus` configured: it restarts on any exit, clean
or crashed, so the account comes back on its own in ~5-10s (same recovery
path as the crash-kill test in 7.8) — but it's a *new* session, not a
resume of the one that was just ended, since `ExecStart` doesn't pass
`--resume`. This specific path (a clean in-app `/exit`, as opposed to an
external `docker kill`) was reasoned through from systemd's documented
semantics, not independently exercised the way 7.8 was — if it matters,
verify it for real rather than trust this note alone.

## Step 8 detail: exact test commands

**7.1 Basic liveness**
```bash
systemctl --user status 'happy@*'   # all should be active (running)
```

**7.2 No container name/hostname collisions**
```bash
docker ps --filter ancestor=claude-pod --format '{{.Names}}\t{{.ID}}' | while read name id; do
  echo "$name | hostname=$(docker inspect --format '{{.Config.Hostname}}' "$id")"
done
# expect exactly one row per account, hostname == that account's id
```

**7.3 Credential isolation**
```bash
for acct in <id1> <id2> ...; do
  echo -n "$acct userID: "; jq -r '.userID' ~/.claude-pod-$acct/.claude.json
done
# every userID must be distinct
```

**7.4 Mobile app session list** — manual: open Happy Coder, confirm one
entry per account, each correctly labeled by `HAPPY_MACHINE_NAME`. Send a
trivial prompt to each from the phone and confirm the response references
that account's actual project folder (the one chosen in Step 0), not
another account's.

**7.5 Persistence across restart**
```bash
systemctl --user show happy@<id>.service -p NRestarts --value   # note value
jq -r '.userID' ~/.claude-pod-<id>/.claude.json                  # note value
systemctl --user restart happy@<id>.service
sleep 8
systemctl --user is-active happy@<id>.service        # expect: active
jq -r '.userID' ~/.claude-pod-<id>/.claude.json       # expect: unchanged
[ -s ~/.claude-pod-<id>/.credentials.json ] && echo YES  # expect: YES
# then check docker ps per 7.2 -- must still show exactly one container for <id>
```
In the mobile app: confirm it reconnects without a new pairing QR, Claude
doesn't re-prompt for login, and prior conversation history is still
visible/resumable.

**7.6 Persistence across host reboot** (needs the user's OK before doing this)
Same checks as 7.5, after an actual reboot (or at minimum full
`systemctl --user stop` of all units, `daemon-reload`, start again).
Confirm lingering actually took effect: `loginctl show-user $USER | grep Linger`
should show `yes`.

**7.7 Workspace trust holds**
```bash
journalctl --user -u happy@<id>.service -n 100 --no-pager | grep -i trust
# expect: no output at all
```

**7.8 Crash recovery**
```bash
docker kill <id>
sleep 8
systemctl --user is-active happy@<id>.service              # expect: active
systemctl --user show happy@<id>.service -p NRestarts --value  # expect: incremented by 1
# then check docker ps per 7.2 -- must show exactly one container for <id>, not two
```

**7.9 Concurrent load** (needs the user's phone) — send a prompt to every
account within the same few seconds; confirm all respond independently
with no cross-talk (e.g. one account's response referencing another
account's repo), and no container gets OOM-killed if resource limits
aren't set.
