# If you bump this tag, also update the literal in uninstall.sh.
FROM node:24-slim

# git/curl/less are baseline dev tools; jq and gh are reached for by Claude's built-in workflows
# (JSON pipelines and the GitHub CLI for PRs/issues/releases). ca-certificates is needed for HTTPS.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates curl less jq gh \
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

# We DO NOT use `USER node` here. Instead, we pass `--user "$(id -u):$(id -g)"` dynamically
# at runtime in the `claude-pod` script. This ensures perfect file permission alignment
# between the host and the container, especially on Linux environments.
# Create a dedicated, globally writable home directory for our dynamic runtime user.
RUN mkdir -p /home/claude-pod && chmod 777 /home/claude-pod

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
EOF

CMD ["bash"]
