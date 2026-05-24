# kasm-agent-images

Docker images for [Kasm Workspaces](https://www.kasmweb.com/) virtual desktops used as steerable browser-agent VMs at Presentia AI.

The image is the **OS + applications** layer only — desktop environment, Chrome with DevTools Protocol enabled, Claude Code CLI, infrastructure helpers. Role-scoped AI tooling (CLAUDE.md, autonomous loop prompts, memory, skills) lives in a separate repo, [`Presentia-AI/agent-workspace`](https://github.com/Presentia-AI/agent-workspace), and is git-cloned into each workspace at boot. This separation lets agent behavior change in seconds via `git pull` without rebuilding multi-GB images.

Companion docs: see `project_two_repo_architecture.md` in `agent-workspace/memory/`.

## What's in the image

Built from `kasmweb/ubuntu-jammy-desktop:1.17.0`. Adds:

- Node 20, git, jq, tmux, sudo (NOPASSWD for `kasm-user`)
- `@anthropic-ai/claude-code` and `chrome-devtools-mcp` (npm globals)
- Chrome wrapper at `/usr/local/bin/google-chrome` that forwards to the system binary with `--remote-debugging-port=9222 --remote-debugging-address=127.0.0.1`, so Claude Code can drive the browser via the chrome-devtools MCP. Both the taskbar `.desktop` launcher and the desktop-icon `.desktop` are patched to call the wrapper.
- Chrome managed policy that restores the previous session on launch (`/etc/opt/chrome/policies/managed/restore-tabs.json`).
- `/usr/local/bin/agent-ping` — Claude Code Notification hook that posts a ClickUp comment (deep-linked to the Kasm session) when the agent goes idle waiting for human input.
- `/etc/bash.bashrc` hooks that, on first interactive shell:
  - Register `chrome-devtools` MCP in `~/.claude.json` if missing
  - Register `agent-ping` as the Notification hook in `~/.claude/settings.json`
  - Fix the desktop icon's launcher if a persistent profile still points at the un-wrapped Chrome
  - Auto-attach tmux session `main`

System-wide rc files live in `/etc/bash.bashrc` rather than `~/.bashrc` because Kasm bind-mounts `/home/kasm-user/`, which overlays anything baked into the user home.

## Repo layout

Flat — one Dockerfile, supporting files alongside it. We have one image type (role is selected at session creation via `KASM_ROLE_LABEL` env), so no need for per-image subdirs.

```
.
├── Dockerfile
├── agent-ping              # ClickUp notification hook
├── claude-agent.desktop    # XFCE desktop launcher
├── tg-send                 # legacy Telegram helper (kept, not COPYed)
├── CLAUDE.md               # baked role doc — TODO: remove, fetch from agent-workspace at build time
└── .github/workflows/build.yml
```

## Known TODOs

- **`CLAUDE.md` is duplicated** with `agent-workspace/general-purpose/CLAUDE.md`. The Dockerfile bakes it in (`COPY CLAUDE.md ...`). Next iteration: fetch from `agent-workspace` at build time, drop the local copy.
- **GH Action does not push.** Currently builds for validation only. Wire up GHCR push + a kasm-01 pull/DB-update step once the deploy-key/sync mechanism is in place.
- **First-run tooling clone hook** is not yet in the Dockerfile. The image still bakes CLAUDE.md instead of cloning the tooling repo at boot. Add `__presentia_ensure_tooling` to `/etc/bash.bashrc`.

## Building locally

```
docker build --load --provenance=false -t presentia-agent-general:test .
```

The `--load --provenance=false` flags are mandatory — without them, buildx produces a manifest list with attestations that dockerd's image store silently fails to load (image shows up in build logs but not in `docker images`).
