#!/bin/sh
# The Herdr package runs this from its checked-out root after install/update.
# The shim is the supported shell boundary for child and peer alias consumers.
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P) || exit 1
bin_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
lib_dir="${XDG_LIB_HOME:-$HOME/.local/lib}"
mkdir -p "$bin_dir" "$lib_dir" || exit 1
install -m 755 "$root/bin/herdr-pane-labels" "$bin_dir/herdr-pane-labels" || exit 1
install -m 644 "$root/lib/herdr-aliases.sh" "$lib_dir/herdr-aliases.sh" || exit 1
install -m 644 "$root/lib/herdr-process.sh" "$lib_dir/herdr-process.sh" || exit 1
printf '%s\n' '0.2.2' > "$lib_dir/herdr-pane-labels.version" || exit 1
