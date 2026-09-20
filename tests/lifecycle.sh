#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/herdr-pane-labels-lifecycle.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

write_herdr() {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/herdr" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$HERDR_LIFECYCLE_LOG"
case "$*" in
  'plugin install '* ) [ "${HERDR_FAIL_STEP:-}" = install ] && exit 17 ;;
  'plugin enable '* ) [ "${HERDR_FAIL_STEP:-}" = enable ] && exit 18 ;;
  'server reload-config') [ "${HERDR_FAIL_STEP:-}" = reload ] && exit 19 ;;
esac
exit 0
SH
  chmod 755 "$WORK/bin/herdr"
}

run_update() {
  local fail_step="${1:-}"
  : > "$WORK/calls"
  if HERDR_LIFECYCLE_LOG="$WORK/calls" HERDR_FAIL_STEP="$fail_step" \
    PATH="$WORK/bin:$PATH" HOME="$WORK/home" \
    HERDR_PANE_LABELS_REPOSITORY=Test/replacement \
    env -u HERDR_SOCKET_PATH "$ROOT/bin/update.sh"; then
    [ -z "$fail_step" ] || fail "update unexpectedly succeeded at $fail_step"
    return 0
  fi
  [ -n "$fail_step" ] || fail 'update unexpectedly failed'
  return 1
}

write_herdr

run_update
[ "$(cat "$WORK/calls")" = $'plugin install Test/replacement -y\nplugin enable seigi.pane-labels\nserver reload-config' ] || \
  fail 'successful update runs install, enable, and reload in order'
pass 'successful update runs the complete lifecycle'

if run_update install; then
  fail 'install failure is propagated'
fi
[ "$(cat "$WORK/calls")" = 'plugin install Test/replacement -y' ] || \
  fail 'install failure stops before activation'
pass 'install failure stops the lifecycle'

if run_update enable; then
  fail 'enable failure is propagated'
fi
[ "$(cat "$WORK/calls")" = $'plugin install Test/replacement -y\nplugin enable seigi.pane-labels' ] || \
  fail 'enable failure stops before reload'
pass 'enable failure stops before reload'

if run_update reload; then
  fail 'reload failure is propagated'
fi
[ "$(cat "$WORK/calls")" = $'plugin install Test/replacement -y\nplugin enable seigi.pane-labels\nserver reload-config' ] || \
  fail 'reload failure preserves the lifecycle boundary'
pass 'reload failure is propagated'
