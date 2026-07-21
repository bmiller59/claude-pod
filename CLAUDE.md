# claude-pod

This is Brendan's personal fork of `claude-pod` (originally trekhleb/claude-pod).

We try to keep it clean and general-purpose where that's easy, but it's ultimately built for Brendan's own workflow — features he uses all the time (e.g. `codegraph`) get baked into the default image rather than left as "customize it yourself" steps, even where the upstream/general-purpose version of this project might leave them out.

When a design decision could go either way (bake in vs. document as a customization), default to what's most useful for Brendan's actual day-to-day use of this tool, not to maximum generality for hypothetical other users.

## The sandbox's own CLAUDE.md

The `CLAUDE.md` a Claude session sees *inside* a running pod is not this file (that's this repo's own project instructions, which only apply when developing claude-pod itself). It's baked into the image at `/etc/claude-code/CLAUDE.md` via a heredoc in the `Dockerfile` (Claude Code's managed-policy path, loaded additively alongside the target project's own CLAUDE.md and the user's `~/.claude/CLAUDE.md`). Edit that heredoc, not this file or `~/.claude/CLAUDE.md`, when changing what every sandboxed session is told about claude-pod itself.
