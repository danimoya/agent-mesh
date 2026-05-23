# agent-mesh

**A tmux-backed direct-send channel between CLI agents — across panes, sessions, and hosts.**

`agent-mesh` lets Claude Code, Codex, your favorite REPL, or any other long-running CLI tool running inside a tmux pane *talk to its peers* — locally and across machines — without a daemon, a broker, or a browser. Each agent is auto-registered by tmux hooks, lives at a stable per-window address (`hub-build-agent-x`, `worker-1-claude-foo`, …), and is reachable through a single command:

```bash
notify-pane worker-1-claude-foo "tests green; pushing to main"
notify-pane worker-1-claude-foo --file /tmp/build-log.txt
```

It scales from "two Claudes on my laptop" to "six agents across three boxes" without changing the user experience.

---

## Why

Running multi-agent workflows already works the moment you give each agent its own tmux pane — you just can't talk *between* them. The usual workarounds are heavy:

| Workaround | Cost |
|---|---|
| Shared chat server / WebSocket hub | A service to run, secure, restart |
| File-drop polling (`tail -f mailbox`) | Latency, missed messages on restart, no cross-host story |
| Manual copy-paste between tmux panes | Tedious, error-prone, no automation |
| Custom protocols on top of SSH | Reinvented |

`agent-mesh` uses what's already on your boxes:

- **tmux** to find and address every pane
- **SSH** for cross-host transport
- **systemd-user / cron** for a 5-minute safety-net resync
- A small TOML address book that's kept in sync automatically

Total stack: ~400 lines of bash + a tmux conf snippet + 2 systemd unit files.

---

## What you get

**Direct delivery**
`send-keys` lands the message exactly where the agent reads input. No polling, no broker; the recipient sees the message arrive in real time, prefixed with a sender tag so it can tell a peer ping from a human typing.

**Auto-discovery**
Spin up a new tmux window or session. Within seconds it's in the registry on every host in the mesh, addressable by name. Kill the window — gone from the registry. No manual bookkeeping.

**Per-window precision**
A tmux session with 4 windows running 4 different Claude tasks is 4 distinct addresses (`hub-dev-build-agent`, `hub-dev-test-agent`, …), not one. No "I hope KanttBan is the active window."

**File drops, not just text**
`notify-pane peer --file ./diff.patch` ships the file to the recipient's `~/.agent-inbox/<sender>/<basename>` over scp and posts a one-line notification. The agent on the other side reads the file from its own filesystem — no chunking the payload through the input box.

**Mid-prompt safety**
Before delivery, the wrapper takes a `capture-pane` of the recipient. If the last line looks like a half-typed prompt, the send is refused with exit code 3 (overridable with `FORCE_SEND=1`).

**Mesh-replicated registry**
Every host carries the same `~/.agents/registry.toml`. Assembled symmetrically — each host writes its own slice (`local.toml`); a 5-minute systemd timer or the tmux hooks regenerate the merged view across the peers. There's no master; add a fourth host by editing one config file on each peer.

**Sender tag**
Every delivered message starts with `[from <agent-name> @ <ISO-ts>]`. Receivers can distinguish peer messages from user input, route replies back, and audit who said what when.

---

## Recommended use cases

1. **Multi-agent development pipelines** — one Claude in the KanttBan repo pings another Claude in HeliosDB-Nano: "schema changed at row 142, please verify the migration works." Both Claudes work in parallel without you switching panes.

2. **Distributed build coordination** — a build agent on a beefy build host finishes a release; pings the release-master agent on the public-edge host with `--file ./artifact.tar.gz`. The release-master picks it up, signs, uploads.

3. **Operator → agent messaging from a script** — cron job notices a deploy succeeded; runs `notify-pane prod-watcher "deploy ${tag} complete at $(date -u)"`. The on-call Claude sees it in its input stream.

4. **Cross-agent reviewers** — multiple Codex / Claude / human reviewers, each in their own tmux window, exchange notes on the same diff via the mesh.

5. **Long-running task hand-offs** — agent A finishes Phase 1, drops a state file to agent B, sends a one-line "Phase 1 done, your turn at `~/.agent-inbox/.../state.json`." Agent B picks up where A left off.

6. **Mixed-vendor agent pools** — works with anything that reads from stdin in a tmux pane. Claude Code, Codex, your in-house REPL, `gemini` CLI, `ollama run`, `aider`, an unattended `bash` waiting for a file path — same `notify-pane <addr> "..."` interface.

