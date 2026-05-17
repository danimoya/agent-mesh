#!/usr/bin/env bash
# Container entrypoint: start sshd (in foreground, logging to stderr so
# `docker compose up` shows it), then exec the role-specific test script
# based on hostname (alpha or beta).
set -euo pipefail

# Belt + braces: defensive perm-fixup in case anything upstream loosened modes
chmod 700 ~/.ssh                       2>/dev/null || true
chmod 600 ~/.ssh/authorized_keys       2>/dev/null || true
chmod 600 ~/.ssh/id_ed25519            2>/dev/null || true

# Start sshd in background; -e routes its log to stderr so docker logs catch it
sudo /usr/sbin/sshd -e

# StrictHostKeyChecking off — every container's host key is the same baked one.
mkdir -p ~/.ssh
cat > ~/.ssh/config <<EOF
Host alpha beta
  User mesh
  IdentityFile /home/mesh/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  BatchMode yes
EOF
chmod 600 ~/.ssh/config

echo "$(hostname): authorized_keys + id pub fingerprint:" >&2
ssh-keygen -lf ~/.ssh/authorized_keys 2>&1 | head -1 >&2
ssh-keygen -lf ~/.ssh/id_ed25519.pub  2>&1 | head -1 >&2

# Run the role-specific scenario
role="$(hostname)"
exec "/opt/agent-mesh/ci/${role}.sh"
