FROM kasmweb/ubuntu-jammy-desktop:1.17.0

USER root

# Node 20 + git, tmux for session resilience, sudo for in-workspace package mgmt,
# gh CLI for the agent's session-branch + PR self-improvement loop.
# Auth to the tooling repo is via the presentia-agent-tooling GitHub App (HTTPS
# + bind-mounted installation token), so no openssh-client / ssh-key plumbing.
# gh reads the same token via GH_TOKEN env (set in /etc/presentia-hooks.sh).
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod a+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs git jq tmux sudo gh \
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

# presentia-gh-token: git credential helper that reads the bind-mounted
# GitHub App installation token (refreshed by the host cron) and emits
# git's credential protocol. The /etc/gitconfig stanza below scopes it to
# the agent-workspace repo so it can never leak to unrelated clones.
# Both URL forms (with and without ".git") are registered because git's
# credential URL matcher does component-wise path-prefix matching — the
# trailing ".git" makes "agent-workspace" not a matching component prefix
# of "agent-workspace.git", so without both stanzas the helper silently
# never fires on real `git push` / `git fetch` calls.
COPY presentia-gh-token /usr/local/bin/presentia-gh-token
RUN chmod +x /usr/local/bin/presentia-gh-token \
 && printf '%s\n' \
    '[credential "https://github.com/Presentia-AI/agent-workspace"]' \
    '    helper = /usr/local/bin/presentia-gh-token' \
    '[credential "https://github.com/Presentia-AI/agent-workspace.git"]' \
    '    helper = /usr/local/bin/presentia-gh-token' \
    >> /etc/gitconfig

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
