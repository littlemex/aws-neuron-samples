#!/usr/bin/env bash
set -euo pipefail

# NOTE: this script delegates to /tmp/setup-explorer.sh which is uploaded
# by setup-explorer-wrapper.sh. The wrapper version of that script must
# write its nginx include to /etc/nginx/conf.d/explorer-location.conf
# rather than awk-patching /etc/nginx/sites-enabled/code-server in place.
# Otherwise re-running code-server-setup overwrites the include silently.

# Task: Install systemd unit, nginx fragment, and start the service
# Description: Drops setup-explorer.sh on the instance and runs it.
#   Re-runnable: the script is idempotent and patches
#   /etc/nginx/sites-enabled/code-server only if the include directive is missing.

echo '==> Running setup-explorer.sh'

if [ ! -f /tmp/setup-explorer.sh ]; then
  echo 'ERROR: /tmp/setup-explorer.sh not found on instance'
  echo 'deploy.sh / install-explorer.sh must upload it before this task runs'
  exit 1
fi

EXPLORER_USER="${EXPLORER_USER}" \
EXPLORER_PORT="${EXPLORER_PORT}" \
EXPLORER_API_PORT="${EXPLORER_API_PORT}" \
EXPLORER_DATA_DIR="${EXPLORER_DATA_DIR}" \
EXPLORER_DISPLAY_NAME="${EXPLORER_DISPLAY_NAME}" \
NGINX_LOCATION="${NGINX_LOCATION}" \
bash /tmp/setup-explorer.sh
