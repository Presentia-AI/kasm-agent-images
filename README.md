# kasm-agent-images

Docker images for [Kasm Workspaces](https://www.kasmweb.com/) virtual desktops used as steerable browser-agent VMs at Presentia AI.

The image is the **OS + applications** layer only — desktop environment, Chrome with DevTools Protocol enabled, Claude Code CLI, infrastructure helpers. Role-scoped AI tooling (CLAUDE.md, autonomous loop prompts, memory, skills) lives in a separate repo, [`Presentia-AI/agent-workspace`](https://github.com/Presentia-AI/agent-workspace), and is git-cloned into each workspace on first shell. This separation lets agent behavior change in seconds via `git pull` without rebuilding multi-GB images.

Companion docs: see `project_two_repo_architecture.md` in `agent-workspace/memory/`.

## What's in the image

Built from `kasmweb/ubuntu-jammy-desktop:1.17.0`. Adds:

- Node 20, git, jq, tmux, sudo (NOPASSWD for `kasm-user`), openssh-client
- `@anthropic-ai/claude-code` and `chrome-devtools-mcp` (npm globals)
- Chrome wrapper at `/usr/local/bin/google-chrome` that forwards to the system binary with `--remote-debugging-port=9222 --remote-debugging-address=127.0.0.1`, so Claude Code can drive the browser via the chrome-devtools MCP. Both the taskbar `.desktop` launcher and the desktop-icon `.desktop` are patched to call the wrapper.
- Chrome managed policy that restores the previous session on launch (`/etc/opt/chrome/policies/managed/restore-tabs.json`).
- `/usr/local/bin/agent-ping` — Claude Code Notification hook that posts a ClickUp comment (deep-linked to the Kasm session) when the agent goes idle waiting for human input.
- `/etc/presentia-hooks.sh` (sourced from `/etc/bash.bashrc`) — on first interactive shell:
  - `__presentia_ensure_tooling`: generates a per-workspace SSH deploy key, clones `Presentia-AI/agent-workspace` into `~/agent/tooling`, symlinks role files (`~/agent/CLAUDE.md → tooling/$KASM_ROLE_LABEL/CLAUDE.md`) and shared `memory/`/`agent-skills/` into Claude Code's data dirs. If the deploy key isn't registered yet, writes `~/agent/DEPLOY_KEY_TO_REGISTER.md` with instructions and the public key.
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
├── presentia-hooks.sh      # shell hooks sourced from /etc/bash.bashrc
├── agent-ping              # ClickUp notification hook
├── claude-agent.desktop    # XFCE desktop launcher
├── tg-send                 # legacy Telegram helper (kept, not COPYed)
└── .github/workflows/build.yml
```

## First-time tooling auth (per workspace)

On first interactive shell, `__presentia_ensure_tooling` generates `~/.ssh/id_ed25519`. The clone of `Presentia-AI/agent-workspace` will fail until the public key is registered as a deploy key on that repo. The hook writes `~/agent/DEPLOY_KEY_TO_REGISTER.md` in the workspace with the pubkey and a registration link. After registering (tick "Allow write access"), opening a new terminal retries automatically.

This is per-workspace because the SSH key lives in the persistent profile, which is per-session in Kasm. Migrate to a GitHub App when we have more than ~3 long-lived roles.

## Known TODOs

- **GH Action does not push.** Currently builds for validation only. Wire up GHCR push + a kasm-01 pull/DB-update step.
- **Tailscale on kasm-01** to eliminate firewall IP whack-a-mole when working from new networks.

## Building locally

```
docker build --load --provenance=false -t presentia-agent-general:test .
```

The `--load --provenance=false` flags are mandatory — without them, buildx produces a manifest list with attestations that dockerd's image store silently fails to load (image shows up in build logs but not in `docker images`).
