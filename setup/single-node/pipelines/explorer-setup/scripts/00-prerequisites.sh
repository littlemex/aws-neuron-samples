#!/usr/bin/env bash
set -euo pipefail

# Task: Verify prerequisites (neuron-explorer binary, nginx site, target user)
# Description: Hard-fail before mutating state if the host is not ready.

echo '==> Verifying prerequisites'

test -x /opt/aws/neuron/bin/neuron-explorer || {
  echo 'ERROR: /opt/aws/neuron/bin/neuron-explorer missing - update Neuron SDK first'
  exit 1
}

test -f /etc/nginx/sites-enabled/code-server || {
  echo 'ERROR: /etc/nginx/sites-enabled/code-server missing - run code-server-setup first'
  exit 1
}

id "${EXPLORER_USER}" >/dev/null 2>&1 || {
  echo "ERROR: user ${EXPLORER_USER} does not exist"
  exit 1
}

echo 'Prerequisites OK'
