#!/usr/bin/env bash
# Role: alpha — drives the test. Waits for beta to be reachable, installs,
# sends a ping and a file, asserts both landed on beta. Exits 0 on success.
set -euo pipefail

cd /opt/agent-mesh
./install.sh

mkdir -p ~/.agents
echo alpha > ~/.agents/self.conf
cat > ~/.agents/peers.conf <<EOF
alpha
beta
EOF

# Start a tmux session of our own (alpha is also a registry member)
tmux new-session -d -s ci -n driver "exec sleep 600"

# Wait for beta's sshd + tmux to be up. The beta script creates /tmp/beta-ready
# inside its container; we can't see that file from here, so we poll via SSH.
echo "alpha: waiting for beta..."
for i in $(seq 1 60); do
  if ssh -o BatchMode=yes -o ConnectTimeout=2 beta 'test -f /tmp/beta-ready' 2>/dev/null; then
    echo "alpha: beta is ready (after ${i}s)"
    break
  fi
  sleep 1
done
ssh beta 'test -f /tmp/beta-ready' || { echo "FAIL: beta never came up"; exit 1; }

# Assemble the registry from both peers
~/bin/agent-discover

echo "alpha: registry contents ↓"
~/bin/notify-pane --list

# Assert both peers' windows are in the registry
~/bin/notify-pane --list | grep -q '^alpha-ci-driver$' || { echo "FAIL: alpha not registered"; exit 1; }
~/bin/notify-pane --list | grep -q '^beta-ci-probe$'   || { echo "FAIL: beta not registered"; exit 1; }

# Send a text ping alpha → beta
FORCE_SEND=1 ~/bin/notify-pane beta-ci-probe "twohost-payload-aaa"

# Send a file alpha → beta
echo "manifest body" > /tmp/test.txt
FORCE_SEND=1 ~/bin/notify-pane beta-ci-probe --file /tmp/test.txt "scope=qa"

sleep 1

# Capture beta's pane and assert
captured="$(ssh beta 'tmux capture-pane -p -S -50 -t ci:probe')"
echo "$captured" | tail -20
echo "$captured" | grep -q 'twohost-payload-aaa' || { echo "FAIL: text ping not delivered"; exit 1; }
echo "$captured" | grep -q 'file dropped at'      || { echo "FAIL: file drop not announced"; exit 1; }

# Confirm the file actually landed in beta's inbox
ssh beta 'find ~/.agent-inbox -type f -name test.txt' | grep -q test.txt || { echo "FAIL: file not in beta inbox"; exit 1; }
ssh beta 'cat $(find ~/.agent-inbox -type f -name test.txt | head -1)' | grep -q 'manifest body' || { echo "FAIL: file content corrupt"; exit 1; }

echo "PASS: two-host mesh smoke (text + file)"
