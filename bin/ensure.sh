#!/bin/sh
# Event hooks are invalidations; the package owns the reconciler and its daemon.
set -u

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P) || exit 0
labels="$script_dir/herdr-pane-labels"
[ -x "$labels" ] || exit 0

case "${1:-}" in
  --event)
    "$labels" --event >/dev/null 2>&1 || true
    ;;
  ''|--ensure-sweep-daemon)
    "$labels" --ensure-sweep-daemon >/dev/null 2>&1 || true
    ;;
esac

exit 0
