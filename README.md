# kasm-agent-images

Docker images for [Kasm Workspaces](https://www.kasmweb.com/) virtual desktops used as steerable browser-agent VMs at Presentia AI.

The image is the **OS + applications** layer only — desktop environment, Chrome with DevTools Protocol enabled, Claude Code CLI, infrastructure helpers. Agent tooling (CLAUDE.md, memory, skills) lives in a separate repo, [`Presentia-AI/agent-workspace`](https://github.com/Presentia-AI/agent-workspace), and is git-cloned into each workspace on first shell. This separation lets agent behavior change in seconds via a PR-merge without rebuilding multi-GB images.

Companion docs: see `project_two_repo_architecture.md` in `agent-workspace/memory/`.

## What's in the image

Built from `kasmweb/ubuntu-jammy-desktop:1.17.0`. Adds:

- Node 20, git, jq, tmux, sudo (NOPASSWD for `kasm-user`)
- `gh` CLI (for the agent's session-branch + PR self-improvement loop)
- `@anthropic-ai/claude-code` and `chrome-devtools-mcp` (npm globals)
- Chrome wrapper at `/usr/local/bin/google-chrome` that forwards to the system binary with `--remote-debugging-port=9222 --remote-debugging-address=127.0.0.1`, so Claude Code can drive the browser via the chrome-devtools MCP. Both the taskbar `.desktop` launcher and the desktop-icon `.desktop` are patched to call the wrapper.
- Chrome managed policy that restores the previous session on launch (`/etc/opt/chrome/policies/managed/restore-tabs.json`).
- `/usr/local/bin/agent-ping` — Claude Code Notification hook that posts a ClickUp comment (deep-linked to the Kasm session) when the agent goes idle waiting for human input.
- `/usr/local/bin/presentia-gh-token` — git credential helper that reads the bind-mounted GitHub App installation token. Wired into `/etc/gitconfig` scoped to `https://github.com/Presentia-AI/agent-workspace`.
- `/etc/presentia-hooks.sh` (sourced from `/etc/bash.bashrc`) — on first interactive shell:
  - `__presentia_setup_gh_auth`: exports `GH_TOKEN` from `/etc/presentia/github-token` so `gh` is auto-authenticated as the App.
  - `__presentia_ensure_session`: fresh-clones `Presentia-AI/agent-workspace` into `~/agent/tooling`, creates a session-unique branch `agent/session-<UTC-ts>-<rand>` off `main`, pushes it up, then symlinks `~/agent/CLAUDE.md → tooling/general-purpose/CLAUDE.md` and shared `memory/`/`agent-skills/` into Claude Code's data dirs. If the token isn't mounted, writes `~/agent/GITHUB_APP_TOKEN_MISSING.md` and stops.
  - `__presentia_ensure_chrome_devtools_mcp`: registers `chrome-devtools` MCP in `~/.claude.json` if missing.
  - `__presentia_ensure_notification_hook`: registers `agent-ping` as the Notification hook in `~/.claude/settings.json`.
  - Auto-attaches tmux session `main`.

System-wide rc lives in `/etc/bash.bashrc` rather than `~/.bashrc`.

## Container lifecycle: ephemeral + branch-as-state

Containers are **non-persistent** (no `/home/kasm-user` bind-mount). Each Kasm session:

1. Spins up a fresh container from the image.
2. On first shell, clones `agent-workspace` and creates a unique branch `agent/session-<UTC-ts>-<rand>` off `main`, then pushes it up.
3. Agent commits + pushes to that branch as it works — the branch is the durable record.
4. When the agent has something worth promoting, it runs `gh pr create`. The App token has `Pull requests: write`.
5. Jorge reviews + merges → next session pulls it at clone time.
6. When the Kasm session is destroyed, the container goes away; the branch persists on the remote and is cleaned up by a host-side cron after 7d (if no merged PR).

This replaces the old persistent-profile + role-switching model — one image, one CLAUDE.md, state lives in git.

## Repo layout

Flat — one Dockerfile, supporting files alongside it. Single image type — no role distinction at the image layer.

```
.
├── Dockerfile
├── presentia-hooks.sh      # shell hooks sourced from /etc/bash.bashrc (in image)
├── presentia-gh-token      # in-container git credential helper (in image)
├── agent-ping              # ClickUp notification hook (in image)
├── claude-agent.desktop    # XFCE desktop launcher (in image)
├── presentia-mint-token    # HOST-side: mints GH App tokens via cron
├── kasm-sync-agent-image   # HOST-side: pulls GHCR image, updates Kasm DB hash
├── tg-send                 # legacy Telegram helper (kept, not COPYed)
└── .github/workflows/build.yml
```

## Tooling-repo auth: presentia-agent-tooling GitHub App

Agents auth to `Presentia-AI/agent-workspace` via the **presentia-agent-tooling** GitHub App (App ID 3845322, install 135293445), scoped to that one repo with `Contents: write` + `Pull requests: write` (so the agent can push to its own session branch and open PRs against `main`). Deploy keys are blocked at the enterprise level so they're not an option.

- **Private key** lives ONLY on the Kasm host at `/etc/presentia/github-app.pem` (root:root 600). It never enters any container.
- **Host minter** `/usr/local/bin/presentia-mint-token` runs every 50 min via `/etc/cron.d/presentia-mint-token`, exchanges a JWT for a 1-hour installation token, writes it to `/var/lib/kasm-secrets/agent-creds/github-token` (uid 1000, mode 600).
- **Per-workspace bind-mount** (configured in Kasm DB `images.volume_mappings`) maps `/var/lib/kasm-secrets/agent-creds` → `/etc/presentia` (ro) into each agent container. Kasm's volume helper can only bind-mount directories, not individual files — hence the subdir.
- **In-container credential helper** `/usr/local/bin/presentia-gh-token` reads `/etc/presentia/github-token` and emits `username=x-access-token\npassword=<token>` on `get`. Scoped via `/etc/gitconfig` to the agent-workspace HTTPS URL (both `.git` and non-`.git` forms — see Dockerfile for why).
- **gh CLI** reads `GH_TOKEN`, set by the shell hook from the same token file.

Token rotation is automatic; if a workspace boots and the token file is missing, the hook writes `~/agent/GITHUB_APP_TOKEN_MISSING.md` instead of silently failing.

## Known TODOs

- **Tailscale on kasm-01** to eliminate firewall IP whack-a-mole when working from new networks.

## Building locally

```
docker build --load --provenance=false -t kasm-agent:test .
```

The `--load --provenance=false` flags are mandatory — without them, buildx produces a manifest list with attestations that dockerd's image store silently fails to load (image shows up in build logs but not in `docker images`).
