#!/bin/sh
set -u

command -v herdr-pane-labels >/dev/null 2>&1 || exit 1
exec herdr-pane-labels --stop
