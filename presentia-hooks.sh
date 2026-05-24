# shellcheck shell=bash
# Presentia agent shell hooks. COPYed to /etc/presentia-hooks.sh by the image
# build and sourced from /etc/bash.bashrc. Lives here (not inlined in the
# Dockerfile) so it's diff-able, lint-able, and testable in isolation.
#
# Loaded for every shell on the image; the heavy interactive setup is gated on
# $PS1 at the bottom.

# Ensure chrome-devtools MCP is registered in this user's Claude Code config.
__presentia_ensure_chrome_devtools_mcp() {
  local cfg="$HOME/.claude.json"
  if [ -f "$cfg" ] && grep -q '"chrome-devtools"' "$cfg" 2>/dev/null; then
    return 0
  fi
  command -v jq >/dev/null || return 0
  [ -f "$cfg" ] || echo '{}' > "$cfg"
  local tmp
  tmp=$(mktemp) || return 1
  jq '.mcpServers["chrome-devtools"] = {"type":"stdio","command":"chrome-devtools-mcp","args":[]}' "$cfg" > "$tmp" \
    && mv "$tmp" "$cfg"
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

# One-time fixup for existing persistent profiles whose Desktop/google-chrome.desktop
# still points at /usr/bin/google-chrome (bypasses the debug-port wrapper).
__presentia_fix_chrome_desktop_icon() {
  local f="$HOME/Desktop/google-chrome.desktop"
  [ -f "$f" ] || return 0
  grep -q '^Exec=/usr/bin/google-chrome' "$f" 2>/dev/null || return 0
  sed -i 's|^Exec=/usr/bin/google-chrome|Exec=/usr/local/bin/google-chrome|g' "$f" 2>/dev/null || true
}

# Clone / refresh the agent-workspace tooling repo and wire role-scoped files
# into ~/agent. Auths via the presentia-agent-tooling GitHub App: the host
# mints an installation token via cron and bind-mounts it at
# /etc/presentia/github-token; the credential helper at
# /usr/local/bin/presentia-gh-token (wired into /etc/gitconfig at image build)
# feeds the token to git over HTTPS. The App private key never enters the
# container.
#
# Sets:
#   ~/agent/tooling/                — clone of Presentia-AI/agent-workspace
#   ~/agent/active-role -> tooling/$ROLE
#   ~/agent/{CLAUDE,AGENT-CRON-PROMPT,PROCESSES}.md -> tooling/$ROLE/...
#   ~/.claude/projects/-home-kasm-user-agent/memory -> tooling/memory
#   ~/.claude/skills -> tooling/agent-skills
__presentia_ensure_tooling() {
  local role="${KASM_ROLE_LABEL:-general-purpose}"
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
Host source:   \`/var/lib/kasm-secrets/github-token\` on kasm-01
Host minter:   \`/usr/local/bin/presentia-mint-token\` (cron every 50 min)

Fix: on kasm-01, confirm the Kasm workspace docker_run_config bind-mounts
\`/var/lib/kasm-secrets/github-token:/etc/presentia/github-token:ro\`, then
relaunch this session.
EOF
    return 1
  fi
  rm -f "$notice"

  # Clone (or pull) the tooling repo. The credential helper baked into
  # /etc/gitconfig supplies x-access-token + the installation token.
  if [ ! -d "$tooling/.git" ]; then
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
  else
    (cd "$tooling" && git pull --rebase --quiet 2>/dev/null) || true
  fi

  # Symlink role-scoped files into ~/agent/ so existing tooling that reads
  # ~/agent/CLAUDE.md keeps working.
  local role_dir="$tooling/$role"
  if [ -d "$role_dir" ]; then
    ln -sfn "$role_dir" "$agent_dir/active-role"
    local f
    for f in CLAUDE.md AGENT-CRON-PROMPT.md PROCESSES.md; do
      [ -e "$role_dir/$f" ] && ln -sfn "$role_dir/$f" "$agent_dir/$f"
    done
  fi

  # Shared memory + skills: same pattern as bin/bootstrap-workspace.sh in the
  # CEO repo on the Mac. Slug matches the agent's CWD (~/agent).
  local slug="-home-kasm-user-agent"
  local mem_parent="$HOME/.claude/projects/$slug"
  mkdir -p "$mem_parent" "$HOME/.claude"
  [ -d "$tooling/memory" ] && ln -sfn "$tooling/memory" "$mem_parent/memory"
  [ -d "$tooling/agent-skills" ] && ln -sfn "$tooling/agent-skills" "$HOME/.claude/skills"
}

if [ -n "$PS1" ] && [ -z "$TMUX" ] && [ -z "$AGENT_BANNER_SHOWN" ]; then
  export AGENT_BANNER_SHOWN=1
  __presentia_ensure_chrome_devtools_mcp
  __presentia_ensure_notification_hook
  __presentia_fix_chrome_desktop_icon
  if __presentia_ensure_tooling; then
    echo "Presentia Agent ready [role=${KASM_ROLE_LABEL:-general-purpose}]. Tooling synced. Auto-attaching tmux session [main]..."
  else
    echo "Presentia Agent: tooling clone failed — see ~/agent/GITHUB_APP_TOKEN_MISSING.md, then open a new terminal."
  fi
  cd ~/agent 2>/dev/null || true
  if command -v tmux >/dev/null; then
    tmux new-session -A -s main
  fi
fi
