#!/bin/sh
set -u

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P) || exit 0
labels="$script_dir/herdr-pane-labels"
[ -x "$labels" ] || exit 0
"$labels" --sweep >/dev/null 2>&1 || true
exit 0
