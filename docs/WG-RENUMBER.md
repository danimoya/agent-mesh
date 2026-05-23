# WireGuard mesh — renumber runbook

For when a peer's WireGuard address inside `10.10.0.0/24` needs to move
without disrupting the agent-mesh on top. Tested 2026-05-23 moving
`gpcca` from `10.10.0.1` → `10.10.0.4` to free `.1` for an Olares
install on dm26.

## Why this might happen

- A non-mesh service grabs a low-numbered IP in the same subnet
  (Kubernetes/Olares grabbing a gateway-style `.1`, a Docker bridge
  conflicting, kube-vip claiming the first IP, etc.).
- A peer's role changes and you want its address to reflect that.
- Subnet expansion — adding the 5th+ peer and you want the numbering
  to stay tidy.

The agent-mesh itself doesn't depend on specific IPs — it reaches peers
by SSH alias. Renumbering only touches the transport, not the agent
layer. Provided the SSH alias on every host is updated to the new IP,
the mesh keeps working without any `peers.conf` edit.

## Pre-flight check

Before touching anything, snapshot the current state on every host:

```bash
# On each host
sudo wg show wg0
sudo cat /etc/wireguard/wg0.conf
grep -rE '10\.10\.0\.<old>\b' /etc /home 2>/dev/null
```

Grep for every reference to the *old* address you intend to move. The
most common downstream surfaces:

- `/etc/wireguard/wg0.conf` — the peer's own `Address` line; every
  other peer's `AllowedIPs` for that peer.
- `~/.ssh/config` — `HostName 10.10.0.<old>` for both `<short>` and
  `<host>-wg` aliases.
- `~/.ssh/known_hosts` — stale host-key entry indexed by IP.
- `/etc/hosts` — sometimes a static mapping like `10.10.0.1 gpc001ca-wg`.
- Systemd unit files for SSH tunnels (`cb-tunnel-*.service`) — these
  usually reference SSH aliases, so they pick up new IPs automatically.
- Anything that hard-codes the IP: dashboard `.env`, firewalld zone
  config, application configs.

The agent-mesh `~/.agents/peers.conf` and `~/.agents/local.toml` should
*not* contain raw IPs. If they do, treat that as a bug separate from
the renumber.

## Order of operations

Critical: the renumber temporarily breaks the WG tunnel **to** the host
being renumbered, but only via WG — the public IP path stays up. So
the renumber step on the moving host **must** be reached via its public
SSH alias, never via the WG alias.

```
1. (on every OTHER peer)  patch peer-block AllowedIPs <old> → <new>
                          live-apply via `wg syncconf`
                          ⚠️  WG tunnel to the moving host is now down

2. (on the MOVING peer)   reached via PUBLIC IP, not via WG:
                          patch [Interface] Address <old> → <new>
                          live-apply with `ip addr del/add`
                          ✅  WG tunnel restored

3. (on every host)        patch SSH config HostName, /etc/hosts,
                          known_hosts, application configs
                          (host-key for the new IP needs `ssh-keyscan`
                          since stale `<old>` entry was removed)

4. Verify each peer can reach the moving host at <new> via WG.
```

Between steps 1 and 2 the moving host is unreachable over WG from the
other peers. Keep the window short — back-to-back in a single script
keeps it sub-second.

## Reference: live-apply commands

`wg syncconf` is the atomic-update path — peers reload their config
without bouncing the interface, so all other tunnels stay up. To
change the interface's own `Address`, use `ip addr del/add` directly
rather than `wg-quick down/up` (the latter teardown drops all tunnels
briefly).

```bash
# Peer-block edit on the OTHER hosts (does not bounce wg0)
sudo bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'

# Address edit on the MOVING host (replaces the IP on wg0 cleanly)
sudo ip addr del 10.10.0.<old>/24 dev wg0
sudo ip addr add 10.10.0.<new>/24 dev wg0
```

The kernel re-derives the connected route automatically — no manual
`ip route` work needed.

