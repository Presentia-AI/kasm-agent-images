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
# into ~/agent. Generates a per-workspace SSH deploy key on first run; if the
# key isn't registered on the repo yet, writes DEPLOY_KEY_TO_REGISTER.md with
# instructions and exits non-zero so the banner surfaces it.
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
  local repo="git@github.com:Presentia-AI/agent-workspace.git"
  local key="$HOME/.ssh/id_ed25519"
  local notice="$agent_dir/DEPLOY_KEY_TO_REGISTER.md"

  mkdir -p "$agent_dir" "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  # known_hosts: pin github.com on first run so the clone doesn't hang on
  # interactive prompt or fail strict-host-key-checking.
  if [ ! -f "$HOME/.ssh/known_hosts" ] || ! ssh-keygen -F github.com -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
    ssh-keyscan -t ed25519 github.com 2>/dev/null >> "$HOME/.ssh/known_hosts"
    chmod 600 "$HOME/.ssh/known_hosts"
  fi

  # Generate a per-workspace deploy key once. Stored in the persistent profile.
  if [ ! -f "$key" ]; then
    ssh-keygen -t ed25519 -N "" -C "kasm-${role}-$(hostname)" -f "$key" >/dev/null 2>&1
    chmod 600 "$key"
    chmod 644 "${key}.pub"
  fi

  # Clone (or pull) the tooling repo.
  if [ ! -d "$tooling/.git" ]; then
    if ! GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes" \
         git clone --quiet "$repo" "$tooling" 2>/dev/null; then
      cat > "$notice" <<EOF
# Register this workspace's deploy key

The agent tooling repo (\`Presentia-AI/agent-workspace\`) clone failed because
this workspace's SSH key isn't registered as a deploy key yet.

## Public key
\`\`\`
$(cat "${key}.pub")
\`\`\`

## Steps
1. Visit: https://github.com/Presentia-AI/agent-workspace/settings/keys/new
2. Title: \`kasm-${role}-$(hostname)\`
3. Tick "Allow write access" (agent pushes skills/memory updates back)
4. Paste the public key above and save
5. Open a fresh terminal in this workspace — the clone will retry automatically
EOF
      return 1
    fi
    rm -f "$notice"
  else
    (cd "$tooling" && GIT_SSH_COMMAND="ssh -o BatchMode=yes" git pull --rebase --quiet 2>/dev/null) || true
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
    echo "Presentia Agent: tooling clone failed — register the deploy key (see ~/agent/DEPLOY_KEY_TO_REGISTER.md), then open a new terminal."
  fi
  cd ~/agent 2>/dev/null || true
  if command -v tmux >/dev/null; then
    tmux new-session -A -s main
  fi
fi
