#!/bin/sh
# Event hooks are invalidations; the package owns the reconciler and its daemon.
set -u

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P) || exit 0
labels="$script_dir/herdr-pane-labels"
[ -x "$labels" ] || exit 0

run_engine() {
  output="$("$labels" "$@" 2>&1 >/dev/null)"
  status=$?
  case "$output" in
    *'herdr-pane-labels: herdr-process.sh API 1 required,'*'run chezmoi apply'*)
      if command -v herdr >/dev/null 2>&1; then
        herdr notification show "$output" >/dev/null 2>&1 || true
      fi
      ;;
  esac
  return "$status"
}

case "${1:-}" in
  --event)
    run_engine --event || true
    ;;
  ''|--ensure-sweep-daemon)
    run_engine --ensure-sweep-daemon || true
    ;;
esac

exit 0
