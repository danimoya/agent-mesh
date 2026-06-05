# Repository Guidelines

## Project Structure & Module Organization

`agent-mesh` is a Bash-based tmux/SSH messaging tool. Runtime commands live in `bin/`: `notify-pane`, `agent-register-hook`, and `agent-discover`. Shared maintenance logic is in `scripts/`, currently `sync-agent-registry.sh`. Install-time assets are split by target: `config/` contains example `~/.agents` files, `tmux/` contains hook snippets, and `systemd/` contains the optional user timer/service. CI-only Docker and smoke-test files live in `ci/`. Architecture notes and runbooks belong in `docs/`.

## Build, Test, and Development Commands

- `./install.sh`: installs scripts into `~/bin` and `~/scripts`, seeds `~/.agents`, appends tmux hooks, and optionally enables the user timer.
- `shellcheck -e SC1091 bin/notify-pane bin/agent-register-hook bin/agent-discover scripts/sync-agent-registry.sh install.sh`: matches the CI lint job.
- `~/bin/agent-discover`: rebuilds the local registry after changing tmux sessions, windows, or config.
- `~/bin/notify-pane --list`: verifies registered agent addresses.
- `cd ci && docker compose build && docker compose up --abort-on-container-exit --exit-code-from alpha`: runs the two-host SSH/tmux smoke test used by CI.

## Coding Style & Naming Conventions

Write portable Bash with `#!/usr/bin/env bash` and `set -euo pipefail`. Use two-space indentation in shell blocks, quote variable expansions, and prefer small helper functions for repeated command sequences. Keep user-facing command names lowercase with hyphens, for example `notify-pane` and `agent-register-hook`. Agent addresses are slug-like: `<host>-<session>-<window>`, using letters, digits, `_`, and `-`; avoid `|` because registry parsing uses it as a separator.

## Testing Guidelines

Run ShellCheck before submitting script changes. For behavior changes, add or update smoke coverage in `.github/workflows/ci.yml` or the `ci/alpha.sh` and `ci/beta.sh` scripts. Preserve tests for text delivery, `--file` delivery, registry population, and window rename re-registration. Prefer deterministic payload markers such as `ci-test-payload-12345` so pane captures can assert exact delivery.

## Commit & Pull Request Guidelines

The history uses short, imperative subjects with optional prefixes such as `ci:`, `docs:`, `README:`, or component names like `notify-pane:`. Keep the first line specific, for example `ci: harden two-host smoke test`. Pull requests should explain the behavior change, list manual or CI tests run, link relevant issues, and include screenshots or pane captures only when output formatting changes.

## Security & Configuration Tips

Do not commit real `~/.agents` state, SSH keys, or host-specific secrets. Keep examples in `config/*.example`. Treat the sender tag as informational; SSH access is the actual trust boundary.