---

## How it works

```
┌─────────────────────────────────────────────────────────────┐
│  HOST A (alias: hub)                                        │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ tmux session "dev"                                   │   │
│  │   ┌────────────────┐  ┌────────────────┐             │   │
│  │   │ win 0  build   │  │ win 1  test    │ ← claude    │   │
│  │   └────────────────┘  └────────────────┘             │   │
│  └──────────────────────────────────────────────────────┘   │
│  ~/.agents/local.toml   (this host's blocks)                │
│  ~/.agents/registry.toml (assembled view, read by notify)   │
└─────────────────────────────────────────────────────────────┘
         ▲                                            ▲
         │ rsync local.toml fragments                 │
         ▼                                            ▼
┌─────────────────────────┐         ┌─────────────────────────┐
│  HOST B (worker-1)      │   …     │  HOST C (worker-2)      │
│  same scripts + state   │         │  same scripts + state   │
└─────────────────────────┘         └─────────────────────────┘

notify-pane worker-1-foo "hi"
   ├─ lookup worker-1-foo  → host=worker-1  target=foo:0
   ├─ ssh worker-1 'tmux send-keys -l "[from hub-dev-build @ <ts>] hi"'
   └─ ssh worker-1 'tmux send-keys Enter'
```

Auto-registration is driven by tmux hooks:

```tmux
set-hook -g session-created  "run-shell -b '~/bin/agent-register-hook on  #{session_name}'"
set-hook -g session-closed   "run-shell -b '~/bin/agent-register-hook off #{hook_session_name}'"
set-hook -g window-linked    "run-shell -b '~/bin/agent-register-hook on  #{session_name}'"
set-hook -g window-unlinked  "run-shell -b '~/bin/agent-register-hook on  #{hook_session_name}'"
set-hook -g window-renamed   "run-shell -b '~/bin/agent-register-hook on  #{session_name}'"
```

A systemd user timer fires `agent-discover` every 5 minutes as a safety net for missed hooks / network blips.

---

## Install

### Prerequisites

- bash 4+, tmux 3.2+, rsync, ssh (anything from the last decade)
- SSH set up so `ssh <peer-alias>` works without prompts between every pair of hosts in the mesh (bidirectional). Distinct keypairs per host strongly recommended.
- (Optional) systemd-user for the 5-minute resync timer; cron works on macOS / non-systemd hosts.

### One-shot

On every host in the mesh:

```bash
git clone https://github.com/danimoya/agent-mesh ~/agent-mesh
cd ~/agent-mesh
./install.sh
```

`install.sh` is idempotent — re-run after `git pull` to roll out changes.

### Configure the mesh

```bash
# Edit on one host, then replicate to every peer.
$EDITOR ~/.agents/peers.conf       # one SSH alias per line
echo hub > ~/.agents/self.conf     # this host's alias from peers.conf

# Push peers.conf to every other host
for p in $(grep -v '^#' ~/.agents/peers.conf | grep -v "$(cat ~/.agents/self.conf)"); do
  scp ~/.agents/peers.conf "$p:~/.agents/peers.conf"
done

# Trigger first sync
~/scripts/sync-agent-registry.sh
notify-pane --list   # should show every window across every host
```

---

## Usage

### Send a text message

```bash
notify-pane <agent> "<body>"
```

### Send a file (with optional text)

```bash
notify-pane <agent> --file ./report.md
notify-pane <agent> --file ./report.md "section 3 needs your review"
```

### List + introspect

```bash
notify-pane --list      # every registered address, mesh-wide
notify-pane --whoami    # this shell's sender id
```

### Set role/scope on a window

The hook fills role/scope with placeholders. Make them meaningful:

```bash
tmux set-option -w -t dev:0 @agent-role  "Test runner — Jest + Playwright"
tmux set-option -w -t dev:0 @agent-scope "Watches ./src for changes, runs full suite, reports red"
~/bin/agent-register-hook on dev    # re-register dev session's windows
```

If a window doesn't have `-w` options, it inherits the session-level `@agent-role`/`@agent-scope` (set without `-w`). Useful: tag the whole session "build infrastructure," then specialize per window.

### Send from inside a busy pane

Most of your panes will be busy with the agent itself; there's no shell to drop into. Use `tmux run-shell -t <session>:<window>`:

