# Design: Claude config access + host-service reachability for claude-pod

Date: 2026-07-17

## Motivation

`claude-pod` deliberately keeps the sandboxed container blind to everything
outside the launched project folder, including the host's real `~/.claude/`.
That's documented as an explicit guarantee in the README ("other projects —
all unreachable", "No writes to ... your existing `~/.claude/`").

That guarantee is also why the pod is currently missing things the user
relies on when running Claude Code normally: personal skills, installed
plugins (e.g. the `superpowers` marketplace), global `CLAUDE.md` instructions,
and `settings.json`/`statusline.sh`. None of that is available inside the
pod today, so Claude running there is missing capabilities it has on the
host.

Separately, tests run inside the pod sometimes need to reach a service
already running on the host (e.g. a local Postgres or Redis bound to
`127.0.0.1`). The container's network namespace can't see host loopback
services by default.

This spec covers both, scoped narrowly:
1. Give the pod read-only access to a curated subset of `~/.claude/` (plus a
   directory it depends on), on by default.
2. Let the pod optionally resolve `host.docker.internal` so it can reach
   host-bound services, opt-in per run.

## 1. Curated `~/.claude` mount (on by default, read-only)

### What gets mounted

Six host paths, each bind-mounted `:ro` into the container at the **same
relative offset under `$HOME`** as they have on the host (container `$HOME`
is `/home/claude-pod`):

| Host path | Container path | Why |
|---|---|---|
| `~/.claude/skills` | `/home/claude-pod/.claude/skills` | Personal skills |
| `~/.agents` | `/home/claude-pod/.agents` | On this host (and likely others using the same cross-tool skill-manager convention), `~/.claude/skills/*` entries are symlinks into `~/.agents/skills/*`. Mounting `~/.claude/skills` alone would give the container a directory of dangling symlinks. Mounting `~/.agents` at the same relative path lets the existing relative symlinks resolve exactly as they do on the host. |
| `~/.claude/plugins` | `/home/claude-pod/.claude/plugins` | Installed marketplace plugins/skills (e.g. `superpowers`). Self-contained — doesn't symlink outside itself. |
| `~/.claude/CLAUDE.md` | `/home/claude-pod/.claude/CLAUDE.md` | Global user instructions, so pod behavior matches host behavior. |
| `~/.claude/settings.json` | `/home/claude-pod/.claude/settings.json` | Model/permissions/statusline config. |
| `~/.claude/statusline.sh` | `/home/claude-pod/.claude/statusline.sh` | Referenced by `settings.json`'s `statusLine.command` on this host. Mounting `settings.json` without it would leave the statusline broken. This is the common-convention path; a `statusLine.command` pointing elsewhere is not specially handled (documented limitation, see below). |

All six are mounted **read-only** (`:ro` suffix) — the container can never
write back to any of them, so this doesn't create a new mechanism for the
sandbox to modify host Claude config.

### Existence guard

Each of the six mounts is added **only if the source path exists** on the
host (`[ -e "$HOME/..." ]`). This is required, not optional: Docker's bind
mount auto-creates the *target* path if the *source* is missing, and because
source and target share the same relative path here, an unconditional mount
would silently create an empty file/directory inside the user's real
`~/.claude` or `~/.agents` the first time they run `claude-pod` without one
of these paths present — mutating host state, which is exactly what this
tool promises never to do (see the existing comment in `claude-pod` about
`~/.claude-pod/.claude.json` needing to pre-exist for the same reason).

A host with none of the six paths present (e.g. a fresh machine, or one that
has never used Claude Code outside the pod) sees no behavior change: no
mounts are added, and nothing is created under the host's `~/.claude` or
`~/.agents`.

### Known limitations (accepted, not engineered around)

- If `statusLine.command` in `settings.json` points somewhere other than
  `~/.claude/statusline.sh`, or a hook in `settings.json` references a script
  outside the six mounted paths, that command will fail inside the pod
  (file not found). This is a documented limitation, not a bug: recursively
  discovering every path a settings file might reference is out of scope.
- `~/.claude/plugins` also isn't guaranteed self-contained on every possible
  host/plugin combination — only verified for what's on this host today. If
  a plugin turns out to symlink outside `~/.claude/plugins`, the same class
  of fix (mount the target) would apply; not pre-emptively handled.
