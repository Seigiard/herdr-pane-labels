#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENGINE="$ROOT/bin/herdr-pane-labels"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/herdr-pane-labels-reconcile.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

write_snapshot() {
  local complete="$1" label="${2:-old}"
  jq -cn --argjson complete "$complete" --arg label "$label" \
    '{id:"cli:api:snapshot",result:{type:"session_snapshot",snapshot:{
      complete:$complete, protocol:20,
      panes:[{pane_id:"pane-1",terminal_id:"term-1",tab_id:"tab-1",workspace_id:"ws-1",agent:"claude",revision:1,label:$label,tokens:{}}],
      tabs:[{tab_id:"tab-1",workspace_id:"ws-1",label:"old-tab"}],
      agents:[{pane_id:"pane-1",terminal_id:"term-1",tab_id:"tab-1",workspace_id:"ws-1",agent:"claude",revision:1,state_change_seq:1,name:"red-wolf"}],
      workspaces:[{workspace_id:"ws-1",label:"repo",tokens:{}}],layouts:[]}}}' \
    | if [ "$complete" = true ]; then cat; else jq 'del(.result.snapshot.tabs,.result.snapshot.agents,.result.snapshot.layouts,.result.snapshot.workspaces)'; fi \
    > "$WORK/snapshot.json"
}

write_herdr() {
  cat > "$WORK/herdr" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "api snapshot") cat "$HERDR_TEST_WORK/snapshot.json" ;;
  "pane get pane-1")
    jq '{result:{pane:.result.snapshot.panes[0]}}' "$HERDR_TEST_WORK/snapshot.json"
    ;;
  "pane rename pane-1 "*)
    printf '%s\n' "$*" >> "$HERDR_TEST_WORK/writes"
    ;;
  "tab get tab-1")
    jq '{result:{tab:.result.snapshot.tabs[0]}}' "$HERDR_TEST_WORK/snapshot.json"
    ;;
  "tab rename tab-1 "*)
    printf '%s\n' "$*" >> "$HERDR_TEST_WORK/writes"
    ;;
  *)
    printf '%s\n' "$*" >> "$HERDR_TEST_WORK/writes"
    ;;
esac
SH
  chmod 755 "$WORK/herdr"
}

test_complete_snapshot_and_conflict_retry() {
  write_snapshot true
  write_herdr
  : > "$WORK/writes"
  if ! HOME="$WORK/home" PATH="$WORK:$PATH" HERDR_TEST_WORK="$WORK" \
    HERDR_SOCKET_PATH="$WORK/session.sock" HERDR_PANE_LABELS_TEST_NO_PRESENTATION=1 \
    "$ENGINE" --sweep; then
    fail 'complete snapshot reconciles successfully'
  fi
  grep -q 'pane rename pane-1 cc:red-wolf' "$WORK/writes" || \
    fail 'pane label follows the complete snapshot'
  pass 'complete snapshot reconciles safely'
}

test_incomplete_snapshot_is_rejected() {
  write_snapshot false
  write_herdr
  : > "$WORK/writes"
  if HOME="$WORK/home" PATH="$WORK:$PATH" HERDR_TEST_WORK="$WORK" \
    HERDR_SOCKET_PATH="$WORK/session.sock" HERDR_PANE_LABELS_TEST_NO_PRESENTATION=1 \
    "$ENGINE" --sweep; then
    fail 'incomplete snapshot is rejected'
  fi
  [ ! -s "$WORK/writes" ] || fail 'incomplete snapshot performs no writes'
  pass 'incomplete snapshot is rejected'
}

test_complete_snapshot_and_conflict_retry
test_incomplete_snapshot_is_rejected
