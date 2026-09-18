#!/bin/sh
set -u

if command -v herdr-pane-labels >/dev/null 2>&1; then
  herdr-pane-labels --diagnostics
else
  printf 'herdr-pane-labels: installed CLI shim is missing\n' >&2
  exit 1
fi
