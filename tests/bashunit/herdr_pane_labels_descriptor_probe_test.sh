#!/usr/bin/env bash
# post-apply: excluded
# Inner half of a two-part probe: test_scripts_1103 in scripts_test.sh drives
# this file under a nested tests/lib/bashunit invocation and owns its oracle.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

load 'helpers/herdr_pane_labels'

teardown() {
  hpl_teardown
}

function test_herdr_pane_labels_descriptor_001_herdr_pane_labels_descriptor_child_probe() {
  _bats_test_init 1 'herdr-pane-labels descriptor child probe'
  [ -n "${HPL_DESCRIPTOR_PID_FILE:-}" ] || skip "internal descriptor probe"
  hpl_setup
  hpl_set_process_pane pane-1 tab-1 ws-1 term-1 /tmp old
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old"}'
  hpl_set_process_label pane-1 btop
  hpl_request_only
  : > "$HPL_WORK/block-herdr"
  env PATH="$HPL_STUB:/usr/bin:/bin" \
    HERDR_SOCKET_PATH="$HPL_DEFAULT_SOCKET" \
    HERDR_PANE_LABELS_STATE_DIR="$HPL_STATE" \
    HERDR_PANE_LABELS_GIT_BUDGET="$HPL_GIT_BUDGET" \
    bash "$HPL_ENGINE" --presentation-worker </dev/null >/dev/null 2>&1 &
  hpl_wait_for_file "$HPL_WORK/herdr-blocked"
  hpl_record_number \
    "$(hpl_namespace "$HPL_DEFAULT_SOCKET")/presentation.claim/owner" pid \
    > "$HPL_DESCRIPTOR_PID_FILE"
  run test -s "$HPL_DESCRIPTOR_PID_FILE"
  assert_success
}

function tear_down() { _bats_run_teardown; }

function tear_down_after_script() { _bats_file_cleanup; }
