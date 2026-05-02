# claude-pod — Pre-release Plan

Action items from the code review, organized by priority. Work through them one by one; check off as we go.

---

## Critical / must-fix before public release

- [x] **1. Fix outdated LICENSE claim in README**
  - File: `README.md:185`
  - Problem: README says "add a LICENSE file with the standard MIT text — none ships with the repo by default", but `LICENSE` already exists.
  - Fix: Rewrite that paragraph to state the project is MIT-licensed and point to `LICENSE`.

- [x] **2. Fix base-image name in `uninstall.sh`**
  - File: `uninstall.sh:23`
  - Problem: Says `node:lts-slim`, but `Dockerfile:1` uses `node:24-slim`. Users following the hint won't actually remove the leftover base image.
  - Fix: Change `node:lts-slim` → `node:24-slim` in both the message and the `docker rmi` example.

- [x] **3. Rephrase misleading "network is fully isolated" line**
  - File: `README.md:62`
  - Problem: Contradicts the Side Effects + threat-model sections (outbound is unrestricted).
  - Fix: Replace with something like *"By default, no container ports are published to the host. Outbound traffic is unrestricted (see 'What is and isn't isolated' below)."*

- [x] **4. Allow pinning the Claude Code version**
  - Files: `Dockerfile`, `install.sh`
  - Problem: `npm install -g @anthropic-ai/claude-code` always grabs `latest` (with `CACHEBUST=$(date +%s)`), so two installs minutes apart can differ. No reproducibility, no escape if a bad release ships.
  - Fix:
    - Add `ARG CLAUDE_CODE_VERSION=latest` to `Dockerfile`.
    - Use `npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}`.
    - Pass through from `install.sh` (`--build-arg CLAUDE_CODE_VERSION=...`), default `latest`.
    - At end of `install.sh`, print the resolved version: `docker run --rm claude-pod claude --version`.
    - Decide whether to keep `CACHEBUST` when version is pinned (probably skip — pinned installs should cache).

---

## Security

- [x] **5. Add container hardening flags**
  - File: `claude-pod` (the docker run command)
  - Add: `--cap-drop=ALL --security-opt=no-new-privileges`
  - Rationale: Interactive dev shell doesn't need any Linux capabilities; cheap, materially shrinks attack surface.
  - Optional follow-ups (decide separately):
    - Resource caps: `--pids-limit=2048 --memory=8g --cpus=4`
    - `--read-only` rootfs with `--tmpfs` for `/tmp` and `~/.cache` (may break some tooling — opt-in).

- [ ] **6. Document hardlink limitation (or stay silent)**
  - File: `README.md` (around the "Symlinks ... appear broken" paragraph)
  - Problem: Symlink reassurance implies hardlinks are also blocked; they aren't (hardlinks resolve through inode, same-filesystem files in project are reachable).
  - Fix: Either add an explicit hardlink note, or remove the symlink reassurance entirely. Don't half-cover it.

- [ ] **7. Add `SECURITY.md`**
  - New file: `SECURITY.md`
  - Contents (mostly extracted from existing README sections):
    - Where to report vulnerabilities (private email or GitHub Security Advisories).
    - Threat model (sandbox boundaries — what's protected, what isn't).
    - Explicit non-goals (does NOT protect against malicious project folder, network exfiltration, compromised auth token, etc.).

- [ ] **8. Validate `PORTS` input**
  - File: `claude-pod:48-56`
  - Problem: Junk values silently produce confusing Docker errors.
  - Fix: Validate each entry against `^[0-9]+(:[0-9]+)?$`, fail fast with a friendly message (e.g. `PORTS entry "abc" is invalid; expected "PORT" or "HOST:CONTAINER"`).

- [ ] **9. Tighten permissions on `~/.claude-pod/`**
  - File: `claude-pod` (after the `mkdir -p`/seed lines)
  - Add: `chmod 700 "$HOME/.claude-pod"` and `chmod 600 "$HOME/.claude-pod/.claude.json"` (only if not already restrictive).
  - Rationale: Protects auth token on multi-user machines; cheap defense in depth.

- [ ] **10. Strengthen the "project folder is exposed" warning**
  - File: `README.md` ("Still exposed" section)
  - Problem: Casual readers skim past `.env`. Be concrete.
  - Fix: Concrete examples — `.env`, `.git/config` (may carry credentials), private keys committed by mistake, sibling worktrees. Add: *"Don't run `claude-pod` from a folder you don't trust."*

---

## Code quality / smells

- [ ] **11. (Deferred) Factor duplicated ANSI color preamble**
  - Files: `install.sh`, `uninstall.sh`, `claude-pod`
  - Acceptable at 3 files; revisit if the project grows.

