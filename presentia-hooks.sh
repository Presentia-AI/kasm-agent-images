# shellcheck shell=bash
# Presentia agent shell hooks. COPYed to /etc/presentia-hooks.sh by the image
# build and sourced from /etc/bash.bashrc. Lives here (not inlined in the
# Dockerfile) so it's diff-able, lint-able, and testable in isolation.
#
# Loaded for every shell on the image; the heavy interactive setup is gated on
# $PS1 at the bottom.

# Make the GitHub App installation token available to gh CLI for the rest of
# the session. The token file is bind-mounted from the host (refreshed by cron
# every 50 min) and read by /usr/local/bin/presentia-gh-token for git too.
__presentia_setup_gh_auth() {
  local token_file="/etc/presentia/github-token"
  if [ -r "$token_file" ]; then
    export GH_TOKEN="$(cat "$token_file")"
  fi
}

# Ensure chrome-devtools MCP is registered in this user's Claude Code config.
#
# Uses `--browserUrl` to attach to an externally-managed Chrome on
# 127.0.0.1:9222 rather than letting the MCP spawn and own its own browser.
# That decoupling matters: when the MCP owns Chrome, any agent that pkill's
# Chrome (e.g. trying to fix a port issue) leaves the MCP holding a dead
# browser handle that returns `Target closed` on every subsequent call —
# unrecoverable for the rest of the Claude Code session. In attach mode the
# MCP just reconnects on the next call once Chrome is back up.
#
# Companion: __presentia_ensure_chrome_running keeps a Chrome on :9222.
__presentia_ensure_chrome_devtools_mcp() {
  local cfg="$HOME/.claude.json"
  command -v jq >/dev/null || return 0
  [ -f "$cfg" ] || echo '{}' > "$cfg"
  # No-op if the entry is already in the target shape (idempotent across shells).
  if jq -e '.mcpServers["chrome-devtools"] == {"type":"stdio","command":"chrome-devtools-mcp","args":["--browserUrl","http://127.0.0.1:9222"]}' "$cfg" >/dev/null 2>&1; then
    return 0
  fi
  local tmp
  tmp=$(mktemp) || return 1
  jq '.mcpServers["chrome-devtools"] = {"type":"stdio","command":"chrome-devtools-mcp","args":["--browserUrl","http://127.0.0.1:9222"]}' "$cfg" > "$tmp" \
    && mv "$tmp" "$cfg"
}

# Ensure Chrome is running with the DevTools Protocol on 127.0.0.1:9222 so the
# chrome-devtools MCP (configured to attach via --browserUrl) has a browser to
# connect to. Idempotent — no-op if /json/version already responds.
#
# Chrome is launched via /usr/local/bin/google-chrome, the image-baked wrapper
# that always adds --remote-debugging-port=9222 (see Dockerfile). Backgrounded
# with nohup + disown so it survives this shell exiting.
__presentia_ensure_chrome_running() {
  if curl -sS -m 2 -o /dev/null http://127.0.0.1:9222/json/version 2>/dev/null; then
    return 0
  fi
  if [ ! -x /usr/local/bin/google-chrome ]; then
    echo "WARN: /usr/local/bin/google-chrome wrapper missing — chrome-devtools MCP won't find a browser."
    return 0
  fi
  nohup /usr/local/bin/google-chrome about:blank > /tmp/chrome-agent.log 2>&1 &
  disown 2>/dev/null || true
  # Wait briefly for the debug port to come up. Don't block long — if Chrome
  # is slow to start, the MCP will surface the error on the first tool call
  # and the agent can react. ~5s is enough for a warm container.
  local i
  for i in $(seq 1 20); do
    if curl -sS -m 1 -o /dev/null http://127.0.0.1:9222/json/version 2>/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  echo "WARN: Chrome on :9222 didn't come up within ~5s — check /tmp/chrome-agent.log."
}

# Ensure agent-ping is wired as the Claude Code Notification hook.
__presentia_ensure_notification_hook() {
  local cfg="$HOME/.claude/settings.json"
  command -v jq >/dev/null || return 0
  mkdir -p "$(dirname "$cfg")"
  [ -f "$cfg" ] || echo '{}' > "$cfg"
  if jq -e '(.hooks.Notification // []) | map(.hooks // []) | flatten | map(.command // "") | any(. == "/usr/local/bin/agent-ping")' "$cfg" >/dev/null 2>&1; then
    return 0
  fi
  local tmp
  tmp=$(mktemp) || return 1
  jq '.hooks = (.hooks // {}) | .hooks.Notification = ((.hooks.Notification // []) + [{"hooks":[{"type":"command","command":"/usr/local/bin/agent-ping"}]}])' "$cfg" > "$tmp" \
    && mv "$tmp" "$cfg"
}

