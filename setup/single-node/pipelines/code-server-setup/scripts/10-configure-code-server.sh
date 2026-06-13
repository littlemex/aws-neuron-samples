#!/usr/bin/env bash
set -euo pipefail

# Task: Configure Code Server
# Write the code-server configuration file. Uses auth: none because authentication is handled
# upstream (CloudFront cf_session HMAC + Cognito Hosted UI per ADR-005/011). The instance is
# locked behind an empty-ingress security group; localhost:8080 is reached only via SSM
# port-forward or the ALB+CloudFront chain. A second password layer here would conflict with
# cf_session SSO and is intentionally disabled.

echo '==> Configuring Code Server (auth: none, gated by CloudFront cf_session)'
mkdir -p "/home/${USER}/.config/code-server"

# Create config file
cat > "/home/${USER}/.config/code-server/config.yaml" <<'EOF'
cert: false
auth: none
EOF

chown -R "${USER}:${USER}" "/home/${USER}/.config"
echo 'Code Server configuration created (auth=none)'
