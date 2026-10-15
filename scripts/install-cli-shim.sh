#!/bin/sh
# The Herdr package runs this from its checked-out root after install/update.
# The shim is the supported shell boundary for child and peer alias consumers.
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P) || exit 1
bin_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
lib_dir="$HOME/.local/lib"
package_lib_dir="$lib_dir/herdr-pane-labels"
mkdir -p "$bin_dir" "$package_lib_dir" || exit 1
install -m 755 "$root/bin/herdr-pane-labels" "$bin_dir/herdr-pane-labels" || exit 1
install -m 644 "$root/lib/herdr-aliases.sh" "$package_lib_dir/herdr-aliases.sh" || exit 1
printf '%s\n' '0.2.3' > "$package_lib_dir/herdr-pane-labels.version" || exit 1
