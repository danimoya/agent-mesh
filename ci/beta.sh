#!/usr/bin/env bash
# Role: beta — passive peer. Set up mesh, create a tmux session, then
# just sleep. Alpha drives the test and asserts.
set -euo pipefail

cd /opt/agent-mesh
./install.sh

# Configure mesh
mkdir -p ~/.agents
echo beta > ~/.agents/self.conf
cat > ~/.agents/peers.conf <<EOF
alpha
beta
EOF

# Start a tmux session that survives the test
tmux new-session -d -s ci -n probe "exec sleep 600"

# Register + sync
~/bin/agent-discover

# Tell stdout we're ready (alpha looks for this file)
touch /tmp/beta-ready

# Sleep until alpha tears us down
sleep 300
