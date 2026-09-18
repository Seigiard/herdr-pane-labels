#!/bin/sh
set -u

repo="${HERDR_PANE_LABELS_REPOSITORY:-Seigiard/herdr-pane-labels}"
herdr plugin install "$repo" -y || exit 1
herdr plugin enable seigi.pane-labels || exit 1
herdr server reload-config >/dev/null 2>&1 || true
printf 'updated %s\n' "$repo"
