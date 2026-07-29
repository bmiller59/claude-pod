# claude-pod

> Docker sandbox for the Claude Code CLI. Runs Claude against one project folder — including with `--dangerously-skip-permissions` — while your home directory, SSH keys, and other projects stay invisible to the container. Unofficial.

> **This is Brendan's personal fork** of [trekhleb/claude-pod](https://github.com/trekhleb/claude-pod). Kept clean and general-purpose where that's easy, but a few things (like `codegraph` baked into the default image) are here specifically because Brendan uses them constantly — see [CLAUDE.md](CLAUDE.md). If you're not Brendan, the upstream repo is probably the better starting point.

![claude-pod](assets/cover.jpeg)

## TL;DR

`claude-pod` runs Claude Code inside a Docker container that mounts the project folder you launch it from. Claude can read and edit that folder; the rest of your machine — home directory, SSH keys, other projects, host shell — isn't mounted, so the container can't see it.

It's useful in two cases:

- With `--dangerously-skip-permissions`: you get auto-approval without giving Claude access to your whole machine.
- In normal, prompt-by-prompt mode: the container still caps the blast radius, so an over-broad command, prompt injection, or a malicious dependency can't reach past the project folder.

It's not full isolation — here's the boundary:

- ✅ **Outside the launch folder is unreachable — with one narrow, read-only exception.** Your home directory, `~/.ssh`, `~/.aws`, other projects, and the host shell aren't mounted, so the container can't see them.
- 📖 **Your Claude Code config is mounted read-only, by default.** Personal skills, installed plugins, global `CLAUDE.md`, and `settings.json`/`statusline.sh` are bind-mounted from the host so Claude behaves the same inside the pod — readable, never writable. Everything else under your home directory (credentials, session history, other projects' transcripts) stays unmounted. See [Claude config access](#claude-config-access).
- ⚠️ **Inside the launch folder is fully exposed.** Any `.env`, `.git/config`, or keys in it are readable and writable; outbound network is open, so contents can be read or exfiltrated; and your Anthropic login is stored on the host under `~/.claude-pod/`.
- 🚫 **Don't launch from `~` or `/` or other sensitive folders.** That mounts your whole home or filesystem into the container and defeats the point.

The practical effect: the worst case is narrowed from "your whole machine" to "this one folder," which is recoverable from git.

```sh
# Clone this repo once, anywhere you like (~/tools/claude-pod is just an example)
git clone https://github.com/bmiller59/claude-pod.git ~/tools/claude-pod

# Build the image (once) — runs from anywhere, no cd needed
~/tools/claude-pod/install.sh

# cd into your project, then launch Claude
cd ~/projects/your-project
~/tools/claude-pod/claude-pod claude --dangerously-skip-permissions

# Long path? You can alias it — see "Aliases" below.

# Forgot a command later? Print a copy-pastable cheatsheet of all of them
~/tools/claude-pod/claude-pod --help
```

Docker is the only requirement — no Node.js, npm, or `claude` needed on your host. (One exception: [whitelisting MCP servers](#mcp-servers) needs `jq` on the host, but only if you use that feature.) For the full threat model and the four-file design, see [Security and limits](#security-and-limits). For the official approach, see Anthropic's [Claude Code sandboxing documentation](https://code.claude.com/docs/en/sandboxing).

## Contents

- [Usage](#usage)
  - [Requirements](#requirements)
  - [Running claude-pod](#running-claude-pod)
  - [Aliases](#aliases)
  - [Running Happy Coder](#running-happy-coder)
  - [First launch (login)](#first-launch-login)
  - [Permission prompts that survive `--dangerously-skip-permissions`](#permission-prompts-that-survive---dangerously-skip-permissions)
  - [Exposing ports](#exposing-ports)
  - [Claude config access](#claude-config-access)
  - [Installing skills and plugins](#installing-skills-and-plugins)
  - [Multiple accounts / profiles](#multiple-accounts--profiles)
  - [Reaching host services](#reaching-host-services)
  - [MCP servers](#mcp-servers)
  - [Forwarding environment variables](#forwarding-environment-variables)
  - [Pasting images and screenshots](#pasting-images-and-screenshots)
  - [Updating or pinning the Claude Code version](#updating-or-pinning-the-claude-code-version)
  - [Customizing the image](#customizing-the-image)
  - [Installing extra tools per-instance](#installing-extra-tools-per-instance)
- [Security and limits](#security-and-limits)
  - [What it actually does](#what-it-actually-does)
  - [What is and isn't isolated](#what-is-and-isnt-isolated)
  - [Network isolation and resource limits](#network-isolation-and-resource-limits)
  - [Side effects outside the project folder](#side-effects-outside-the-project-folder)
- [Reference](#reference)
  - [Platforms](#platforms)
  - [Uninstall](#uninstall)
  - [License and trademarks](#license-and-trademarks)

## Usage

### Requirements

**Just Docker.** Claude Code runs inside the container, not on your host — you do not need Node.js, npm, or the `claude` CLI installed on your machine. The host stays untouched apart from one state folder (`~/.claude-pod/`, overridable — see [Multiple accounts / profiles](#multiple-accounts--profiles)) that exists only to keep your login across container restarts.

### Running claude-pod

Call the script using its full or relative path from any project:

```sh
cd ~/projects/anything
~/tools/claude-pod/claude-pod
```

You land in a bash shell at the same path your project lives at on the host (e.g. `/Users/you/projects/anything`), with `claude` on `PATH`. Run it however you like:

```sh
claude --dangerously-skip-permissions
```

Alternatively, you may skip the shell and go straight into Claude. Anything you pass to `claude-pod` is run inside the container instead of bash. So this drops you directly into Claude in one command, and exits the container when Claude exits:

```sh
~/tools/claude-pod/claude-pod claude --dangerously-skip-permissions
```

To exit, type `exit`.

Forgot a command later? Run `~/tools/claude-pod/claude-pod --help` (or `-h`) anytime — it prints a copy-pastable cheatsheet of every command (run, install, update, uninstall, options), with the correct absolute paths for your install.

### Aliases

For your convenience, you can add an alias to your shell configuration file (`~/.zshrc`, `~/.bashrc`, etc.):

```sh
alias claude-pod=~/tools/claude-pod/claude-pod
```

This is the shell-first form: `claude-pod` drops you into the container with `claude` on `PATH`, so you can run `npm install`, a dev server, or tests and then start `claude` yourself — all inside the sandbox. The same alias also goes straight into Claude when you pass the command through: `claude-pod claude --dangerously-skip-permissions`.

### Running Happy Coder

[Happy Coder](https://happy.engineering) (`happy`) is baked into the image as an alternative front-end for Claude Code — it adds encrypted mobile/web session pairing on top of the same underlying `claude` process. Happy passes Claude flags straight through, so use them exactly as you would with `claude` itself:

```sh
claude-pod happy --dangerously-skip-permissions
```

Happy keeps its own state (auth/session data for the pairing) under `HAPPY_HOME_DIR` (default `~/.happy`) — that's Happy's own env var, not something `claude-pod` invented, so it works the same whether you run `happy` directly on your host or through the pod. This is the one state dir in this project that **isn't** pod-exclusive by default: if you also run `happy` natively on your host, the pod shares that same `~/.happy` directory (read-write) rather than getting a separate copy the way `~/.claude-pod` does for Claude's own login. If you'd rather keep the pod's Happy state separate, point it at its own directory:

```sh
HAPPY_HOME_DIR=~/.happy-pod claude-pod happy --dangerously-skip-permissions
```

Because the default isn't pod-exclusive, `uninstall.sh` deliberately does **not** remove `~/.happy` (or a custom `HAPPY_HOME_DIR`) — doing so could delete real host-side Happy state. Clean that up yourself if you used a dedicated directory and no longer need it.

### First launch (login)

The first time you start Claude inside the pod, it will print a login URL. Open it in your host browser, complete the login, paste the verification code back into the container, and you're done. The session persists in `~/.claude-pod/` (or `CLAUDE_POD_HOME` if set — see [Multiple accounts / profiles](#multiple-accounts--profiles)) and survives container restarts — you only do this once per machine (per state dir).

### Permission prompts that survive `--dangerously-skip-permissions`

`--dangerously-skip-permissions` bypasses Claude Code's tool-permission system, but a few other confirmation gates sit outside that system entirely and are **not** suppressed by it — worth knowing about, since a headless pod (a `happy@*` systemd service, say) has no one at the keyboard to answer them:

- **Workspace trust, per directory.** Claude Code tracks "do you trust this folder" separately from tool permissions, keyed by the exact working directory — recorded per-path in the pod's own `.claude.json` (`$POD_HOME/.claude.json`, bind-mounted and writable, so acceptance does persist across container restarts once given). The trap: trust is **not** inherited by subdirectories. If the agent `cd`s into a git submodule or a monorepo package it hasn't visited before, that path gets its own untrusted entry and blocks until someone accepts it — even though the parent repo is already trusted and the session is running fully bypassed otherwise. Fix a stuck one by hand: set `"hasTrustDialogAccepted": true` for that path's entry under `"projects"` in `$POD_HOME/.claude.json`.
- **The `skipDangerousModePermissionPrompt` first-run dialog.** The very first time bypass mode is used, Claude Code normally shows a one-time "I accept the risk" confirmation; a background/headless run has no way to answer it. Set `"skipDangerousModePermissionPrompt": true` in the profile's `settings.json` ahead of time to pre-accept it — needed for any account that will run non-interactively (systemd, CI, etc.) before its first launch.
- **Explicit `ask` rules and `requiresUserInteraction` MCP tools.** A `permissions.ask` entry in `settings.json`, or an MCP tool whose definition sets `_meta["anthropic/requiresUserInteraction"]`, forces a prompt regardless of permission mode. Not an issue unless you've added one yourself or an MCP server declares it.
- **The `rm -rf /` / `rm -rf ~` circuit breaker.** Always prompts, by design, with no override — including when the destructive command is hidden behind `$(...)`/backtick/`<(...)` substitution. This one can't be pre-accepted and isn't meant to be.

None of this is `claude-pod`-specific — it's how Claude Code's permission modes work in general — but it matters more here because these pods are routinely run unattended.

**A starter `permissions.allow` list is seeded into each of the 4 profile `settings.json` files** (`~/.claude-seas`, `-nextspace`, `-tessero`, `-tessero-bam`) — the `codegraph` MCP tools plus common read-only/low-risk commands (`git diff`/`status`/`log`/`show`, `ls`, `grep`, `find`, `cat`, `npm`/`npx`/`yarn` test-and-lint scripts, `curl -s`, read-only `gh` lookups, `WebSearch`/`WebFetch`). This doesn't change what bypass mode already allows — it's a defense-in-depth measure in case a session ever isn't fully bypassed, or a future Claude Code version narrows what bypass mode covers. It does **not** help with any of the gates above (workspace trust, the circuit breaker) — those aren't allow-list-shaped problems. Edit `permissions.allow` directly in a profile's `settings.json` to extend it; see [Claude Code's permission-rule syntax](https://code.claude.com/docs/en/permissions) for the `Tool(pattern)` format.

**`claude-pod` pre-seeds workspace trust for you, to specifically address the first bullet above.** If you launch `claude-pod` at a parent directory that spans several repos — the pattern this project recommends for a long-running `happy@*` pod you `cd` around inside rather than restart per-repo — every `git`-repo root found under `$PWD` (skipping `node_modules`/`vendor`/`.venv`) gets `"hasTrustDialogAccepted": true` written into `$POD_HOME/.claude.json` *before* Claude ever starts, so a `cd` into a sibling repo or a submodule mid-session never hits the trust dialog at all.

This defaults to **silent, unprompted auto-approval** — a deliberate privacy/security tradeoff, not an oversight. The reasoning: `claude-pod`'s actual trust boundary is the Docker mount, not Claude Code's per-directory trust dialog — only `$PWD` and what's under it is ever visible inside the container in the first place (see [What is and isn't isolated](#what-is-and-isnt-isolated)). A second, per-subdirectory confirmation gate for something the sandboxed session can already read and execute inside that same mount doesn't add real isolation, it only adds friction — and friction a headless systemd pod has no way to answer, which is exactly the failure mode this whole section is about. If that tradeoff isn't right for a directory you don't fully control the contents of (e.g. a parent folder you don't own every repo under), set `TRUST_PROMPT=1` to get an interactive `[y/N]` per repo instead; it's skipped (with a warning, not a hang) when stdin isn't a terminal, so it degrades safely rather than wedging a headless launch.

**That launch-time scan only covers repos that already exist when the container starts** — it can't see a directory created *during* the session, most commonly a `git worktree add` for a feature branch. For that, the image bakes in a `PostToolUse` hook (`/etc/claude-code/managed-settings.json` — see the Dockerfile) that fires right after any `git worktree add ...` command and re-seeds trust for every worktree `git worktree list --porcelain` reports for that repo, same silent-auto-approve tradeoff as above. It's baked into the image rather than a profile's `settings.json` on purpose: that file is one `claude-pod` bind-mounts **read-only**, so there'd be no way to apply a hook there from inside the sandbox, and managed settings apply to every profile uniformly with no per-account setup. It's scoped to the literal `git worktree add` prefix, so it won't fire if that's chained behind `&&` in the same Bash call, and it doesn't (yet) cover a brand-new sibling repo dropped in some other way, e.g. a fresh `git clone` mid-session.

### Exposing ports

By default, `claude-pod` doesn't publish any ports to the host (outbound traffic is still unrestricted — see [What is and isn't isolated](#what-is-and-isnt-isolated)). Map ports through with the `PORTS` environment variable:

```sh
# Map a single port (127.0.0.1:3000 -> container:3000)
PORTS=3000 claude-pod

# Map multiple ports
PORTS="3000 5173" claude-pod

# Map a specific host port to a different container port
PORTS="8080:80" claude-pod

# Or, alternatively, without using aliases
PORTS="5173:5173" ~/tools/claude-pod/claude-pod
```

> **Bind your dev server to `0.0.0.0` inside the container, not `localhost`.** Most dev servers default to `localhost`, which means they only listen on the container's own loopback — your host browser can't reach them even with `PORTS=...` set. Common fixes:
> - **Vite:** `npm run dev -- --host` (or `vite --host 0.0.0.0`)
> - **Next.js:** `next dev -H 0.0.0.0`
> - **Create React App / webpack-dev-server:** `HOST=0.0.0.0 npm start`
> - **Django:** `manage.py runserver 0.0.0.0:8000`
> - **Rails:** `rails s -b 0.0.0.0`
>
> The host-side mapping is still `127.0.0.1`-only (forced by `claude-pod`), so binding `0.0.0.0` inside the container does not expose your dev server to your LAN.

### Claude config access

By default, `claude-pod` bind-mounts a curated, **read-only** subset of your host's Claude Code config, so Claude behaves the same inside the pod as it does on your host:

- `~/.claude/skills` — your personal skills.
- `~/.agents` — if your `~/.claude/skills/*` entries are symlinks (some skill-manager setups do this), this is where they actually resolve to. Mounted at the same relative path so the symlinks work inside the container too.
- `~/.claude/plugins` — installed marketplace plugins (e.g. `superpowers`).
- `~/.claude/CLAUDE.md` — your global instructions.
- `~/.claude/settings.json` and `~/.claude/statusline.sh` — model/permissions/statusline config.
- `~/.claude/profile-tag` — optional; see [Multiple accounts / profiles](#multiple-accounts--profiles).

Each of these is mounted only if it exists on your host, and only read-only — Claude can see them but can never write back, install a new plugin, or edit your global `CLAUDE.md` from inside the pod.

Don't have a `statusline.sh` yet? [`docs/statusline.sh`](docs/statusline.sh) is a copy-pasteable reference implementation — pod/host indicator, repo/branch, model, context-window and rate-limit usage, and (if you use [multiple profiles](#multiple-accounts--profiles)) a profile letter. Save it as `~/.claude/statusline.sh` (`chmod +x`) and point `settings.json` at it:

```json
"statusLine": { "type": "command", "command": "~/.claude/statusline.sh", "padding": 0 }
```

This is deliberately **not** the whole `~/.claude/` directory: your `.credentials.json`, `history.jsonl`, and `projects/` (session transcripts from every other project you've used Claude Code on) are never mounted, so "other projects are unreachable" ([What is and isn't isolated](#what-is-and-isnt-isolated)) still holds.

If your `settings.json` references a hook or `statusLine.command` pointing somewhere other than the paths above, that reference will fail inside the pod (file not found) — only the paths listed here are mounted.

> **Project-scoped plugins won't activate inside the pod — only user-scoped ones will.** Run `claude plugin list` (or check `~/.claude/plugins/installed_plugins.json`) on your host: plugins installed at `"scope": "user"` show up inside the pod, but a plugin installed at `"scope": "project"` (pinned to one project path) does not, even though its skill files are mounted and readable. That's because project-scope activation is resolved through your host's real `~/.claude.json` (a file sibling to `~/.claude/`, holding trust/config state for *every* project you've used Claude Code in), which the pod intentionally does not mount — mounting it would undo "other projects are unreachable" above. If a plugin you rely on inside the pod is project-scoped, reinstall it at user scope on your host.

The source directory for all of this defaults to `~/.claude` but is overridable with `CLAUDE_CONFIG_DIR` — see [Multiple accounts / profiles](#multiple-accounts--profiles) below. `~/.agents` is the one exception: it's always read from `$HOME/.agents` regardless, since it's a skill-manager symlink target unrelated to which Claude account is active.

### Installing skills and plugins

`claude-pod` never installs anything into `~/.claude/` itself — it only mounts what's already there (see [Claude config access](#claude-config-access) above), so a new plugin has to be installed with the host's own `claude` CLI, not from inside the pod:

```sh
claude plugin marketplace add <owner>/<repo>
claude plugin install <plugin>@<marketplace>
```

For the default profile (no `CLAUDE_CONFIG_DIR`), that's the whole story — install normally on the host and it shows up inside the pod on the next run, no extra step, since it's the same `~/.claude/plugins` either way.

**If you're running [multiple profiles](#multiple-accounts--profiles), install separately into each one.** Each `CLAUDE_CONFIG_DIR` is a fully independent Claude account with its own plugin manifest — installing a plugin under the default `~/.claude` does *not* make it visible to a `CLAUDE_CONFIG_DIR=~/.claude-tessero` pod, even though both are mounted by the same `claude-pod` script. Point `CLAUDE_CONFIG_DIR` at the profile you're adding it to:

```sh
CLAUDE_CONFIG_DIR=~/.claude-tessero claude plugin marketplace add obra/superpowers-marketplace
CLAUDE_CONFIG_DIR=~/.claude-tessero claude plugin install superpowers@superpowers-marketplace
```

Repeat per profile. Personal skills (`~/.claude/skills/*`, not installed via the plugin marketplace) work the same way — they have to actually exist under each profile's own config dir to be mounted there.

If the profile is a running `happy@*` systemd service (see [`multi-account-happy-setup`](.claude/skills/multi-account-happy-setup/SKILL.md)), the plugin mount is only evaluated when the container starts, so restart that service after installing — `systemctl --user restart happy@tessero.service` — or it won't pick up the new plugin until its next natural restart.

### Multiple accounts / profiles

If you use more than one Claude account — say, separate `~/.claude-tessero` and `~/.claude-nextspace` config directories on your host, switched between via `claude`'s own `CLAUDE_CONFIG_DIR` env var — `claude-pod` recognizes the same variable:

```sh
CLAUDE_CONFIG_DIR=~/.claude-tessero claude-pod claude --dangerously-skip-permissions
```

This replaces the default `~/.claude` as the source for skills/plugins/`CLAUDE.md`/`settings.json`/`statusline.sh` (see [Claude config access](#claude-config-access)), and also relocates the `~/.claude.json` lookup used for [MCP server whitelisting](#mcp-servers) to `$CLAUDE_CONFIG_DIR/.claude.json` — matching where Claude Code itself puts it for a custom config dir, so a profile's own MCP servers get picked up automatically. Setting `CLAUDE_CONFIG_DIR` to a path that doesn't exist fails fast with a clear error before Docker runs.

`CLAUDE_CONFIG_DIR` only changes what's *read* from the host, though — by itself it does **not** give each profile its own pod state (auth/session). Every pod still shares one `~/.claude-pod/`, so running two profiles at the same time would have them fight over the same login. For that, also set `CLAUDE_POD_HOME` (default `~/.claude-pod`) to a distinct path per profile:

```sh
CLAUDE_CONFIG_DIR=~/.claude-tessero  CLAUDE_POD_HOME=~/.claude-pod-tessero  claude-pod claude --dangerously-skip-permissions
CLAUDE_CONFIG_DIR=~/.claude-nextspace CLAUDE_POD_HOME=~/.claude-pod-nextspace claude-pod claude --dangerously-skip-permissions
```

The two variables are independent — nothing derives one from the other — but naming `CLAUDE_POD_HOME` with the same suffix as `CLAUDE_CONFIG_DIR` (as above) keeps profiles easy to tell apart. Each `CLAUDE_POD_HOME` gets its own auth token and session history, so the two pods above can run concurrently, fully logged into different Claude accounts, without interfering with each other.

Typing both variables out every time gets old fast — fold each profile into its own alias instead, one per profile, in your shell configuration file:

```sh
alias claude-pod-tessero='CLAUDE_CONFIG_DIR=~/.claude-tessero CLAUDE_POD_HOME=~/.claude-pod-tessero ~/tools/claude-pod/claude-pod claude --dangerously-skip-permissions'
alias claude-pod-nextspace='CLAUDE_CONFIG_DIR=~/.claude-nextspace CLAUDE_POD_HOME=~/.claude-pod-nextspace ~/tools/claude-pod/claude-pod claude --dangerously-skip-permissions'
```

Each is the shell-through-to-Claude form (see [Aliases](#aliases) above) rather than the shell-first form, so running `claude-pod-tessero` drops straight into that profile's Claude session. Swap in `happy` for `claude` in the alias if you'd rather land in [Happy Coder](#running-happy-coder) for that profile instead.

**Telling profiles apart in the statusline.** [`docs/statusline.sh`](docs/statusline.sh) shows a profile letter derived from `CLAUDE_CONFIG_DIR`'s basename (e.g. `~/.claude-tessero` → `t`) — but `CLAUDE_CONFIG_DIR` itself isn't forwarded into the container, so that derivation only works on the host. Inside a pod, drop a one-line `profile-tag` file next to each profile's `statusline.sh` instead — `claude-pod` bind-mounts it the same way (see [Claude config access](#claude-config-access)) and the script prefers it when present:

```sh
echo -n t > ~/.claude-tessero/profile-tag
echo -n n > ~/.claude-nextspace/profile-tag
```

If `~/.claude-tessero/statusline.sh` is a symlink to your main `~/.claude/statusline.sh` (recommended, so a script update doesn't need copying to every profile), this is the only per-profile file you need to maintain by hand.

> **Want several accounts each reachable from the Happy Coder mobile app, kept running persistently by systemd instead of one-off foreground commands?** See the [`multi-account-happy-setup`](.claude/skills/multi-account-happy-setup/SKILL.md) skill — it walks an agent through the full setup (directory layout, the MCP-whitelist and bypass-permissions gotchas that only surface on first run, the `HAPPY_HOME_DIR`/`HAPPY_MACHINE_NAME` pairing, the systemd unit template, and the recommended test suite) for as many accounts as you name.

### Reaching host services

By default, the container can't reach anything bound to your host's loopback interface (`127.0.0.1`) — a local Postgres, Redis, or other dev-only service is invisible to it, same as the rest of your machine. If your tests need one, set `HOST_SERVICES=1`:

```sh
HOST_SERVICES=1 claude-pod
```

This lets the container resolve `host.docker.internal`. Point your test config at it the same way you'd use `extra_hosts` in a docker-compose file:

```sh
DATABASE_URL=postgres://host.docker.internal:5432/mydb
```

> **On native Linux Docker, bind the service to `0.0.0.0`, not just `127.0.0.1`.** `host.docker.internal` resolves to the Docker bridge gateway IP (e.g. `172.17.0.1`), not to `127.0.0.1` — a service bound only to loopback (the default for a stock Postgres or Redis install) won't accept the connection even though the name resolves. Rebind the service to `0.0.0.0` (or the bridge-facing interface) to reach it. This is the mirror image of the [Exposing ports](#exposing-ports) caveat above, in the opposite direction. Docker Desktop (macOS/Windows) routes `host.docker.internal` through the VM differently and may not have this limitation — not verified here.

This is deliberately coarse, not scoped to one port: once `host.docker.internal` resolves, the container can attempt to reach *any* port on your host's loopback interface, not just the one your tests use. Docker has no flag that restricts host-gateway to specific ports. `HOST_SERVICES=1` and `NET=none` are mutually exclusive.

#### Transparent port forwarding

If you'd rather not touch your test config at all — no `host.docker.internal` rewrite, same connection string in and out of the pod — pass `HOST_SERVICES` a space-separated list of ports instead of `1`:

```sh
HOST_SERVICES="27017 8000" claude-pod
```

For each port listed, the container relays its own `127.0.0.1:<port>` to `host.docker.internal:<port>` via a small `socat` proxy started by the image's entrypoint before your command runs. Code inside the pod can keep connecting to `localhost:27017` unchanged, whether it's running in the sandbox or on your host directly. This is scoped to exactly the ports you name — unlike the `HOST_SERVICES=1` form, it does not open up the rest of your host's loopback interface. The same platform caveat above still applies: the service itself must be bound to `0.0.0.0` (not just `127.0.0.1`) on native Linux Docker for `host.docker.internal` to actually reach it.

### MCP servers

Your host's MCP servers aren't available inside the pod by default — the pod's Claude config is seeded fresh and never touches your host's real `~/.claude.json`, where MCP servers are registered. `claude-pod` whitelists them by name via `MCP_SERVERS`, and **defaults to `codegraph`** (this fork's one personal default — see [CLAUDE.md](CLAUDE.md)):

```sh
# Default: just codegraph. No env var needed.
claude-pod

# Override the default entirely (include codegraph yourself if you still want it too)
MCP_SERVERS="codegraph agentmemory" claude-pod

# Disable MCP servers entirely
MCP_SERVERS=none claude-pod
```

This copies just the named entries out of your host's `~/.claude.json` `mcpServers` object into the pod's own config, replacing it fresh on every run — including a run where the resolved list is empty, so a server whitelisted earlier doesn't linger on a later run that no longer asks for it. A typo — a name not found in your host's `mcpServers` — fails with a clear error before Docker even starts. This step needs `jq` on your host; it's the one place this tool needs something besides Docker, and only when the resolved server list is non-empty.

The server's underlying command has to already exist in the image — `codegraph` is baked into this fork's `Dockerfile` (see [Customizing the image](#customizing-the-image)) since it's used constantly here; anything else you whitelist may need the same treatment, or it'll simply fail to start inside the pod.

If a server's config references env vars (like `agentmemory`'s `AGENTMEMORY_URL`/`AGENTMEMORY_SECRET`), those are **not** forwarded automatically. Name them explicitly with `MCP_SERVER_ENV`:

```sh
MCP_SERVERS=agentmemory MCP_SERVER_ENV="AGENTMEMORY_URL AGENTMEMORY_SECRET" claude-pod
```

This is the same mechanism as the general-purpose [`ENV_PASSTHROUGH`](#forwarding-environment-variables) below, kept under its own name for the MCP-secret case specifically — set either or both, they combine rather than override each other.

This covers locally-configured MCP servers only (your `~/.claude.json`'s `mcpServers` object). claude.ai account connectors (Linear, Notion, Asana, etc.) are a separate mechanism and aren't covered here.

If you're using [`CLAUDE_CONFIG_DIR`](#multiple-accounts--profiles) for a custom profile, this reads that profile's own `mcpServers` (from `$CLAUDE_CONFIG_DIR/.claude.json`) instead of `~/.claude.json`.

### Forwarding environment variables

Nothing from your host shell's environment reaches the container by default — not even something as ordinary as `AWS_PROFILE` or an API key you've exported locally. Name exactly what an instance needs with `ENV_PASSTHROUGH`, a space-separated list of host env var *names* (not values):

```sh
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=us-east-1 \
  ENV_PASSTHROUGH="AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION" \
  claude-pod claude --dangerously-skip-permissions
```

Only the exact vars you list cross into the container (bare `-e NAME`, same pass-through style as `COLORTERM`). Nothing is inferred or auto-detected — a credential only ends up in the sandbox if you name it, since anything forwarded here becomes reachable from code running under `--dangerously-skip-permissions`. This is per-invocation, not baked into the image, so different instances can forward completely different vars (or none) without touching the `Dockerfile`.

`MCP_SERVER_ENV` (see [MCP servers](#mcp-servers) above) is this same mechanism under a name scoped to MCP-server secrets specifically; the two combine if you set both.

### Pasting images and screenshots

Claude can only read files that live **inside the project folder** — that's the one directory bind-mounted into the container. Images on your Desktop or in Downloads aren't mounted, so pasting one straight from there hands Claude a path it can't reach. This is the same isolation that keeps the rest of your machine private from the container ([What is and isn't isolated](#what-is-and-isnt-isolated)); the small bit of friction below is the price for not exposing those default locations.

The workaround:

1. Take the screenshot as usual (it lands on the Desktop, or wherever your OS drops it).
2. Copy the file into your project folder — anywhere under it works, e.g. a `tmp/` subfolder.
3. **Re-copy the file from that new in-project location**, so the path on your clipboard points at the copy that's actually synced into the container.
4. Paste into Claude. The path now resolves inside the container and the image is recognized.

### Updating or pinning the Claude Code version

By default, `install.sh` fetches whatever's currently `latest` on npm, bypassing Docker's cache for that step. It resolves its own location, so you can re-run it from any folder:

```sh
~/tools/claude-pod/install.sh
```

To pin a specific version, set `CLAUDE_CODE_VERSION`:

```sh
CLAUDE_CODE_VERSION=2.0.0 ~/tools/claude-pod/install.sh
```

Pinned versions cache normally across rebuilds. The script prints the resolved version after each build, so you always know what you got.

### Customizing the image

The image is intentionally minimal: `node:24-slim` + `git` + `curl` + `less` + `jq` + `gh` + `unzip` + Claude Code, plus `@colbymchenry/codegraph`, `nvm`, and `happy-coder` (this fork's personal additions — see [CLAUDE.md](CLAUDE.md)). Nothing else language-specific. Anything **every** instance needs (Python, build tools, other toolchains), or another [MCP server](#mcp-servers)'s underlying command, belongs here — edit the `Dockerfile` and re-run `~/tools/claude-pod/install.sh`. Something only *some* instances need doesn't have to go in the shared image at all — see the next section.

### Installing extra tools per-instance

Not every dependency is worth baking into the shared image — a tool only one project or one profile needs (the AWS CLI for a project that touches AWS, say) shouldn't bloat every other instance's container. Two pieces make this possible without a rebuild:

1. **A writable, persistent place to install into.** `CLAUDE_POD_HOME` (default `~/.claude-pod`, see [Multiple accounts / profiles](#multiple-accounts--profiles)) is bind-mounted at `/home/claude-pod/.claude` and survives container restarts — unlike the rest of the container's filesystem, which is discarded on exit (`--rm`). Installing a tool there means you only pay the install cost once per profile, not once per container start.
2. **A hook that loads it automatically.** The image's entrypoint sources `$HOME/.claude/profile.sh` (i.e. `<CLAUDE_POD_HOME>/profile.sh` on the host) before running your command, if that file exists — before `exec`, so it applies uniformly whether you're in an interactive shell or a non-interactive `claude-pod claude ...` run. Nothing to configure; just create the file.

Worked example — AWS CLI + credentials, installed once per profile:

```sh
# One-time, inside a pod session: download and install AWS CLI v2 into the persistent state dir
# instead of the ephemeral container filesystem, so it's still there on your next container start.
claude-pod bash -c '
  curl -sSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip &&
  unzip -q /tmp/awscliv2.zip -d /tmp &&
  /tmp/aws/install -i "$HOME/.claude/tools/aws-cli" -b "$HOME/.claude/tools/bin"
'

# One-time, on the host: make that install directory load automatically every future session.
echo 'export PATH="$HOME/.claude/tools/bin:$PATH"' >> ~/.claude-pod/profile.sh
```

From then on, every run picks up `aws` on `PATH` automatically. Credentials still aren't forwarded by this — pass those per-run with [`ENV_PASSTHROUGH`](#forwarding-environment-variables), same as any other secret:

```sh
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=us-east-1 \
  ENV_PASSTHROUGH="AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION" \
  claude-pod claude --dangerously-skip-permissions
```

This only works for tools that install without root — the container still runs as an unprivileged, dynamic, `--cap-drop=ALL` user with no `sudo` (see [What it actually does](#what-it-actually-does)), so anything requiring `apt-get install` (a real system package, not a self-contained binary/installer like AWS CLI's) still has to go in the `Dockerfile` and be shared across every instance.

If you're running [multiple profiles](#multiple-accounts--profiles) (distinct `CLAUDE_POD_HOME` per profile), each gets its own `profile.sh` and installed tools automatically, since each has its own state dir.

## Security and limits

### What it actually does

The whole tool is four tiny files:

- **`Dockerfile`** — `node:24-slim` + `git` + `curl` + `less` + `jq` + `gh` + `unzip` + `@anthropic-ai/claude-code` (+ `happy-coder`, this fork's addition).
- **`claude-pod`** — one `docker run` command that mounts your current directory (plus small state dirs for Claude's and, if you use it, Happy's login and history), and — read-only, by default — a curated subset of your Claude Code skills, plugins, and global config.
- **`install.sh`** — checks Docker and builds the image. Doesn't touch any system path; the tool stays self-contained in this folder.
- **`uninstall.sh`** — removes the image and `~/.claude-pod/` (or `CLAUDE_POD_HOME` if set; auth + session history) after confirmation. Lists what it doesn't touch so you can clean those up yourself.

### What is and isn't isolated

**Safe from Claude:**
- Everything outside the project folder you launched from. `~/.ssh`, `~/.aws`, `~/.zshrc`, browser data, other projects — all unreachable.
- The host shell. No way to execute commands on your host machine.
- Your `~/.claude/.credentials.json`, `history.jsonl`, and `projects/` (session transcripts from every other project). Only a narrow, read-only subset of `~/.claude/` is mounted — see [Claude config access](#claude-config-access).

**Still exposed:**
- **The project folder itself.** Anything inside it — `.env`, `.git/config` (which can carry credentials for private remotes), private keys committed by mistake, `node_modules`, sibling worktrees, scratch files — is fully readable *and* writable by code running in the container. Don't run `claude-pod` from a folder whose contents you wouldn't trust the AI (or a malicious dependency it just installed) to see and modify.
- **The network.** Outbound is unrestricted by default. A malicious payload could exfiltrate the project contents or burn your Anthropic API quota. For offline work you can cut networking entirely with `NET=none` (see [Network isolation and resource limits](#network-isolation-and-resource-limits)), but that also takes Claude itself offline — there's no built-in egress allowlist that would keep Claude online while blocking everything else. Opting into `HOST_SERVICES=1` (see [Reaching host services](#reaching-host-services)) widens this further: the container can then also reach anything bound to your host's own loopback interface. `HOST_SERVICES="<ports>"` (the transparent-forwarding form) is narrower — only the named ports are reachable — but still opt-in for the same reason.
- **Your Anthropic login** (stored in `~/.claude-pod/` on the host, or `CLAUDE_POD_HOME` if set, separate from any host Claude install, shared across sandboxed projects using the same state dir).
- **Happy Coder's state**, if you use `happy` (see [Running Happy Coder](#running-happy-coder)) — stored in `~/.happy/` by default, which unlike `~/.claude-pod/` is shared with any host-side `happy` install unless you set `HAPPY_HOME_DIR` to a dedicated directory.

**Where Claude can actually write** — three paths, all intentional bind mounts:
- The project folder, bind-mounted at the same path inside the container (`$PWD:$PWD`). Edits land on your host's disk directly, no copy.
- `~/.claude-pod/` on the host (or `CLAUDE_POD_HOME` if set), mounted at `/home/claude-pod/.claude`. Holds the auth token and session history, plus anything you've put there yourself — e.g. a `profile.sh` init hook or tools it installs (see [Installing extra tools per-instance](#installing-extra-tools-per-instance)).
- `~/.happy/` on the host (or `HAPPY_HOME_DIR` if set), mounted at `/home/claude-pod/.happy`, when running via `happy` instead of `claude` directly.

> Because the current directory (`$PWD`) is mounted into the container, **avoid running this tool from directories like root (`/`) or `/etc` or other sensitive ones**. In such cases you are giving the AI access to your entire machine or to other sensitive data, defeating the purpose of the sandbox. Always `cd` into your specific project folder first.

Everywhere else Claude writes is either in the container's ephemeral filesystem (discarded on exit thanks to `--rm`) or simply has no path to land at — the Linux kernel's mount namespace makes any other host directory invisible to the container. Symlinks inside the project folder pointing to `~/.ssh` or `/etc/passwd` appear broken for the same reason: those targets aren't mounted, so the container can't see them.

> **Hardlinks are different.** A hardlink is a second name for an existing inode on the same filesystem. If a file inside your project folder is hardlinked to a sensitive file elsewhere on the same filesystem (e.g., `~/.ssh/id_rsa`), the container *can* reach it through the hardlink — the bind-mount exposes the inode, not just the path. This requires the hardlink to already exist in the project folder, so it's a real concern only when you're inspecting code from an untrusted source. Treat unfamiliar projects with the same caution you'd apply to running their code directly: don't run `claude-pod` inside a folder you don't trust.

The tradeoff: the worst case becomes "something bad happens to one project folder," which is recoverable from git, instead of "my entire home directory is exposed."

### Network isolation and resource limits

By default the container has **unrestricted outbound network** (Claude needs `api.anthropic.com`, your builds need npm/pip/etc.) and a generous process cap. When you're about to let Claude loose on code from an untrusted source, you can tighten things further with environment variables — all of them just add flags to the same `docker run`, nothing else changes:

```sh
# Cut ALL networking for the run. A malicious payload can't exfiltrate the project or phone home.
# Note: Claude itself can't reach Anthropic with no network, so this is for offline shell/build
# work (inspecting or building untrusted code), not for a live Claude session.
NET=none claude-pod

# Cap memory and CPU so a runaway or malicious build can't exhaust the host (recoverable via OOM,
# but disruptive). No default cap — a fixed limit would kill legitimate large builds.
MEMORY=4g CPUS=2 claude-pod

# Lower the process/thread cap when running untrusted code (default is 4096, generous for builds).
PIDS=512 claude-pod

# Let the container reach services bound to your host's loopback interface (e.g. a local Postgres
# your tests need). See "Reaching host services" above for details.
HOST_SERVICES=1 claude-pod

# Same, but transparently: proxy just these ports onto the container's own localhost so test
# config doesn't need to change between host and pod. See "Transparent port forwarding" above.
HOST_SERVICES="27017 8000" claude-pod
```

`NET=none` and `PORTS` are mutually exclusive — a container with no network can't publish ports. `NET=none` and `HOST_SERVICES` are also mutually exclusive — a no-network container can't resolve or reach the host either. `--pids-limit` is always applied (it contains fork bombs, which dropped capabilities do *not* prevent); raise `PIDS=` if a very parallel build hits the ceiling.

### Side effects outside the project folder

Everything this repo causes to exist outside the project you launch it from:

- `~/.claude-pod/` on your host (or `CLAUDE_POD_HOME` if set) — auth token, settings, and per-project session/conversation history (transcripts can include code snippets and command output Claude saw). Auth and settings are shared across projects using the same state dir (one login, ever, per state dir); session history lives under `<state dir>/projects/<encoded-host-path>/`, one folder per project, using the same encoding host-Claude uses — so if you ever switch to a host install, you can copy the folders over and keep your transcripts. This is *not* a host Claude install; it's a state directory for the container's Claude, kept on the host so it survives restarts. If you've set up a `profile.sh` init hook (see [Installing extra tools per-instance](#installing-extra-tools-per-instance)), whatever it installed also lives here.
- `~/.happy/` on your host (or `HAPPY_HOME_DIR` if set), created only if you run `happy` — see [Running Happy Coder](#running-happy-coder). Unlike `~/.claude-pod/`, this is Happy's *own* default state location (not a pod-specific fork of it), so it's shared with any host-side `happy` usage unless you override it.
- Docker image `claude-pod` and its layers, plus the `node:24-slim` base image, in Docker's image store.
- Docker build cache from `apt-get` and `npm install` steps.
- Outbound network during build: Docker Hub, Debian apt mirrors, npm registry. During runtime: `api.anthropic.com` and whatever your project code reaches (network is unrestricted).
- While a session is running: one container process, and any ports you explicitly mapped via `PORTS` bound on `127.0.0.1`.

No `sudo`, no writes to `/usr/local/`, `/etc/`, `~/.zshrc`, `~/Library/`, or anywhere else on the host. Your existing `~/.claude/` (skills, plugins, `CLAUDE.md`, `settings.json`, `statusline.sh` — or `CLAUDE_CONFIG_DIR` if set) and `~/.agents` are read from by default, but never written to — see [Claude config access](#claude-config-access). Your host's `~/.claude.json` (or `$CLAUDE_CONFIG_DIR/.claude.json`) is also read from by default (never written to), and the pod's own state dir's `.claude.json`'s `mcpServers` key is rewritten every run to match — see [MCP servers](#mcp-servers).

## Reference

### Platforms

The wrapper is portable POSIX bash + Docker. It should work on any host with a recent Docker:

- **macOS** (Apple Silicon and Intel) with Docker Desktop, OrbStack, or Colima — primary development target.
- **Linux** with Docker Engine or Docker Desktop — bind mounts and `--user` UID/GID map directly here, the most native experience.
- **Windows + WSL2** with Docker Desktop's WSL2 backend — run `claude-pod` from inside a WSL distribution's bash shell.

**Native Windows** (`cmd.exe` / PowerShell) is not supported. The wrapper is a bash script and uses POSIX tools (`id`, etc.); use WSL2 instead.

If a platform doesn't behave as expected, please open an issue.

### Uninstall

```sh
~/tools/claude-pod/uninstall.sh
```

Removes `~/.claude-pod/` and the `claude-pod` image after confirmation. Tells you exactly what it isn't touching (`node:24-slim`, build cache, this repo) and how to clean those up yourself.

If you're running [multiple profiles](#multiple-accounts--profiles), `uninstall.sh` also respects `CLAUDE_POD_HOME` — run it once per profile's state dir to remove each individually, e.g. `CLAUDE_POD_HOME=~/.claude-pod-tessero ~/tools/claude-pod/uninstall.sh`. The shared `claude-pod` image is only actually removed the first time (or when it's already gone) — later runs report "was not present" for that part.

If you added a shell alias for convenience (e.g. `alias claude-pod=...` in `~/.zshrc` / `~/.bashrc`), remove that line too — `uninstall.sh` doesn't touch your shell rc files.

`uninstall.sh` deliberately does **not** remove `~/.happy/` (or a custom `HAPPY_HOME_DIR`) — see [Running Happy Coder](#running-happy-coder) for why that dir isn't pod-exclusive the way `~/.claude-pod/` is. Remove it yourself if you used a dedicated directory for the pod and no longer need it.

### License and trademarks

The code in this repository is released under the MIT License — see [`LICENSE`](LICENSE) for the full text.

Claude Code itself is a separate product owned by Anthropic, PBC, and is **not** redistributed by this project — `install.sh` fetches it from npm at build time. This project is not affiliated with, endorsed by, or sponsored by Anthropic, PBC. "Claude" and "Claude Code" are trademarks of Anthropic, PBC, referenced here nominatively. No Anthropic logos, wordmarks, or other brand assets are used.
