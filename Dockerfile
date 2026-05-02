# If you bump this tag, also update the literal in uninstall.sh.
FROM node:24-slim

# git/curl/less are baseline dev tools; jq and gh are reached for by Claude's built-in workflows
# (JSON pipelines and the GitHub CLI for PRs/issues/releases). ca-certificates is needed for HTTPS.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates curl less jq gh \
 && rm -rf /var/lib/apt/lists/*

# CACHEBUST is passed from install.sh as the current timestamp.
# This invalidates the cache from this line onward, forcing Docker to always
# fetch the latest version of claude-code without rebuilding the slow apt-get layer.
ARG CACHEBUST=1
RUN npm install -g @anthropic-ai/claude-code

# We DO NOT use `USER node` here. Instead, we pass `--user "$(id -u):$(id -g)"` dynamically
# at runtime in the `claude-pod` script. This ensures perfect file permission alignment
# between the host and the container, especially on Linux environments.
# Create a dedicated, globally writable home directory for our dynamic runtime user.
RUN mkdir -p /home/claude-pod && chmod 777 /home/claude-pod

# Override the default bash prompt to hide the "I have no name!" warning for dynamic users.
RUN echo 'PS1="claude-pod:\w\$ "' >> /etc/bash.bashrc

CMD ["bash"]
