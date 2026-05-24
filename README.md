# kasm-agent-images

Docker images for [Kasm Workspaces](https://www.kasmweb.com/) virtual desktops used as steerable browser-agent VMs at Presentia AI.

The image is the **OS + applications** layer only — desktop environment, Chrome with DevTools Protocol enabled, Claude Code CLI, infrastructure helpers. Role-scoped AI tooling (CLAUDE.md, autonomous loop prompts, memory, skills) lives in a separate repo, [`Presentia-AI/agent-workspace`](https://github.com/Presentia-AI/agent-workspace), and is git-cloned into each workspace on first shell. This separation lets agent behavior change in seconds via `git pull` without rebuilding multi-GB images.

Companion docs: see `project_two_repo_architecture.md` in `agent-workspace/memory/`.

## What's in the image

Built from `kasmweb/ubuntu-jammy-desktop:1.17.0`. Adds:

- Node 20, git, jq, tmux, sudo (NOPASSWD for `kasm-user`)
- `@anthropic-ai/claude-code` and `chrome-devtools-mcp` (npm globals)
- Chrome wrapper at `/usr/local/bin/google-chrome` that forwards to the system binary with `--remote-debugging-port=9222 --remote-debugging-address=127.0.0.1`, so Claude Code can drive the browser via the chrome-devtools MCP. Both the taskbar `.desktop` launcher and the desktop-icon `.desktop` are patched to call the wrapper.
- Chrome managed policy that restores the previous session on launch (`/etc/opt/chrome/policies/managed/restore-tabs.json`).
- `/usr/local/bin/agent-ping` — Claude Code Notification hook that posts a ClickUp comment (deep-linked to the Kasm session) when the agent goes idle waiting for human input.
- `/usr/local/bin/presentia-gh-token` — git credential helper that reads the bind-mounted GitHub App installation token. Wired into `/etc/gitconfig` scoped to `https://github.com/Presentia-AI/agent-workspace`.
- `/etc/presentia-hooks.sh` (sourced from `/etc/bash.bashrc`) — on first interactive shell:
  - `__presentia_ensure_tooling`: clones `Presentia-AI/agent-workspace` over HTTPS into `~/agent/tooling` (auth via the bind-mounted installation token at `/etc/presentia/github-token`), symlinks role files (`~/agent/CLAUDE.md → tooling/$KASM_ROLE_LABEL/CLAUDE.md`) and shared `memory/`/`agent-skills/` into Claude Code's data dirs. If the token isn't mounted, writes `~/agent/GITHUB_APP_TOKEN_MISSING.md` and stops.
  - `__presentia_ensure_chrome_devtools_mcp`: registers `chrome-devtools` MCP in `~/.claude.json` if missing.
  - `__presentia_ensure_notification_hook`: registers `agent-ping` as the Notification hook in `~/.claude/settings.json`.
  - `__presentia_fix_chrome_desktop_icon`: patches stale desktop launchers in persistent profiles that still point at the un-wrapped Chrome.
  - Auto-attaches tmux session `main`.

System-wide rc lives in `/etc/bash.bashrc` (sourcing `/etc/presentia-hooks.sh`) rather than `~/.bashrc` because Kasm bind-mounts `/home/kasm-user/`, which overlays anything baked into the user home.

## Repo layout

Flat — one Dockerfile, supporting files alongside it. We have one image type (role is selected at session creation via `KASM_ROLE_LABEL` env), so no need for per-image subdirs.

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

Agents auth to `Presentia-AI/agent-workspace` via the **presentia-agent-tooling** GitHub App (App ID 3845322, install 135293445), scoped to that one repo with Contents:write. Deploy keys are blocked at the enterprise level so they're not an option.

- **Private key** lives ONLY on the Kasm host at `/etc/presentia/github-app.pem` (root:root 600). It never enters any container.
- **Host minter** `/usr/local/bin/presentia-mint-token` runs every 50 min via `/etc/cron.d/presentia-mint-token`, exchanges a JWT for a 1-hour installation token, writes it to `/var/lib/kasm-secrets/github-token` (uid 1000, mode 600).
- **Per-workspace bind-mount** (configured in Kasm DB `images.volume_mappings`) maps `/var/lib/kasm-secrets/github-token` → `/etc/presentia/github-token` (ro) into each agent container.
- **In-container credential helper** `/usr/local/bin/presentia-gh-token` reads that file and emits `username=x-access-token\npassword=<token>` on `get`. Scoped via `/etc/gitconfig` to the agent-workspace HTTPS URL only.

Token rotation is automatic; if a workspace boots and the token file is missing, the hook writes `~/agent/GITHUB_APP_TOKEN_MISSING.md` instead of silently failing.

## Known TODOs

- **Tailscale on kasm-01** to eliminate firewall IP whack-a-mole when working from new networks.

## Building locally

```
docker build --load --provenance=false -t presentia-agent-general:test .
```

The `--load --provenance=false` flags are mandatory — without them, buildx produces a manifest list with attestations that dockerd's image store silently fails to load (image shows up in build logs but not in `docker images`).