# Fresh-clone agent-workspace, create a session-unique branch off main, push
# it up so the branch persists even if this container dies mid-task. Then
# symlink the agent-facing files (CLAUDE.md, memory, agent-skills) into
# locations Claude Code reads.
#
# Containers are now non-persistent (no /home/kasm-user bind-mount). Each
# session is therefore a fresh clone — no "if exists, pull" path.
#
# Auths via the presentia-agent-tooling GitHub App: the host mints an
# installation token via cron and bind-mounts it at /etc/presentia/github-token;
# the credential helper at /usr/local/bin/presentia-gh-token (wired into
# /etc/gitconfig at image build) feeds the token to git over HTTPS.
#
# Sets:
#   ~/agent/tooling/                     — fresh clone of Presentia-AI/agent-workspace
#                                          on branch agent/session-<ts>-<rand>
#   ~/agent/CLAUDE.md  -> tooling/general-purpose/CLAUDE.md
#   ~/.claude/projects/-home-kasm-user-agent/memory -> tooling/memory
#   ~/.claude/skills   -> tooling/agent-skills
#   ~/agent/SESSION_BRANCH               — bare branch name for easy reference
__presentia_ensure_session() {
  local agent_dir="$HOME/agent"
  local tooling="$agent_dir/tooling"
  local repo="https://github.com/Presentia-AI/agent-workspace.git"
  local token_file="/etc/presentia/github-token"
  local notice="$agent_dir/GITHUB_APP_TOKEN_MISSING.md"

  mkdir -p "$agent_dir"

  # The Kasm host bind-mounts the installation token here. If it's missing,
  # the workspace was launched without the mount — surface it loudly instead
  # of silently failing the clone.
  if [ ! -r "$token_file" ]; then
    cat > "$notice" <<EOF
# GitHub App token not mounted

The agent tooling repo clone can't proceed because the installation token
isn't bind-mounted into this container.

Expected file: \`$token_file\` (mode 600, owned by uid 1000)
Host source:   \`/var/lib/kasm-secrets/agent-creds/github-token\` on kasm-01
Host minter:   \`/usr/local/bin/presentia-mint-token\` (cron every 50 min)

Fix: on kasm-01, confirm the Kasm image row's volume_mappings bind-mounts
\`/var/lib/kasm-secrets/agent-creds:/etc/presentia:ro\`, then relaunch this
session.
EOF
    return 1
  fi
  rm -f "$notice"

  # Skip if already initialized this boot (subsequent shells in the same
  # session shouldn't re-clone or create a new branch).
  if [ -d "$tooling/.git" ] && [ -f "$agent_dir/SESSION_BRANCH" ]; then
    return 0
  fi

  # Fresh clone. Container is ephemeral, so anything sitting in $tooling from
  # a stale state is wiped — the source of truth is the branch on the remote.
  rm -rf "$tooling"
  if ! git clone --quiet "$repo" "$tooling" 2>/dev/null; then
    cat > "$notice" <<EOF
# Tooling clone failed

GitHub App token is mounted at \`$token_file\` but \`git clone $repo\`
still failed. Likely causes:
  - Token expired (host cron hasn't run recently — check /var/log/presentia-mint-token.log on kasm-01)
  - App installation removed or repo removed from installation scope
  - Network egress blocked
EOF
    return 1
  fi

  # Configure commit identity for this clone.
  git -C "$tooling" config user.email "claude-agent@presentia.ai"
  git -C "$tooling" config user.name  "Claude AI Agent"

  # Create the session branch off whatever main is right now, and push it up
  # so the branch exists remotely (durable record if the container dies).
  local session_id branch
  session_id="$(date -u +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c6 /dev/urandom | xxd -p)"
  branch="agent/session-${session_id}"
  git -C "$tooling" checkout -b "$branch" --quiet
  if ! git -C "$tooling" push -u origin "$branch" --quiet 2>/dev/null; then
    echo "WARN: failed to push session branch ${branch} — agent state won't persist if container dies."
    echo "       Check App permissions: Contents:write + Pull requests:write."
  fi

  printf '%s\n' "$branch" > "$agent_dir/SESSION_BRANCH"

  # Symlink CLAUDE.md into ~/agent/ so Claude Code (launched from ~/agent/)
  # finds it. No more role disambiguation — one image, one CLAUDE.md.
  local agent_ctx="$tooling/general-purpose"
  if [ -e "$agent_ctx/CLAUDE.md" ]; then
    ln -sfn "$agent_ctx/CLAUDE.md" "$agent_dir/CLAUDE.md"
  fi

  # Shared memory + skills. Slug matches the agent's CWD (~/agent).
  local slug="-home-kasm-user-agent"
  local mem_parent="$HOME/.claude/projects/$slug"
  mkdir -p "$mem_parent" "$HOME/.claude"
  [ -d "$tooling/memory" ]       && ln -sfn "$tooling/memory"       "$mem_parent/memory"
  [ -d "$tooling/agent-skills" ] && ln -sfn "$tooling/agent-skills" "$HOME/.claude/skills"
}

if [ -n "$PS1" ] && [ -z "$TMUX" ] && [ -z "$AGENT_BANNER_SHOWN" ]; then
  export AGENT_BANNER_SHOWN=1
  __presentia_setup_gh_auth
  __presentia_ensure_chrome_devtools_mcp
  __presentia_ensure_chrome_running
  __presentia_ensure_notification_hook
  if __presentia_ensure_session; then
    branch="$(cat ~/agent/SESSION_BRANCH 2>/dev/null || echo '?')"
    echo "Presentia Agent ready. Session branch: ${branch}. Auto-attaching tmux session [main]..."
  else
    echo "Presentia Agent: session setup failed — see ~/agent/GITHUB_APP_TOKEN_MISSING.md, then open a new terminal."
  fi
  cd ~/agent 2>/dev/null || true
  if command -v tmux >/dev/null; then
    tmux new-session -A -s main
  fi
fi
