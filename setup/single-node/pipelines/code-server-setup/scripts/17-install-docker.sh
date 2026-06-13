#!/usr/bin/env bash
set -euo pipefail

# Task: Install Docker and grant rootless access to the code-server user
# Install docker.io (no-op when the DLAMI already ships Docker), start the daemon, and add
# the user to the docker group so the code-server user can run `docker` without sudo. Idempotent.

echo '==> Ensuring Docker is installed'
if command -v docker >/dev/null 2>&1; then
  echo "docker already present: $(docker --version 2>/dev/null || true)"
else
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker.io
fi

echo '==> Enabling and starting the docker service'
systemctl enable --now docker || true
systemctl is-active docker && echo 'docker ACTIVE' || echo 'docker INACTIVE'

echo "==> Adding ${USER} to the docker group (rootless docker access)"
getent group docker >/dev/null 2>&1 || groupadd docker
if id -nG "${USER}" | tr ' ' '\n' | grep -qx docker; then
  echo "${USER} already in docker group"
else
  usermod -aG docker "${USER}"
  echo "${USER} added to docker group (takes effect on next login / next SSM task)"
fi

echo "==> Smoke-testing docker as ${USER}"
# `sg docker -c ...` runs a one-off shell with the docker group applied so
# the check works in the same SSM invocation where we added the group.
sudo -u "${USER}" sg docker -c 'docker version --format "client: {{.Client.Version}} server: {{.Server.Version}}"' || echo 'docker smoke test failed'
