#!/usr/bin/env bash
# Inner half of a two-part probe: test 1103 in
# tests/bashunit/pane_labels_behavior_test.sh drives this file under a nested
# tests/lib/bashunit invocation and owns its oracle. Not run directly by
# `make test` -- the driver is the only supported entry point.
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

# The stub assets are per-file, not per-test: bashunit runs every test body in
# a subshell, so an export from hpl_setup_assets inside one test never reaches
# the next. These hooks run in the file shell, which is the only place the
# export survives -- without them each test rebuilds the stubs and leaks its
# own $BATS_TMPDIR/hpl-assets.* directory.
function set_up_before_script() { hpl_setup_assets; }

function tear_down_after_script() { hpl_teardown_assets; _bats_file_cleanup; }