- Read-only means Claude in the pod can *see* skills/plugins/instructions,
  but can't install a new plugin or edit global `CLAUDE.md` from inside the
  pod — that has to happen on the host.

## 2. `HOST_SERVICES=1` — opt-in container→host reachability

Adds `--add-host=host.docker.internal:host-gateway` to the `docker run`
invocation when `HOST_SERVICES=1` is set. This is a single Docker flag, no
new containers, no new images, no new required tools.

This is intentionally **coarse, not port-scoped**: once the container can
resolve `host.docker.internal`, it can attempt to connect to any port bound
on the host's loopback interface, not just whichever one your tests care
about. Docker has no `docker run` flag or compose key that restricts *which*
host ports are reachable through `host-gateway` — enforcing that would
require a relay process in front of every allowed port, which is
disproportionate to this tool's existing threat model (the README already
accepts unrestricted outbound network as the default, proportionate risk for
a solo-dev sandbox, with `NET=none` as the opt-out for genuinely untrusted
code). `HOST_SERVICES=1` is the same class of risk, same scale, opt-in the
same way.

Usage: point test config at `host.docker.internal:<port>` (e.g.
`DATABASE_URL=postgres://host.docker.internal:5432/...`) the same way you
would in a docker-compose file using `extra_hosts`.

### Validation

- `HOST_SERVICES=1` and `NET=none` are mutually exclusive — a container with
  no network can't resolve or reach anything on the host either. Same style
  of check as the existing `PORTS`/`NET=none` guard: die with a clear error
  before invoking Docker if both are set.
- No other value of `HOST_SERVICES` is supported (not a port list, not a
  service name) — it's a boolean toggle. Only the literal value `1` enables
  it; anything else (unset, `0`, a typo) is silently treated as not set —
  no dedicated error message, same as how only the literal string `none`
  triggers `NET`'s isolation today and any other value is a silent no-op.

## 3. Documentation updates

- **README "Safe from Claude" list**: note that skills/plugins/global
  instructions are now reachable (read-only) by default; everything else
  outside the project folder is still unreachable exactly as documented
  today.
- **README "Side effects outside the project folder"**: the line "No writes
  to ... your existing `~/.claude/`" stays accurate (still true — read-only)
  but gets a note that it's now *read* by default.
- **README "Exposing ports" / options section**: add `HOST_SERVICES=1`
  alongside `PORTS`, `NET`, `MEMORY`, `CPUS`, `PIDS`, with the
  `host.docker.internal` usage example and the coarse-grained caveat above.
- **`--help` output**: add a row for `HOST_SERVICES=1` under "Isolate/limit"
  or a new "Reach host services" line.

## 4. Testing plan

Manual verification (this is infra, not unit-testable in isolation):

1. Run `claude-pod` on this host; confirm a plugin skill (e.g.
   `/superpowers:brainstorming`) and a personal skill (e.g. `/tdd`) both
   invoke correctly from inside the pod.
2. Confirm `settings.json` config (model, permissions) and the statusline
   render inside the pod the same as on the host.
3. Confirm all six mounts are read-only: `touch` inside each mounted path
   from inside the container fails with a read-only-filesystem error.
4. Simulate a host with none of the six paths present (e.g. temp `$HOME`);
   confirm `claude-pod` runs without error and creates nothing under the
   fake `~/.claude` or `~/.agents`.
5. Confirm `HOST_SERVICES=1` resolves `host.docker.internal` inside the
   container and can reach a service bound to `127.0.0.1` on the host.
6. Confirm `HOST_SERVICES=1 NET=none claude-pod` dies with a clear error
   before touching Docker.

## Out of scope

- Per-port scoping of host-service reachability (relay sidecars, compose,
  network-namespace sharing). Considered and rejected as disproportionate;
  see Motivation/Section 2 above.
- Handling `settings.json` references to scripts/paths outside the six
  mounted paths.
- Changes to `install.sh`/`uninstall.sh` — no new persistent host state is
  created by this feature (all mounts read directly from existing host
  paths), so neither script needs to change.
