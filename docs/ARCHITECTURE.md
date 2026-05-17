# agent-mesh — architecture notes

Internal design rationale for contributors. Reading order: README first.

## Layers

```
┌─────────────────────────────────────────────────────────────────────────┐
│  notify-pane (sender side)                                              │
│    1. lookup <agent> in registry.toml  →  host + tmux target            │
│    2. (optional) scp file to recipient's ~/.agent-inbox                 │
│    3. capture-pane on recipient → mid-prompt safety check               │
│    4. ssh peer 'tmux send-keys -l "[from … @ …] <body>"'                │
│    5. ssh peer 'tmux send-keys Enter'                                   │
└─────────────────────────────────────────────────────────────────────────┘
                                  │
                                  │ reads
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  ~/.agents/registry.toml  (per-host assembled view)                     │
│    written by sync-agent-registry.sh, never edited by hand              │
└─────────────────────────────────────────────────────────────────────────┘
                                  ▲
                                  │ assembles from
                                  │
┌─────────────────────────────────────────────────────────────────────────┐
│  ~/.agents/local.toml      (per-host fragment, this host's agents only) │
│    written by agent-register-hook                                       │
│    one [agents.<addr>] block per tmux window                            │
└─────────────────────────────────────────────────────────────────────────┘
                                  ▲
                                  │ called by
                                  │
┌─────────────────────────────────────────────────────────────────────────┐
│  tmux hooks: session-created/closed, window-linked/unlinked/renamed     │
└─────────────────────────────────────────────────────────────────────────┘
```

## Why per-window, not per-pane

Multi-pane tmux windows are typically split-view shells, not multi-agent
setups. When users run multiple agents in one tmux session, they almost
always use separate windows. Indexing by `<session>:<window>` covers the
real case cleanly; pane addressing would more than double the registry
size while addressing a use case nobody asked for.

The other reason: tmux's `send-keys -t session:window` is unambiguous;
`send-keys -t session:window.pane` requires knowing the pane id, which
isn't stable across splits/closes. Window indices are stable for the
session's lifetime.

## Why TOML

- Human-editable for the few fields a user might want to set by hand
- Trivially parseable with awk for the wrapper's tight inner loop
- Blocks are delimited (`[agents.X]`); easy to splice/strip with awk

JSON would force a real parser (jq) into every script's dependencies.
YAML's indentation is hostile to awk surgery.

## Why "fragment + assembled"

Two failure modes the fragment model neutralizes:

1. **Concurrent writes from independent hosts.** With a single shared
   `registry.toml`, two hosts each editing simultaneously would have to
   merge. With per-host `local.toml`, each host only writes its own slice
   and the assembled view is regenerated.

2. **Stale entries on offline peers.** If host B goes offline, its
   `local.toml` keeps being included in everyone else's `registry.toml`
   from the last successful pull. Notifications to B's agents fail at the
   ssh step (exit 4), not at the lookup step.

The cost is one extra file per host and a small assembly step.

## Why a sender tag

Without `[from <addr> @ <ts>] ...`, the receiving agent sees the
notification arrive as ordinary input. Three problems:

- It can't distinguish peer message from user typing
- It can't reply back ("who do I send to?")
- Logs lose attribution

A textual tag is the smallest possible solution. The ISO-8601 timestamp
makes log scraping deterministic; the address is the same string the
receiver would use to call `notify-pane` back. This is the same pattern
email used a generation ago — turns out to scale fine.

## Why a 5-minute timer when hooks are realtime

Hooks fire on tmux events. They can be missed when:

- tmux server isn't running yet at the moment the event happens (rare)
- The `run-shell -b` background launch fails silently
- The SSH that the hook's sync tries to reach is briefly down
- A peer's local.toml had a fragment-write at the wrong time

The 5-minute resync (`agent-discover` → `sync-agent-registry.sh`) is
content-stable when nothing changed; it costs three rsync round trips
to peers. Cheap insurance.

## Why `run-shell -b` in the hooks

Hooks run synchronously by default. If `agent-register-hook` (which does
file I/O plus a backgrounded sync) ran on the foreground hook thread,
every tmux session/window event would briefly stall the tmux server.
`-b` puts the command in the background; tmux returns immediately.

## Why the slug truncation at 40 chars

Window names get long ("Claude-Code-Backend-Migration-Phase-3"). Address
lookup is by string match; nothing breaks at length, but the registry
gets harder to skim past ~40 chars. The truncation is a soft hint to
keep names compact, not a security control.

## Why `--file` does scp, not inline

A 50 KB diff would shred the recipient's input buffer if sent through
`send-keys -l`. Inline is also lossy for any binary (terminal codes,
control characters get interpreted). The scp + path notification gets:

- Reliable transport (scp's existing semantics)
- No corruption (binary-safe)
- The receiver chooses how to handle it (Claude can `cat` it, `bat`,
  `wc`, … and decide based on type/size)

The cost is one extra ssh round trip. Worth it.

## Security model

`agent-mesh` is **not** a security boundary. It assumes:

- The set of hosts in `peers.conf` is administered by people who already
  trust each other at the SSH-key level
- Anyone with an authorized SSH key on a peer can deliver as any sender
  (the tag is informational, not signed)
- Local user accounts that can read `~/.agents/registry.toml` can
  enumerate every agent in the mesh

Within that trust boundary, the wrapper does basic hygiene:

- Mid-prompt safety check prevents accidental clobbering
- Address must exist in the registry (no arbitrary `send-keys` targets)
- Slug truncation prevents pathological long-name resource consumption
- File drops land in a per-sender directory (no traversal — the basename
  is taken from the local file, not a remote-supplied path)

For zero-trust multi-tenant setups, add an `@agent-allow` allowlist
option (in the roadmap) and a body-signing mode using age or minisign.

## Things deliberately not done

- **No central registry server.** Adds an operational dependency
  (process to keep up, port to firewall, schema migrations). The
  fragment model gives the same UX at the cost of a 5-minute eventual
  consistency budget.
- **No retries on send.** If a send fails, the operator (or calling
  script) gets exit code 4 immediately. Notifications are at-most-once,
  not at-least-once. If you need durability, store the body somewhere
  durable and notify a path.
- **No web UI.** A `notify-pane --list` + `--whoami` is enough to drive
  the system from scripts and agents. A web front-end is a different
  product.
- **No automatic peer pubkey distribution.** SSH is the trust anchor; if
  you can't get a key authorized on a peer, you don't trust that peer
  enough to be in the mesh.