```bash
tmux run-shell -t dev:1 "AGENT_NAME='hub-dev-tests' ~/bin/notify-pane hub-dev-build 'tests green'"
```

`run-shell -b` runs the command in a backgrounded shell with the window's tmux context — no need to interrupt the agent in the foreground.

---

## Exit codes

| code | meaning |
|---|---|
| 0 | delivered |
| 1 | usage / missing args / unreadable `--file` |
| 2 | unknown agent (not in `~/.agents/registry.toml`) |
| 3 | recipient looks mid-prompt; refused (override with `FORCE_SEND=1`) |
| 4 | ssh / tmux failure on the wire |

---

## Files & directories

```
~/bin/notify-pane                           # the wrapper
~/bin/agent-register-hook                   # tmux hook handler (on/off <session>)
~/bin/agent-discover                        # one-shot session+window sweep
~/scripts/sync-agent-registry.sh            # peer-fragment assembly + push
~/.agents/peers.conf                        # mesh membership (you edit)
~/.agents/self.conf                         # this host's alias (you edit)
~/.agents/local.toml                        # this host's slice (auto)
~/.agents/registry.toml                     # assembled view (read by notify)
~/.agent-inbox/<sender>/<file>              # files dropped to this host
~/.config/systemd/user/agent-resync.timer   # 5-min safety net (optional)
~/.tmux.conf                                # appended with the five hooks
```

---

## Limitations / caveats

- **Splits (multiple panes inside one window) are NOT individually addressed.** If you split, only the window-active pane sees `send-keys`. Use separate windows per agent.
- **`|` in window names breaks the parser** (it's the format separator). Use letters/digits/`-`/`_`.
- **Renaming a window** changes its slug. Anyone holding the old address misses the next message. Reconcile with `notify-pane --list` after renames.
- **The sender tag is informational**, not authenticated — SSH is what gates *who* can deliver. If you give an untrusted user SSH to a host, they can `notify-pane` as anyone.
- **`registry.toml` is replicated**, so it's only as fresh as the last sync. The 5-min timer + hook-driven updates usually keep it within seconds of live; on a network split it can stale until reachability returns.
- **No reply routing** at the protocol level. Receivers parse the sender tag if they want to reply (just `notify-pane <sender-slug> "..."`).

---

## Troubleshooting

### Messages eaten by a stuck Claude Code dialog (`/config`, `/help`, `/permissions`)
A recipient pane that's currently showing a Claude Code modal — e.g. after a fleet-wide `/config reload` — captures the next `notify-pane` delivery into the dialog's search box instead of submitting it as a new prompt to the agent. As of [#2](https://github.com/danimoya/agent-mesh/issues/2), `notify-pane` detects `/config`, `/help`, and `/permissions` modals in the captured pane and sends `Escape` to dismiss them before delivering the body. Set `SKIP_DISMISS=1` to opt out.

If you hit a Claude Code modal that isn't auto-dismissed: add its detection pattern to `bin/notify-pane` (search for `modal_detected`), or send `tmux send-keys -t <target> Escape` manually before retrying.

### "Connection closed by invalid user … [preauth]" — Alpine + musl
If you're building `agent-mesh` into an Alpine-based container and SSH between peers fails preauth with `invalid user <name>` (despite the user being in `/etc/passwd` and the container running as them), it's a known interaction between musl libc and OpenSSH's privsep sandbox. Switch the base image to a glibc-based one (Debian / Ubuntu / Rocky / Fedora …) or add `UsePAM yes` to `sshd_config`. Full investigation, attempts, and the two-commit fix in **[#1](https://github.com/danimoya/agent-mesh/issues/1)**.

Real `agent-mesh` deployments on the canonical distros are not affected; this only bites if you containerize on Alpine.

---

## Roadmap (open to PRs)

- [ ] First-class pane addressing (split-view support) — `<host>-<session>-<window>-<pane-idx>`
- [ ] Optional encrypted body via age / gpg (for shared-host setups)
- [ ] `--reply-to <addr>` convenience flag that just rewrites the sender tag
- [ ] Per-agent ACLs (allowlist of senders) read from `@agent-allow` tmux option
- [ ] Cron-mode installer for macOS / non-systemd hosts

---

## License

Apache 2.0. See [LICENSE](./LICENSE).
