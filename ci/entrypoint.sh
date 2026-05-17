#!/usr/bin/env bash
# Container entrypoint: start sshd, then exec the role-specific test script
# based on hostname (alpha or beta).
set -euo pipefail

sudo /usr/sbin/sshd

# StrictHostKeyChecking off — every container's host key is the same baked one.
mkdir -p ~/.ssh
cat > ~/.ssh/config <<EOF
Host alpha beta
  User mesh
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
EOF
chmod 600 ~/.ssh/config

# Run the role-specific scenario
role="$(hostname)"
exec "/opt/agent-mesh/ci/${role}.sh"