- [ ] **12. Add shellcheck + hadolint to CI**
  - New file: `.github/workflows/lint.yml`
  - Run shellcheck on `install.sh`, `uninstall.sh`, `claude-pod`.
  - Run hadolint on `Dockerfile`.
  - Address any warnings surfaced (likely a few `SC2086`/`SC2155`).

- [ ] **13. Add `.dockerignore`**
  - New file: `.dockerignore`
  - Contents: `.git`, `*.md`, `LICENSE`, `claude-pod`, `install.sh`, `uninstall.sh`, `PLAN.md` — anything that doesn't need to be in the build context.
  - Note: there's currently a stray untracked `.dockerignore` flagged in `git status`; reconcile with that.

- [ ] **14. Mirror Docker-daemon liveness check in `claude-pod`**
  - File: `claude-pod`
  - Problem: Only image existence is checked; raw Docker error if daemon is stopped.
  - Fix: Add `docker info >/dev/null 2>&1 || die "Docker daemon is not running."` (same pattern as `install.sh:18`).

- [ ] **15. Decide on `--help`/`--version` behavior**
  - File: `claude-pod`
  - Problem: Currently `claude-pod --help` runs `bash --help` inside the container — surprising.
  - Fix: Either intercept those flags at the wrapper level, or document the passthrough explicitly. Probably the former.

- [ ] **16. Resolve the stray untracked `.dockerignore`**
  - Output of `git status` shows `?? .dockerignore`.
  - Either commit (after #13 populates it) or delete.

---

## Industry standards / project hygiene

- [ ] **17. Add `.gitignore`**
  - Currently missing entirely. At minimum: editor swap files, OS artifacts (`.DS_Store`).

- [ ] **18. Add `CONTRIBUTING.md`**
  - Sets expectations: shellcheck-clean, single-purpose PRs, how to test changes locally.

- [ ] **19. Add `CHANGELOG.md`**
  - Helps users notice when image rebuild is needed.
  - Start with `## [Unreleased]` and a `v0.1.0` entry once #1–#10 are done.

- [ ] **20. Add `.editorconfig`**
  - Cheap consistency for shell tabs/spaces.

- [ ] **21. Add GitHub issue templates**
  - Bug report should ask for: `docker --version`, host OS + arch, project size, exact command, full error.

- [ ] **22. Cut a `v0.1.0` git tag + GitHub Release**
  - After items #1–#10 land. Gives early adopters a stable reference.

---

## Documentation polish

- [ ] **23. Add a TL;DR at the top of README**
  - Three lines: clone, install, run. Skimmer-friendly.

- [ ] **24. State supported platforms**
  - Linux, macOS (Apple Silicon + Intel), Windows+WSL2 — list what's tested.
  - Note macOS bind-mount performance for large projects (especially `node_modules`).

- [ ] **25. Replace `<this repo>` placeholder**
  - File: `README.md:25`
  - Use the actual GitHub URL before announcing.

- [ ] **26. Promote the first-launch login flow to its own subsection**
  - Currently buried in `## Notes`. It's what every new user hits first.

- [ ] **27. Add uninstall reminder for shell aliases**
  - File: `README.md` (uninstall section) or `uninstall.sh` output.
  - Remind users to remove `alias claude-pod=...` from their shell rc file.

- [ ] **28. (Optional) Asciinema or short screencast**
  - Strongly increases conversion for CLI tools. Skip if low-effort isn't possible.

---

## Legal

- [ ] **29. Confirm copyright name**
  - File: `LICENSE:3`
  - Currently `Oleksii Trekhleb`. Confirm this is the intended public attribution.

- [ ] **30. Add `THIRD_PARTY_NOTICES.md`**
  - Image embeds Debian packages (`git`, `curl`, `less`, `jq`, `gh`) + Node.js runtime under various licenses.
  - Not strictly required (you're not distributing the image binary), but good practice and 5 minutes of work.

---

## Open questions to resolve before doing the work

These were asked during review; flagging them here so we don't lose them:

- [ ] **Q1.** Target platforms — Linux / macOS (both archs) / Windows+WSL2 — which are tested?
- [ ] **Q2.** Audience — security-cautious devs vs. hobbyists? Affects how strict the defaults are.
- [ ] **Q3.** Distribution channel — GitHub-only, or also Homebrew / AUR / scoop?
- [ ] **Q4.** Versioning — will you cut tagged releases? Affects whether `CACHEBUST=$(date +%s)` should remain the default vs. pinning.
- [ ] **Q5.** "Always latest Claude Code" — feature or bug? My recommendation: feature, with opt-out via `CLAUDE_CODE_VERSION`.
