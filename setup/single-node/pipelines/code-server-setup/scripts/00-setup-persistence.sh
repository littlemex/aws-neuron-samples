#!/usr/bin/env bash
set -euo pipefail

# Task: Setup filesystem persistence (NVMe + EFS + /home/coder + NEFF dual cache)
# NVMe instance store mount, EFS mount, /home/coder symlink to EFS, and Neuron NEFF compile cache
# (NVMe primary + EFS backup via rsync). Idempotent: re-running recovers state after Spot
# stop/start (NVMe is wiped on stop).

echo '==> Running setup-persistence.sh'
cat > /tmp/setup-persistence.sh <<'PERSIST_SCRIPT_EOF'
#!/bin/bash
# Auto-generated: mirrors scripts/setup-persistence.sh so it can be run through run-tasks.sh
# If this task changes, keep scripts/setup-persistence.sh in sync.
EFS_ID="${EFS_ID}"
EFS_SUBPATH="${EFS_SUBPATH}"
CODE_USER="${USER}"
HOME_DIR="${HOME_DIR}"
NEFF_RESTORE_FROM_EFS=yes
AWS_REGION="${AWS_REGION:-$(TOKEN=$(curl -sSfX PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60'); curl -sSf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null)}"
export EFS_ID EFS_SUBPATH CODE_USER HOME_DIR NEFF_RESTORE_FROM_EFS AWS_REGION
bash /tmp/setup-persistence-full.sh
PERSIST_SCRIPT_EOF

# The full script body is transferred to the instance by setup-code-server.sh
# (the preamble in setup-code-server.sh uploads /tmp/setup-persistence-full.sh)
if [ ! -f /tmp/setup-persistence-full.sh ]; then
  echo 'ERROR: /tmp/setup-persistence-full.sh not found on instance'
  echo 'setup-code-server.sh must upload it before this task runs'
  exit 1
fi
bash /tmp/setup-persistence.sh
