FROM kasmweb/ubuntu-jammy-desktop:1.17.0

USER root

# Node 20 + git, tmux for session resilience, sudo for in-workspace package mgmt,
# openssh-client for the tooling-repo deploy-key clone.
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs git jq tmux sudo openssh-client \
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

# Empty agent working dir. The role-scoped CLAUDE.md, AGENT-CRON-PROMPT.md,
# memory/, and agent-skills/ are cloned at first interactive shell from
# Presentia-AI/agent-workspace by __presentia_ensure_tooling (see hooks file).
RUN mkdir -p /home/kasm-user/agent \
 && chown -R 1000:1000 /home/kasm-user/agent

# agent-ping: posts a ClickUp comment when Claude is blocked on user input.
# Wired up via presentia-hooks.sh as a Claude Code Notification hook.
COPY agent-ping /usr/local/bin/agent-ping
RUN chmod +x /usr/local/bin/agent-ping

# Custom desktop launcher (kept from v0)
COPY --chown=1000:1000 claude-agent.desktop /home/kasm-user/Desktop/claude-agent.desktop
RUN chmod +x /home/kasm-user/Desktop/claude-agent.desktop

# All shell hooks live in /etc/presentia-hooks.sh (diff-able, lint-able). The
# single-line append to /etc/bash.bashrc just sources it. System-wide rather
# than ~/.bashrc because Kasm bind-mounts /home/kasm-user/ from the persistent
# profile, which would shadow anything baked into the user home.
COPY presentia-hooks.sh /etc/presentia-hooks.sh
RUN chmod 0644 /etc/presentia-hooks.sh \
 && printf '\n# Presentia agent hooks\n[ -f /etc/presentia-hooks.sh ] && . /etc/presentia-hooks.sh\n' >> /etc/bash.bashrc

USER 1000
WORKDIR /home/kasm-user
