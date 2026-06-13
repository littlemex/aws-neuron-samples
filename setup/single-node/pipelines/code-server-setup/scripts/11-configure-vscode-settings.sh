#!/usr/bin/env bash
set -euo pipefail

# Task: Configure VS Code settings
# Write the default VS Code user settings.json with Neuron-friendly defaults

echo '==> Configuring VS Code settings'
mkdir -p "/home/${USER}/.local/share/code-server/User/"

cat > "/home/${USER}/.local/share/code-server/User/settings.json" <<'EOF'
{
  "extensions.autoUpdate": false,
  "extensions.autoCheckUpdates": false,
  "telemetry.telemetryLevel": "off",
  "security.workspace.trust.startupPrompt": "never",
  "security.workspace.trust.enabled": false,
  "security.workspace.trust.banner": "never",
  "security.workspace.trust.emptyWindow": false,
  "auto-run-command.rules": [
    {
      "command": "workbench.action.terminal.new"
    }
  ]
}
EOF

chown -R "${USER}:${USER}" "/home/${USER}/.local"
echo 'VS Code settings configured'
