#!/usr/bin/env bash
set -euo pipefail

# Task: Install Claude Code and neuron-agentic-development (opt-in)
# When INSTALL_CLAUDE_CODE=yes, install the Anthropic Claude Code CLI (npm -g) and the
# neuron-agentic-development Python package, then run deploy-neuron-agentic-development-to-claude
# to populate ~/.claude/agents and ~/.claude/skills for the code-server user.
# Skipped when INSTALL_CLAUDE_CODE=no.

echo '==> Install Claude Code + neuron-agentic-development (opt-in)'
if [ "${INSTALL_CLAUDE_CODE}" != 'yes' ]; then
  echo "[skip] INSTALL_CLAUDE_CODE=\"${INSTALL_CLAUDE_CODE}\" (opt-in flag is off)"
  exit 0
fi

CODER_USER="${USER}"
CODER_HOME=$(getent passwd "$CODER_USER" | cut -d: -f6)
# Some code-server packagings drop ~/.bashrc as root:root which blocks the user
# from appending PATH. Make sure dotfiles are owned by the user before we touch them.
sudo touch "$CODER_HOME/.bashrc"
sudo chown "$CODER_USER:$CODER_USER" "$CODER_HOME/.bashrc"
sudo chmod 0644 "$CODER_HOME/.bashrc"

# Install Claude Code CLI globally for the code-server user.
# Uses ~/.npm-global as the npm prefix to avoid sudo.
sudo -u "$CODER_USER" bash -lc '
  set -e
  mkdir -p ~/.npm-global
  npm config set prefix ~/.npm-global
  grep -q npm-global/bin ~/.bashrc || echo "export PATH=$HOME/.npm-global/bin:$PATH" >> ~/.bashrc
  if ! command -v node >/dev/null 2>&1; then
    echo node-missing
    exit 1
  fi
  if ! ~/.npm-global/bin/claude --version >/dev/null 2>&1; then
    npm install -g @anthropic-ai/claude-code 2>&1 | tail -5
  fi
  ~/.npm-global/bin/claude --version || true
'

# Install neuron-agentic-development agents/skills into ~/.claude for the user.
sudo -u "$CODER_USER" bash -lc '
  set -e
  python3 -m venv --system-site-packages ~/neuron-agentic-venv || python3 -m venv ~/neuron-agentic-venv
  source ~/neuron-agentic-venv/bin/activate
  pip install --quiet --upgrade pip
  pip install --quiet --upgrade neuron-agentic-development \
      --extra-index-url https://pip.repos.neuron.amazonaws.com
  deploy-neuron-agentic-development-to-claude
  echo === deployed agents ===
  ls ~/.claude/agents/ 2>/dev/null | head -20 || echo no-agents
  echo === deployed skills ===
  ls ~/.claude/skills/ 2>/dev/null | head -20 || echo no-skills
'
