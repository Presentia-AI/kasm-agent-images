FROM kasmweb/ubuntu-jammy-desktop:1.17.0

USER root

# Node 20 + git, tmux for session resilience, sudo for in-workspace package mgmt
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs git jq tmux sudo \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @anthropic-ai/claude-code chrome-devtools-mcp

# Passwordless sudo for kasm-user (uid 1000)
RUN echo 'kasm-user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/kasm-user \
 && chmod 0440 /etc/sudoers.d/kasm-user

# Chrome managed policy: restore last session on startup
RUN mkdir -p /etc/opt/chrome/policies/managed \
 && printf '{"RestoreOnStartup": 1}\n' > /etc/opt/chrome/policies/managed/restore-tabs.json

# Chrome wrapper that enables DevTools Protocol so Claude Code can drive it.
# Both the system .desktop launcher (taskbar) AND the desktop-icon .desktop
# (which is seeded from /home/kasm-default-profile/Desktop/) are patched to
# call the wrapper instead of /usr/bin/google-chrome directly.
RUN printf '%s\n' \
    '#!/bin/bash' \
    '# Launch Chrome with DevTools Protocol on 127.0.0.1:9222 for Claude Code.' \
    'exec /usr/bin/google-chrome --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1 "$@"' \
    > /usr/local/bin/google-chrome \
 && chmod +x /usr/local/bin/google-chrome \
 && sed -i 's|^Exec=/usr/bin/google-chrome|Exec=/usr/local/bin/google-chrome|g' /usr/share/applications/google-chrome.desktop \
 && sed -i 's|^Exec=/usr/bin/google-chrome|Exec=/usr/local/bin/google-chrome|g' /home/kasm-default-profile/Desktop/google-chrome.desktop

# Role-scoped working directory + CLAUDE.md
RUN mkdir -p /home/kasm-user/agent \
 && chown -R 1000:1000 /home/kasm-user/agent

COPY --chown=1000:1000 CLAUDE.md /home/kasm-user/agent/CLAUDE.md

# agent-ping: posts a ClickUp comment when Claude is blocked on user input.
# Wired up below via /etc/bash.bashrc as a Claude Code Notification hook.
COPY agent-ping /usr/local/bin/agent-ping
RUN chmod +x /usr/local/bin/agent-ping

# Custom desktop launcher (kept from v0)
COPY --chown=1000:1000 claude-agent.desktop /home/kasm-user/Desktop/claude-agent.desktop
RUN chmod +x /home/kasm-user/Desktop/claude-agent.desktop

# Banner + tmux auto-attach + first-run config bootstrap, in /etc/bash.bashrc
# (system-wide; survives host bind-mount over /home/kasm-user).
RUN cat >> /etc/bash.bashrc << 'BASHRC_EOF'

# --- Presentia agent additions ---

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

if [ -n "$PS1" ] && [ -z "$TMUX" ] && [ -z "$AGENT_BANNER_SHOWN" ]; then
  export AGENT_BANNER_SHOWN=1
  __presentia_ensure_chrome_devtools_mcp
  __presentia_ensure_notification_hook
  __presentia_fix_chrome_desktop_icon
  echo 'Presentia Agent ready. CLAUDE.md is in ~/agent. Auto-attaching tmux session [main]...'
  cd ~/agent 2>/dev/null || true
  if command -v tmux >/dev/null; then
    tmux new-session -A -s main
  fi
fi
BASHRC_EOF

USER 1000
WORKDIR /home/kasm-user
