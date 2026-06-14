#!/usr/bin/env bash
set -euo pipefail

# Task: Create code command
# Install a `code` CLI wrapper so the user can open files in code-server from a shell

echo '==> Creating code command'
cat > /usr/local/bin/code <<'WRAPPER_EOF'
#!/bin/bash
if [ "$1" = "." ]; then
  current_dir=$(pwd)
  /usr/bin/code-server $current_dir
elif [ -n "$1" ]; then
  target=$(realpath "$1" 2>/dev/null || echo "$1")
  /usr/bin/code-server $target
fi
WRAPPER_EOF

chmod +x /usr/local/bin/code
echo 'code command created'
