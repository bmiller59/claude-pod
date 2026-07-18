# If you bump this tag, also update the literal in uninstall.sh.
FROM node:24-slim

# git/curl/less are baseline dev tools; jq and gh are reached for by Claude's built-in workflows
# (JSON pipelines and the GitHub CLI for PRs/issues/releases). ca-certificates is needed for HTTPS.
# socat backs the HOST_SERVICES port-forwarding entrypoint below.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates curl less jq gh socat \
 && rm -rf /var/lib/apt/lists/*

# Override at build time with --build-arg CLAUDE_CODE_VERSION=2.x.y to pin a specific
# version. Default "latest" tracks whatever's current on npm.
ARG CLAUDE_CODE_VERSION=latest

# When CLAUDE_CODE_VERSION=latest, install.sh passes CACHEBUST=$(date +%s) to force a fresh
# refetch (the literal "latest" alone wouldn't change the layer's cache key). For pinned
# versions, the version literal itself is the cache key, so install.sh skips CACHEBUST and
# this layer caches normally.
ARG CACHEBUST=1
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# codegraph: this is a personal fork (see CLAUDE.md) baked in because we use it constantly via the
# MCP_SERVERS whitelist in the claude-pod script. Not a general-purpose default for other forks.
RUN npm install -g @colbymchenry/codegraph

# Happy Coder CLI (https://happy.engineering, https://github.com/slopus/happy-cli): an optional
# wrapper around `claude` that adds mobile/web session pairing. Installs the `happy` binary.
# Invoked as `claude-pod happy --claude-arg <arg>` instead of `claude-pod claude <arg>` -- see the
# claude-pod script's HAPPY_HOME_DIR handling for its state dir.
RUN npm install -g happy-coder

# We DO NOT use `USER node` here. Instead, we pass `--user "$(id -u):$(id -g)"` dynamically
# at runtime in the `claude-pod` script. This ensures perfect file permission alignment
# between the host and the container, especially on Linux environments.
# Create a dedicated, globally writable home directory for our dynamic runtime user.
RUN mkdir -p /home/claude-pod && chmod 777 /home/claude-pod

# nvm, installed under the dynamic user's home dir so it's writable at runtime (the container
# always runs with HOME=/home/claude-pod, set by the `claude-pod` script, regardless of which
# host uid/gid is mapped in). PROFILE=/dev/null stops the installer from appending its loader
# line to a build-time root shell rc that the runtime user will never read -- we add that line
# ourselves to /etc/bash.bashrc below instead, next to the rest of the interactive-shell setup.
# chmod -R 777 mirrors the home dir above: the runtime user has no fixed uid/gid, so nvm's own
# files (installed here as root) need to be world-writable for `nvm install <version>` to work.
RUN export NVM_DIR=/home/claude-pod/.nvm \
 && mkdir -p "$NVM_DIR" \
 && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.6/install.sh | PROFILE=/dev/null bash \
 && chmod -R 777 "$NVM_DIR"

# Interactive-shell setup, appended to /etc/bash.bashrc. Only interactive bash sources this file, so
# none of it touches the non-interactive `claude-pod claude ...` path. The dynamic, /etc/passwd-less
# user has no $HOME/.bashrc of its own, so these baseline conveniences have to live in the system-wide
# rc. Heredoc keeps the escapes readable (BuildKit, which install.sh already requires via
# --progress=plain, supports it).
RUN cat >> /etc/bash.bashrc <<'EOF'

# Colored prompt: green label, blue path — the conventional Debian default look. \[...\] wraps the
# non-printing escapes so bash measures the prompt width correctly. The "claude-pod" label also
# hides the "I have no name!" warning a dynamic, passwd-less user would otherwise show.
PS1='\[\e[1;32m\]claude-pod\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

# Basic, conventional coloring for the most-used commands. dircolors supplies the standard LS_COLORS
# palette; the aliases enable color only when output is a terminal (so piped output stays clean).
if command -v dircolors >/dev/null 2>&1; then eval "$(dircolors -b)"; fi
alias ls='ls --color=auto'
alias grep='grep --color=auto'

# nvm's standard loader snippet (nvm itself is installed above, under $HOME/.nvm).
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
EOF

# Managed-policy CLAUDE.md: Claude Code loads a fixed system path (this one, on Linux) before the
# user's own ~/.claude/CLAUDE.md and any project CLAUDE.md, and concatenates rather than overrides --
# so this applies additively to every project run in the pod, without editing anyone's host CLAUDE.md
# (which is bind-mounted read-only from the host, so we couldn't safely rewrite it here anyway) and
# without depending on a project remembering to @import it. It also can't be excluded the way a
# project/user CLAUDE.md can via claudeMdExcludes.
RUN mkdir -p /etc/claude-code && cat > /etc/claude-code/CLAUDE.md <<'EOF'
# claude-pod sandbox

Every Claude Code session inside a `claude-pod` container loads this file from
`/etc/claude-code/CLAUDE.md` (Claude Code's managed-policy location) in addition to
the project's own CLAUDE.md and the user's `~/.claude/CLAUDE.md` -- it doesn't replace
either.

## Check access before starting
Before starting a task, think about what it will need -- network access, a specific
MCP server, a host service, elevated resource limits, git push access -- and whether
this sandbox has it (see the sections below for what's available and what isn't). If
something's missing, say so up front and tell the user what to set (`MCP_SERVERS`,
`HOST_SERVICES`, etc.) or that it isn't possible here, instead of starting the work
and hitting the gap partway through.

## No git/GitHub push credentials
No SSH keys, git credential helper, or `gh` auth token are mounted into the container.
`git push` and any `gh` command needing authentication (`gh pr create`, `gh issue
comment`, etc.) will fail here. Don't attempt them -- tell the user what to run and
let them do it from the host.

## Never rewrite git branches
NEVER rewrite a git branch in this sandbox -- no `push --force`/`--force-with-lease`,
`rebase`, `commit --amend`, `reset --hard`, or `branch -D`. The project directory is
the host's real working tree, not a copy, so a rewrite here mutates the host's actual
repo state, not a disposable sandbox one. If a rewrite is genuinely needed, tell the
user exactly what to run and let them do it themselves.

## Tools baked into the image
- git, curl, less, jq, gh, socat, node/npm -- all on PATH already.
- nvm is installed at `$NVM_DIR` (`$HOME/.nvm`) to switch Node versions. It's loaded
  automatically in interactive bash shells; in a non-interactive `claude-pod claude ...`
  run, source it first: `. "$NVM_DIR/nvm.sh" && nvm use <version>`.
- The codegraph MCP server is available by default (see `MCP_SERVERS` in the
  `claude-pod` script) when a project has a `.codegraph/` index.
- `happy` (Happy Coder CLI) is available as an alternative way to start a session --
  `happy --claude-arg <arg>` instead of `claude <arg>` -- for mobile/web session pairing.

## Isolation
Only the project directory the pod was launched from (mounted at the same path as
the host) and the pod's own `~/.claude` and `~/.happy` state are visible. Other host
paths and other projects are not reachable. If the run was started with `NET=none`,
there is no network at all -- not even to api.anthropic.com -- so that mode is for
offline shell/build work, not a live Claude session.
EOF

# Entrypoint: proxies named host ports onto the container's own loopback before running the real
# command, so `claude-pod`'s HOST_SERVICES=<ports> option (see the `claude-pod` script) lets test
# config keep pointing at `localhost:<port>` unchanged whether running in the pod or not, instead
# of requiring `host.docker.internal:<port>` inside the sandbox. HOST_FORWARD_PORTS is set by that
# script via `-e`, never by the user directly. Backgrounded (&) then exec'd past: exec replaces this
# script's own process image, but the socat children it already forked stay alive as children of
# whatever ends up as PID 1.
RUN cat > /usr/local/bin/claude-pod-entrypoint.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${HOST_FORWARD_PORTS:-}" ]; then
  for port in $HOST_FORWARD_PORTS; do
    socat TCP-LISTEN:"$port",bind=127.0.0.1,fork,reuseaddr TCP:host.docker.internal:"$port" &
  done
fi

exec "$@"
EOF
RUN chmod 755 /usr/local/bin/claude-pod-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/claude-pod-entrypoint.sh"]
CMD ["bash"]
