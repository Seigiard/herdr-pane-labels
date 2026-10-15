# Herdr Pane Labels

`seigi.pane-labels` keeps pane and tab labels, agent aliases, workspace origin,
and Git location/status metadata in step with complete Herdr snapshots. Events
invalidate a pass; the package-owned sweep daemon also repairs process and CWD
changes that do not produce an event.

## Requirements

- Herdr 0.8.2 or newer
- Bash 3.2 or newer, `jq`, `awk`, and `git`
- macOS or Linux
- [my-mac-setup](https://github.com/Seigiard/my-mac-setup) with
  `~/.local/lib/herdr-process.sh` at API 1

## Install

```bash
herdr plugin install Seigiard/herdr-pane-labels --ref v0.2.3 -y
herdr plugin enable seigi.pane-labels
```

Use a reviewed immutable release or commit in managed environments. The build
step installs the package's shell boundary at `~/.local/bin/herdr-pane-labels`
and its private runtime libraries at `~/.local/lib/herdr-pane-labels/`. The shared
`~/.local/lib/herdr-process.sh` library is owned by `my-mac-setup` and is never
installed or replaced by this package. A missing or incompatible shared library is
an installation error; run `chezmoi apply` to restore it. `herdr-child` and
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

## Agent checkout records

For agent panes, the package reads the current checkout from the following
input interface when the record is present and valid:

```text
${HERDR_WORKTREE_IDENTITY_STATE_DIR:-~/.cache/herdr-worktree-identity}/agent-cwd/<key>
```

`~` means `$HOME`. The `<key>` is the pane's `agent_session.value`, encoded
with the RFC 4648 section 5 base64url alphabet (`-` and `_`), without `=`
padding or line breaks. The record value is one line containing an absolute
directory path. Writers should replace the record atomically with a temporary
file and rename.

If the record is missing, empty, relative, or names a directory that does not
exist, the package falls back to the pane's `.cwd`. Non-agent panes always keep
their existing `.cwd` or `foreground_cwd` behavior.

## Development

Install Lefthook 2.2.1 or newer (`brew install lefthook` on macOS), then run
`make install-git-hooks` once per clone. Before commit, it runs `make lint` for
staged shell changes, including the extensionless CLI, and checks staged
whitespace. Use the ShellCheck version documented by the CI configuration.

```bash
make test
make lint
herdr plugin link "$PWD" --enabled
```

Behavior tests run from a clean temporary home and do not require this
dotfiles checkout.
