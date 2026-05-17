#!/usr/bin/env bash
# Container entrypoint: start sshd (in foreground, logging to stderr so
# `docker compose up` shows it), then exec the role-specific test script
# based on hostname (alpha or beta).
set -euo pipefail

# Belt + braces: defensive perm-fixup in case anything upstream loosened modes
chmod 700 ~/.ssh                       2>/dev/null || true
chmod 600 ~/.ssh/authorized_keys       2>/dev/null || true
chmod 600 ~/.ssh/id_ed25519            2>/dev/null || true

# -D keeps sshd in the foreground so daemon() doesn't close stdio; -e routes
# log to stderr; & backgrounds the shell job. Captures auth-level traces in
# `docker compose up` output.
sudo /usr/sbin/sshd -D -e &
SSHD_PID=$!
sleep 2

# Diagnose: is sshd actually up?
echo "=== $(hostname): sshd status ===" >&2
pgrep -fa sshd >&2 || echo "  NO sshd processes!" >&2
ss -ltn 'sport = :22' 2>&1 | tail -n +2 | head >&2 || true

# Self-ssh sanity check — same image, same keypair, should always work
echo "=== $(hostname): self-ssh test ===" >&2
ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    localhost 'echo "  self-ssh OK on $(hostname)"' 2>&1 >&2 \
    || echo "  self-ssh FAILED on $(hostname)" >&2

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
