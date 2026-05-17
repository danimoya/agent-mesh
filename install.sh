#!/usr/bin/env bash
# agent-mesh installer. Run this once on every host in the mesh, AFTER you've
# set up SSH connectivity to the peers (this script doesn't manage keys).
#
# What it does:
#   1. Drops scripts into ~/bin and ~/scripts
#   2. Seeds ~/.agents/{peers.conf,self.conf} (only if absent — it won't
#      overwrite your existing membership)
#   3. Appends tmux hooks to ~/.tmux.conf (idempotent)
#   4. Installs the systemd --user resync timer (optional; skipped on macOS
#      or if systemd is unavailable)
#   5. Runs agent-discover to populate the registry
#
# Idempotent — re-run after upgrading the repo to roll out changes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
HERE_BIN="$REPO_ROOT/bin"
HERE_SCRIPTS="$REPO_ROOT/scripts"
HERE_TMUX="$REPO_ROOT/tmux"
HERE_SYSTEMD="$REPO_ROOT/systemd"
HERE_CONFIG="$REPO_ROOT/config"

DEST_BIN="${HOME}/bin"
DEST_SCRIPTS="${HOME}/scripts"
DEST_AGENTS="${HOME}/.agents"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

say "Installing agent-mesh from $REPO_ROOT"

# 1. Drop binaries
mkdir -p "$DEST_BIN" "$DEST_SCRIPTS" "$DEST_AGENTS"
install -m 0755 "$HERE_BIN/notify-pane"           "$DEST_BIN/notify-pane"
install -m 0755 "$HERE_BIN/agent-register-hook"   "$DEST_BIN/agent-register-hook"
install -m 0755 "$HERE_BIN/agent-discover"        "$DEST_BIN/agent-discover"
install -m 0755 "$HERE_SCRIPTS/sync-agent-registry.sh" "$DEST_SCRIPTS/sync-agent-registry.sh"
say "Installed scripts in $DEST_BIN/ + $DEST_SCRIPTS/"

# Make sure ~/bin is on PATH for interactive shells
if [ -f "$HOME/.bashrc" ] && ! grep -q 'PATH.*\$HOME/bin' "$HOME/.bashrc"; then
  echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
  say "Added $HOME/bin to PATH in ~/.bashrc"
fi

# 2. Seed config files (don't overwrite)
if [ ! -f "$DEST_AGENTS/peers.conf" ]; then
  cp "$HERE_CONFIG/peers.conf.example" "$DEST_AGENTS/peers.conf"
  warn "Wrote example $DEST_AGENTS/peers.conf — EDIT IT with your mesh's SSH aliases."
fi
if [ ! -f "$DEST_AGENTS/self.conf" ]; then
  echo "$(hostname -s)" > "$DEST_AGENTS/self.conf"
  warn "Wrote $DEST_AGENTS/self.conf with '$(hostname -s)'. Change it to match your peers.conf alias if different."
fi
touch "$DEST_AGENTS/local.toml"
say "Seeded $DEST_AGENTS/"

# 3. tmux hooks
if [ -f "$HOME/.tmux.conf" ] && grep -q 'agent-mesh' "$HOME/.tmux.conf"; then
  say "tmux hooks already present in ~/.tmux.conf"
else
  touch "$HOME/.tmux.conf"
  {
    echo ""
    echo "# === agent-mesh tmux hooks (managed) ==="
    cat "$HERE_TMUX/hooks.conf" | grep -v '^#' | grep -v '^$'
  } >> "$HOME/.tmux.conf"
  if command -v tmux >/dev/null 2>&1 && tmux info >/dev/null 2>&1; then
    tmux source-file "$HOME/.tmux.conf" 2>/dev/null || true
    say "Installed tmux hooks + reloaded live server"
  else
    say "Installed tmux hooks (no live tmux to reload — they'll load next start)"
  fi
fi

# 4. systemd user resync timer (optional)
# Make sure XDG_RUNTIME_DIR is set; without it, `systemctl --user` can't find
# the user bus even on systems where it's running.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if command -v systemctl >/dev/null 2>&1 && [ -d "$XDG_RUNTIME_DIR" ] \
   && systemctl --user is-system-running >/dev/null 2>&1 \
        || systemctl --user list-units --type=service --no-pager >/dev/null 2>&1; then
  UNITDIR="$HOME/.config/systemd/user"
  mkdir -p "$UNITDIR"
  install -m 0644 "$HERE_SYSTEMD/agent-resync.service" "$UNITDIR/agent-resync.service"
  install -m 0644 "$HERE_SYSTEMD/agent-resync.timer"   "$UNITDIR/agent-resync.timer"
  systemctl --user daemon-reload
  systemctl --user enable --now agent-resync.timer
  say "Installed + enabled agent-resync.timer (fires every 5 min)"
  # Linger isn't enabled by this script — that requires sudo. Mention it.
  if command -v loginctl >/dev/null 2>&1; then
    if ! loginctl show-user "$(id -un)" 2>/dev/null | grep -q 'Linger=yes'; then
      warn "Linger is not enabled — the timer stops when you log out."
      warn "Run as a privileged user: sudo loginctl enable-linger $(id -un)"
    fi
  fi
else
  warn "No systemd --user available; skipped resync timer."
  warn "On macOS / non-systemd hosts: add a cron line — */5 * * * * \$HOME/bin/agent-discover"
fi

# 5. First-run discovery
if command -v tmux >/dev/null 2>&1 && tmux info >/dev/null 2>&1; then
  "$DEST_BIN/agent-discover" || warn "discover failed; you can re-run it after seeding peers.conf"
fi

say "Done. Next steps:"
echo "  - edit ~/.agents/peers.conf with your mesh SSH aliases"
echo "  - edit ~/.agents/self.conf with this host's alias from that list"
echo "  - replicate peers.conf to every peer (see config/peers.conf.example)"
echo "  - on every peer, run ./install.sh"
echo "  - notify-pane --list   # confirm the registry"