`wg syncconf` cannot be invoked through `sudo` with process
substitution as a non-root caller: `sudo wg syncconf wg0 <(sudo
wg-quick strip wg0)` fails because the inner `sudo`'s file descriptor
isn't visible to the outer `sudo`. Wrap both in a single `sudo bash
-c '…'` instead.

## Rollback

Every step writes a timestamped backup `/etc/wireguard/wg0.conf.bak-renumber-<ts>`
before editing. To revert on a host:

```bash
sudo cp /etc/wireguard/wg0.conf.bak-renumber-<ts> /etc/wireguard/wg0.conf
sudo bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'        # peer-block hosts
# OR
sudo ip addr del 10.10.0.<new>/24 dev wg0 && \
sudo ip addr add 10.10.0.<old>/24 dev wg0                   # moving host
```

Then reverse the SSH-config / `/etc/hosts` edits and re-`ssh-keyscan`.

## Reference script — gpcca: .1 → .4

The orchestration that performed the 2026-05-23 renumber. Parameters
are hard-coded; copy + adapt for the next move. Runs from the host
that has SSH aliases for all peers + the moving host's public IP
(`dm26` in this case).

```bash
#!/usr/bin/env bash
set -euo pipefail
TS=$(date +%s)

# 1. dm26: peer ca AllowedIPs .1 → .4
sudo cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak-renumber-${TS}
sudo sed -i 's|AllowedIPs = 10.10.0.1/32|AllowedIPs = 10.10.0.4/32|' /etc/wireguard/wg0.conf
sudo bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'

# 2. gpcgb: same edit
ssh gpc001gb-wg "sudo bash -c '
  cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak-renumber-${TS}
  sed -i \"s|AllowedIPs = 10.10.0.1/32|AllowedIPs = 10.10.0.4/32|\" /etc/wireguard/wg0.conf
  wg syncconf wg0 <(wg-quick strip wg0)
'"

# 3. gpcca: reached via PUBLIC alias gpc001ca, not gpc001ca-wg
ssh gpc001ca "sudo bash -c '
  cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak-renumber-${TS}
  sed -i \"s|Address = 10.10.0.1/24|Address = 10.10.0.4/24|\" /etc/wireguard/wg0.conf
  ip addr del 10.10.0.1/24 dev wg0
  ip addr add 10.10.0.4/24 dev wg0
'"

# 4. dm26 ssh config + known_hosts
sed -i 's|HostName 10.10.0.1|HostName 10.10.0.4|g' ~/.ssh/config
ssh-keygen -R 10.10.0.1 -f ~/.ssh/known_hosts >/dev/null 2>&1 || true
ssh-keyscan -t ed25519 -T 5 10.10.0.4 >> ~/.ssh/known_hosts 2>/dev/null

# 5. gpcgb: same SSH + hosts cleanup
ssh gpc001gb-wg "
  sudo sed -i 's|^10\\.10\\.0\\.1\\b|10.10.0.4|' /etc/hosts
  sed -i 's|HostName 10.10.0.1|HostName 10.10.0.4|g' ~/.ssh/config
  ssh-keygen -R 10.10.0.1 -f ~/.ssh/known_hosts >/dev/null 2>&1 || true
  ssh-keyscan -t ed25519 -T 5 10.10.0.4 >> ~/.ssh/known_hosts 2>/dev/null
"
```

## Current mesh addressing (2026-05-23)

| Host  | WG addr      | Public IP        | SSH aliases             |
|-------|--------------|------------------|-------------------------|
| dm26  | `10.10.0.3`  | `51.77.68.69`    | `dm26`                  |
| gpcgb | `10.10.0.2`  | `51.89.217.57`   | `gpc001gb`, `gpc001gb-wg`, `gpcgb` |
| gpcca | `10.10.0.4`  | `51.161.84.199`  | `gpc001ca`, `gpc001ca-wg`, `gpcca` |

`10.10.0.1` is intentionally left free for non-mesh infrastructure
(Olares / kube-vip / Docker bridge gateways) that wants to grab the
gateway-style first IP in the subnet.
