# Herdr Pane Labels

`seigi.pane-labels` keeps pane and tab labels, agent aliases, workspace origin,
and Git location/status metadata in step with complete Herdr snapshots. Events
invalidate a pass; the package-owned sweep daemon also repairs process and CWD
changes that do not produce an event.

## Requirements

- Herdr 0.8.2 or newer
- Bash 3.2 or newer, `jq`, `awk`, and `git`
- macOS or Linux

## Install

```bash
herdr plugin install Seigiard/herdr-pane-labels --ref v0.2.3 -y
herdr plugin enable seigi.pane-labels
```

Use a reviewed immutable release or commit in managed environments. The build
step installs the package's shell boundary at `~/.local/bin/herdr-pane-labels`
and its private runtime libraries at `~/.local/lib`. `herdr-child` and
`herdr-peer-alias` use only this supported interface:

```bash
herdr-pane-labels --alias-candidates <seed>
```

Candidate selection is deterministic but not an atomic reservation. Callers
must still handle Herdr's `agent_name_taken` response after registration.

## Lifecycle

The package owns the ordinary runtime lifecycle through the Herdr actions
`start`, `stop`, `update`, and `diagnostics`. `update` stops the current daemon,
installs and enables the replacement, reloads configuration when a server is
running, performs a strict reconciliation, and restores daemon ownership on a
failed post-install check. `sweep` requests one immediate reconciliation. The
package preserves complete-snapshot validation, generation checks, target
identity revalidation, explicit metadata clearing, stale Git location handling,
and one active writer per socket.

The package does not own sidebar rows or personal presentation settings. Those
remain in the user's Herdr `config.toml`.

## Development

```bash
make test
make lint
herdr plugin link "$PWD" --enabled
```

Behavior tests run from a clean temporary home and do not require this
dotfiles checkout.
