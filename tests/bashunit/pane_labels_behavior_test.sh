#!/usr/bin/env bash
# Standalone behavioral coverage moved from the dotfiles-owned implementation.
source "$(dirname "${BASH_SOURCE[0]}")/test-dsl.bash"
_bats_file_init "${BASH_SOURCE[0]}"

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HERDR_ALIASES="$SOURCE_ROOT/lib/herdr-aliases.sh"
export SOURCE_ROOT
export HERDR_ALIASES
load 'helpers/herdr_pane_labels'

setup() {
  unset HERDR_PANE_LABELS_TEST_CRASH_AFTER
  unset HERDR_PANE_LABELS_TEST_NO_PRESENTATION
  unset HERDR_PANE_LABELS_TEST_NO_DAEMON
  unset HERDR_PANE_LABELS_TEST_PAUSE_BEFORE_RELEASE
  unset HERDR_PANE_LABELS_TEST_NOW_SEQ
  unset HERDR_PANE_LABELS_TEST_DIGEST_FILE
  unset HERDR_PANE_LABELS_TEST_TRACE_FILE
  unset HERDR_PANE_LABELS_TEST_LOCATION_BARRIER
  unset HERDR_PANE_LABELS_TEST_LOCATION_BARRIER_COUNT
  unset HERDR_PANE_LABELS_TEST_LOCATION_BARRIER_RELEASE
  unset HERDR_PANE_LABELS_STRICT_SWEEP
  unset HERDR_PANE_LABELS_LOCK_ATTEMPTS
  unset HERDR_ALIAS_TEST_SEED
}

teardown() {
  hpl_teardown
}

# herdr-pane-labels engine
# ===========================================

function test_scripts_1103_herdr_pane_labels_descriptor_probe_closes_worker_pipes() {
  _bats_test_init 1103 'herdr-pane-labels descriptor probe closes detached worker pipes'
  local probe_file="$BATS_TEST_DIRNAME/bashunit/herdr_pane_labels_descriptor_probe_test.sh"
  local release_file="$BATS_TEST_TMPDIR/release-herdr"
  local pid_file="$BATS_TEST_TMPDIR/descriptor-worker.pid"
  local blocked_pid_file="$BATS_TEST_TMPDIR/blocked-herdr.pid"
  assert_file_exists "$probe_file"

  run env HPL_DESCRIPTOR_RELEASE_FILE="$release_file" \
    HPL_DESCRIPTOR_PID_FILE="$pid_file" \
    HPL_DESCRIPTOR_BLOCKED_PID_FILE="$blocked_pid_file" \
    HPL_BLOCKED_HERDR_POLLS="$HPL_BLOCKED_HERDR_POLLS" \
    TMPDIR="$BATS_TEST_TMPDIR" \
    BASHUNIT_BIN="$BATS_TEST_DIRNAME/lib/bashunit" PROBE_FILE="$probe_file" \
    python3 - <<'PY'
import os
from pathlib import Path
import select
import signal
import subprocess
import time

release = Path(os.environ["HPL_DESCRIPTOR_RELEASE_FILE"])
worker_file = Path(os.environ["HPL_DESCRIPTOR_PID_FILE"])
blocked_file = Path(os.environ["HPL_DESCRIPTOR_BLOCKED_PID_FILE"])
gave_up = Path(str(blocked_file) + ".gave-up")
control_read, control_write = os.pipe()
os.set_inheritable(control_write, True)
proc = subprocess.Popen(
    [os.environ["BASHUNIT_BIN"], os.environ["PROBE_FILE"], "--no-parallel"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=os.environ.copy(),
    pass_fds=(control_write,),
)
os.close(control_write)

def read_pid(path):
    try:
        return int(path.read_text().strip())
    except (FileNotFoundError, ValueError):
        return None

try:
    deadline = time.monotonic() + int(os.environ["HPL_INNER_BATS_PROGRESS_SECONDS"])
    worker_pid = None
    while worker_pid is None and time.monotonic() < deadline:
        worker_pid = read_pid(worker_file)
        if worker_pid is None:
            if proc.poll() is not None:
                raise AssertionError("nested probe exited before publishing its worker pid")
            time.sleep(0.02)
    if worker_pid is None:
        raise AssertionError("nested probe did not publish its worker pid")

    blocked_pid = read_pid(blocked_file)
    if gave_up.exists() or blocked_pid is None:
        raise AssertionError("blocked Herdr fixture gave up before the EOF check")
    os.kill(blocked_pid, 0)

    try:
        stdout, stderr = proc.communicate(timeout=int(os.environ["HPL_INNER_BATS_EXIT_SECONDS"]))
    except subprocess.TimeoutExpired as error:
        raise AssertionError("detached worker retained the nested runner output pipes") from error
    if proc.returncode != 0:
        raise AssertionError(f"nested probe failed: {stderr}\n{stdout}")
    if "1 passed" not in stdout:
        raise AssertionError(f"nested probe did not report its passing test: {stdout}")
    readable, _, _ = select.select([control_read], [], [], 1)
    if not readable or os.read(control_read, 1) != b"":
        raise AssertionError("detached worker retained the inherited control pipe")

    release.touch()
    for _ in range(500):
        try:
            os.kill(worker_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.01)
    else:
        os.kill(worker_pid, signal.SIGKILL)
        raise AssertionError("detached worker survived its release")
finally:
    os.close(control_read)
    release.touch()
    if proc.poll() is None:
        proc.kill()
        proc.wait()
PY
  assert_success
}

function test_scripts_1104_herdr_pane_labels_harness_fresh_reads_follow_pane_and_t() {
  _bats_test_init 1104 'herdr-pane-labels harness fresh reads follow pane and tab mutations'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" \
    '{"pane_id":"pane-1","tab_id":"tab-1","terminal_id":"term-1","cwd":"/repo/one","label":"old","tokens":{}}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" \
    '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-tab"}'

  run hpl_socket_run "$HPL_DEFAULT_SOCKET" pane rename pane-1 new
  assert_success
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" tab rename tab-1 new-tab
  assert_success
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" pane get pane-1
  assert_success
  assert_output --partial '"label":"new"'
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" tab get tab-1
  assert_success
  assert_output --partial '"label":"new-tab"'
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" api snapshot
  assert_success
  assert_output --partial '"tabs":[{"tab_id":"tab-1"'

  hpl_snapshot_complete "$HPL_DEFAULT_SOCKET" false
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" api snapshot
  assert_success
  refute_output --partial '"tabs"'
}

function test_scripts_1105_herdr_pane_labels_harness_isolates_colliding_sanitized_() {
  _bats_test_init 1105 'herdr-pane-labels harness isolates colliding sanitized socket names'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  # a-b.sock and a_b.sock collided under the retired sanitized-name scheme;
  # exact socket paths must now map to separate harness directories.
  local socket_one="$HPL_WORK/a-b.sock" socket_two="$HPL_WORK/a_b.sock"
  local dir_one dir_two
  dir_one="$(hpl_socket_dir "$socket_one")"
  dir_two="$(hpl_socket_dir "$socket_two")"
  run test "$dir_one" != "$dir_two"
  assert_success
  hpl_set_pane "$socket_one" '{"pane_id":"pane-1","label":"one","tokens":{}}'
  hpl_set_pane "$socket_two" '{"pane_id":"pane-1","label":"two","tokens":{}}'

  run hpl_socket_run "$socket_one" api snapshot
  assert_success
  assert_output --partial '"label":"one"'
  run hpl_socket_run "$socket_two" api snapshot
  assert_success
  assert_output --partial '"label":"two"'
  hpl_wait_for_socket_call "$dir_one" 1
  hpl_wait_for_socket_completion "$dir_one" 1
  hpl_wait_for_socket_call "$dir_two" 1
  hpl_wait_for_socket_completion "$dir_two" 1
  # A failing mkdir trips the ERR trap, so this probes both independent locks
  # parents without restating the resulting directory existence.
  mkdir "$dir_one/locks/held" "$dir_two/locks/held"
  assert_equal "$(wc -l < "$(hpl_socket_log "$socket_one")" | tr -d ' ')" 1
  assert_equal "$(wc -l < "$(hpl_socket_log "$socket_two")" | tr -d ' ')" 1
}

function test_scripts_1106_herdr_pane_labels_harness_applies_source_metadata_seque() {
  _bats_test_init 1106 'herdr-pane-labels harness applies source metadata sequence and clear rules'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","label":"agent","tokens":{}}'

  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane report-metadata --source location pane-1 --seq 2 --token repo=alpha
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane report-metadata --source foreign pane-1 --seq 1 --token foreign=review
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane report-metadata --source location pane-1 --seq 1 --clear-token repo
  local state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.metadata["pane-1"].location.tokens.repo' "$state")" alpha
  assert_equal "$(jq -r '.panes[0].tokens.foreign' "$state")" review

  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane report-metadata --source location pane-1 --seq 3 --clear-token repo
  assert_equal "$(jq -r '.metadata["pane-1"].location.seq' "$state")" 3
  assert_equal "$(jq -r '.metadata["pane-1"].location.tokens.repo // "cleared"' "$state")" cleared
  assert_equal "$(jq -r '.panes[0].tokens.repo // "cleared"' "$state")" cleared
  assert_equal "$(jq -r '.panes[0].tokens.foreign' "$state")" review
}

function test_scripts_1107_herdr_pane_labels_harness_models_target_loss_move_reuse() {
  _bats_test_init 1107 'herdr-pane-labels harness models target loss move reuse and final-read change'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" \
    '{"pane_id":"pane-1","tab_id":"tab-1","terminal_id":"term-1","cwd":"/repo/one","label":"one","tokens":{}}'
  hpl_remove_pane "$HPL_DEFAULT_SOCKET" pane-1
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" pane get pane-1
  assert_failure
  run grep -q '^pane rename' "$HPL_LOG"
  assert_failure

  hpl_set_pane "$HPL_DEFAULT_SOCKET" \
    '{"pane_id":"pane-1","tab_id":"tab-2","terminal_id":"term-2","cwd":"/repo/two","label":"two","tokens":{}}'
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" pane get pane-1
  assert_success
  assert_output --partial '"tab_id":"tab-2"'
  assert_output --partial '"terminal_id":"term-2"'

  local state next_state
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  next_state="$(jq -c '.panes[0].terminal_id = "term-3" | .panes[0].cwd = "/repo/three" | .panes[0].label = "three"' "$state")"
  hpl_after_next_call_state "$HPL_DEFAULT_SOCKET" "$next_state"
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" pane get pane-1
  assert_success
  assert_output --partial '"terminal_id":"term-2"'
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane rename pane-1 stale-write
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" pane get pane-1
  assert_success
  assert_output --partial '"terminal_id":"term-3"'
  assert_output --partial '"label":"stale-write"'
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane rename pane-1 converged
  run hpl_socket_run "$HPL_DEFAULT_SOCKET" pane get pane-1
  assert_success
  assert_output --partial '"label":"converged"'
}

function test_scripts_1108_herdr_pane_labels_assigns_distinct_aliases_and_renders_() {
  _bats_test_init 1108 'herdr-pane-labels assigns distinct aliases and renders known and fallback runtime prefixes'
  command -v jq >/dev/null || skip "jq not available"
  source "$HERDR_ALIASES"
  hpl_setup
  export HERDR_ALIAS_TEST_SEED=u2-prefixes
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude review-auth
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-2 tab-1 ws-1 term-2 opencode CORE-42
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-3 tab-1 ws-1 term-3 pi consult-pi
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-4 tab-1 ws-1 term-4 codex manual-name
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-5 tab-1 ws-1 term-5 gemini tracker-name

  hpl_request_only
  hpl_presentation_run

  local state names aliases alias
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  names="$(jq -r '.agents[].name' "$state")"
  aliases=0
  while IFS= read -r alias; do
    herdr_alias_in_pool "$alias"
    aliases=$((aliases + 1))
  done <<EOF
$names
EOF
  assert_equal "$aliases" 5
  assert_equal "$(printf '%s\n' "$names" | sort -u | wc -l | tr -d ' ')" 5
  assert_equal "$(jq -r '[.panes[].label] | join("|")' "$state")" \
    "cc:$(jq -r '.agents[] | select(.pane_id == "pane-1").name' "$state")|oc:$(jq -r '.agents[] | select(.pane_id == "pane-2").name' "$state")|pi:$(jq -r '.agents[] | select(.pane_id == "pane-3").name' "$state")|cx:$(jq -r '.agents[] | select(.pane_id == "pane-4").name' "$state")|g:$(jq -r '.agents[] | select(.pane_id == "pane-5").name' "$state")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "$(jq -r '[.panes[].label] | join(" · ")' "$state")"
  unset HERDR_ALIAS_TEST_SEED
}

function test_scripts_1109_herdr_pane_labels_preserves_a_unique_pool_alias_across_() {
  _bats_test_init 1109 'herdr-pane-labels preserves a unique pool alias across events and sweeps'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf
  hpl_sweep_run --sweep
  assert_equal "$(jq -r '.agents[0].name' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" red-wolf
  assert_equal "$(jq -r '.panes[0].label' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" cc:red-wolf

  : > "$HPL_LOG"
  hpl_sweep_run --sweep
  run grep -E '^(agent|pane|tab) rename' "$HPL_LOG"
  assert_failure
}

function test_scripts_1110_herdr_pane_labels_accepts_independent_pane_and_agent_re() {
  _bats_test_init 1110 'herdr-pane-labels accepts independent pane and agent revisions in a complete join'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf
  hpl_transform_state "$HPL_DEFAULT_SOCKET" '.panes[0].revision = 7 | .agents[0].revision = 42'

  hpl_sweep_run --sweep

  local state
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].revision' "$state")" 7
  assert_equal "$(jq -r '.agents[0].revision' "$state")" 42
  assert_equal "$(jq -r '.panes[0].label' "$state")" cc:red-wolf
  assert_equal "$(jq -r '.tabs[0].label' "$state")" cc:red-wolf
  run grep '^agent rename' "$HPL_LOG"
  assert_failure
}

function test_scripts_1111_herdr_pane_labels_rejects_unsafe_snapshot_strings_befor() {
  _bats_test_init 1111 'herdr-pane-labels rejects unsafe snapshot strings before every write'
  command -v jq >/dev/null || skip "jq not available"
  local mutation namespace pending completed
  for mutation in \
    '.panes[0].pane_id = "bad\npane" | .agents[0].pane_id = "bad\npane"' \
    '.panes[0].terminal_id = "bad\u001fterminal" | .agents[0].terminal_id = "bad\u001fterminal"' \
    '.panes[0].tab_id = "bad\ntab" | .agents[0].tab_id = "bad\ntab" | .tabs[0].tab_id = "bad\ntab"' \
    '.panes[0].workspace_id = "bad\u001fworkspace" | .agents[0].workspace_id = "bad\u001fworkspace" | .tabs[0].workspace_id = "bad\u001fworkspace" | .workspaces[0].workspace_id = "bad\u001fworkspace"' \
    '.panes[0].agent = "bad\nruntime" | .agents[0].agent = "bad\nruntime"' \
    '.panes[0].label = "bad\u001flabel"' \
    '.panes[0].tokens = {repo:"bad\nrepo",worktree:"bad\u001fworktree",branch:"bad\nbranch",location_status:"bad\u001fstatus",git_ref:"bad\nref",location_label:"bad\u001flocation"}' \
    '.tabs[0].label = "bad\nlabel"' \
    '.workspaces[0].label = "bad\u001flabel"' \
    '.agents[0].name = "bad\nalias"' \
    '({source:"bad\u001fsource",agent:"claude",kind:"id",value:"session"}) as $session | .panes[0].agent_session = $session | .agents[0].agent_session = $session'; do
    hpl_setup
    hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf
    hpl_transform_state "$HPL_DEFAULT_SOCKET" "$mutation"
    run hpl_sweep_run --sweep
    assert_failure

    run grep -E '^(agent|pane|tab) rename|^pane report-metadata' "$HPL_LOG"
    assert_failure
    namespace="$(hpl_namespace "$HPL_DEFAULT_SOCKET")"
    pending="$(hpl_record_number "$namespace/reconcile.state" pending_generation)"
    completed="$(hpl_record_number "$namespace/reconcile.state" completed_generation)"
    run test "$pending" -gt "$completed"
    assert_success
    run find "$namespace/panes" -name location.state -print
    assert_output ""
    hpl_teardown
  done
}

function test_scripts_1112_herdr_pane_labels_sources_the_alias_library_relative_to() {
  _bats_test_init 1112 'herdr-pane-labels sources the alias library relative to its deployed path'
  local deployed="$BATS_TEST_TMPDIR/deployed-herdr-pane-labels"
  mkdir -p "$deployed/bin" "$deployed/lib"
  cp "$HPL_ENGINE" "$deployed/bin/herdr-pane-labels"
  cp "$HERDR_ALIASES" "$deployed/lib/herdr-aliases.sh"
  cp "$SOURCE_ROOT/lib/herdr-process.sh" "$deployed/lib/herdr-process.sh"

  run env PATH="$deployed/bin:/usr/bin:/bin" bash "$deployed/bin/herdr-pane-labels" --help
  assert_success
  assert_output --partial 'Usage: herdr-pane-labels'
}

function test_scripts_1114_herdr_pane_labels_retries_only_an_exact_confirmed_agent() {
  _bats_test_init 1114 'herdr-pane-labels retries only an exact confirmed agent_name_taken conflict'
  command -v jq >/dev/null || skip "jq not available"
  source "$HERDR_ALIASES"
  hpl_setup
  export HERDR_ALIAS_TEST_SEED=u2-conflict
  local first second occupied state raced
  first="$(herdr_alias_candidates ignored | sed -n '1p')"
  second="$(herdr_alias_candidates ignored | sed -n '2p')"
  occupied=red-wolf
  [[ "$occupied" != "$first" && "$occupied" != "$second" ]] || occupied=blue-otter
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude semantic-name
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-2 tab-1 ws-1 term-2 pi "$occupied"
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  raced="$(jq -c --arg candidate "$first" '.agents |= map(if .pane_id == "pane-2" then .name = $candidate else . end)' "$state")"
  hpl_after_call_state "$HPL_DEFAULT_SOCKET" 3 "$raced"
  hpl_fail_next_agent_rename "$HPL_DEFAULT_SOCKET" agent_name_taken

  hpl_request_only
  hpl_presentation_run

  assert_equal "$(jq -r '.agents[] | select(.pane_id == "pane-1").name' "$state")" "$second"
  assert_equal "$(jq -r '.agents[] | select(.pane_id == "pane-2").name' "$state")" "$first"
  assert_file_contains "$HPL_LOG" "^agent rename pane-1 $first$"
  assert_file_contains "$HPL_LOG" "^agent rename pane-1 $second$"

  hpl_teardown
  hpl_setup
  export HERDR_ALIAS_TEST_SEED=u2-generic
  first="$(herdr_alias_candidates ignored | sed -n '1p')"
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude semantic-name
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-2 tab-1 ws-1 term-2 pi red-wolf
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  raced="$(jq -c --arg candidate "$first" '.agents |= map(if .pane_id == "pane-2" then .name = $candidate else . end)' "$state")"
  hpl_after_call_state "$HPL_DEFAULT_SOCKET" 3 "$raced"
  hpl_fail_next_agent_rename "$HPL_DEFAULT_SOCKET" internal_error
  hpl_request_only
  hpl_presentation_run
  assert_equal "$(jq -r '.agents[] | select(.pane_id == "pane-1").name' "$state")" semantic-name
  assert_equal "$(grep -c '^agent rename pane-1' "$HPL_LOG")" 1
  run grep -E '^(pane|tab) rename|^pane report-metadata' "$HPL_LOG"
  assert_failure
  unset HERDR_ALIAS_TEST_SEED
}

function test_scripts_1115_herdr_pane_labels_never_renames_a_stale_target_that_exi() {
  _bats_test_init 1115 'herdr-pane-labels never renames a stale target that exits moves or changes before validation'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude semantic-name
  local state changed
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  changed="$(jq -c '.panes = [] | .agents = []' "$state")"
  hpl_after_call_state "$HPL_DEFAULT_SOCKET" 1 "$changed"
  hpl_request_only
  hpl_presentation_run
  run grep '^agent rename' "$HPL_LOG"
  assert_failure

  hpl_teardown
  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude semantic-name
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  changed="$(jq -c '
    .panes[0].pane_id = "pane-2" | .panes[0].terminal_id = "term-2"
    | .panes[0].revision = 2
    | .agents[0].pane_id = "pane-2" | .agents[0].terminal_id = "term-2"
    | .agents[0].revision = 2 | .agents[0].state_change_seq = 2' "$state")"
  hpl_after_call_state "$HPL_DEFAULT_SOCKET" 1 "$changed"
  hpl_request_only
  hpl_presentation_run
  run grep '^agent rename pane-1' "$HPL_LOG"
  assert_failure
  run cat "$HPL_WORK/presentation.trace"
  assert_output --partial retry-stale-generation
  run cat "$HPL_LOG"
  assert_output --partial 'agent rename pane-2 '

  hpl_teardown
  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude semantic-name
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  changed="$(jq -c '
    .panes[0].agent = "opencode" | .panes[0].revision = 2
    | .agents[0].agent = "opencode" | .agents[0].revision = 2 | .agents[0].state_change_seq = 2' "$state")"
  hpl_after_call_state "$HPL_DEFAULT_SOCKET" 1 "$changed"
  hpl_request_only
  hpl_presentation_run
  run grep -c '^agent rename pane-1' "$HPL_LOG"
  assert_output 1
  assert_equal "$(jq -r '.panes[0].label' "$state")" "oc:$(jq -r '.agents[0].name' "$state")"
}

function test_scripts_1116_herdr_pane_labels_accepts_a_same_pane_replacement_in_th() {
  _bats_test_init 1116 'herdr-pane-labels accepts a same-pane replacement in the rename command interval'
  command -v jq >/dev/null || skip "jq not available"
  source "$HERDR_ALIASES"
  hpl_setup
  export HERDR_ALIAS_TEST_SEED=u2-command-interval
  local candidate state replacement
  candidate="$(herdr_alias_candidates ignored | sed -n '1p')"
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude semantic-name
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  replacement="$(jq -c --arg candidate "$candidate" '
    .panes[0].agent = "pi" | .panes[0].revision = 2
    | .agents[0].agent = "pi" | .agents[0].revision = 2
    | .agents[0].state_change_seq = 2 | .agents[0].name = $candidate' "$state")"
  hpl_after_call_state "$HPL_DEFAULT_SOCKET" 3 "$replacement"
  hpl_request_only
  hpl_presentation_run
  assert_equal "$(jq -r '.agents[0].name' "$state")" "$candidate"
  assert_equal "$(jq -r '.panes[0].label' "$state")" "pi:$candidate"
  run grep -c '^agent rename pane-1' "$HPL_LOG"
  assert_output 1
  unset HERDR_ALIAS_TEST_SEED
}

function test_scripts_1117_herdr_pane_labels_rejects_incomplete_malformed_duplicat() {
  _bats_test_init 1117 'herdr-pane-labels rejects incomplete malformed duplicate and contradictory snapshots before writes'
  command -v jq >/dev/null || skip "jq not available"
  local mutation baseline state
  for mutation in \
    'del(.agents[0].revision)' \
    '.panes[0].terminal_id = 7' \
    '.agents += [(.agents[0] | .name = "blue-otter")]' \
    '.agents[0].terminal_id = "contradiction"' \
    '.agents[0].tab_id = "other-tab"'; do
    hpl_setup
    hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude semantic-name
    state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
    baseline="$(jq -c . "$state")"
    hpl_transform_state "$HPL_DEFAULT_SOCKET" "$mutation"
    run hpl_sweep_run --sweep
    assert_failure
    run grep -E '^(agent|pane|tab) rename|^pane report-metadata' "$HPL_LOG"
    assert_failure

    hpl_replace_state "$HPL_DEFAULT_SOCKET" "$baseline"
    : > "$HPL_LOG"
    hpl_sweep_run --sweep
    assert_file_contains "$HPL_LOG" '^agent rename pane-1 '
    hpl_teardown
  done

  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-2 tab-1 ws-1 term-2 pi red-wolf
  run hpl_sweep_run --sweep
  assert_failure
  run grep -E '^(agent|pane|tab) rename|^pane report-metadata' "$HPL_LOG"
  assert_failure
  hpl_transform_state "$HPL_DEFAULT_SOCKET" '.agents[1].name = "blue-otter"'
  : > "$HPL_LOG"
  run hpl_sweep_run --sweep
  assert_success
  assert_file_contains "$HPL_LOG" '^pane rename pane-1 cc:red-wolf$'
  assert_file_contains "$HPL_LOG" '^pane rename pane-2 pi:blue-otter$'

  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude semantic-name
  hpl_snapshot_complete "$HPL_DEFAULT_SOCKET" false
  run hpl_sweep_run --sweep
  assert_failure
  run grep -E '^(agent|pane|tab) rename|^pane report-metadata' "$HPL_LOG"
  assert_failure

  hpl_snapshot_complete "$HPL_DEFAULT_SOCKET" true
  : > "$HPL_LOG"
  : > "$(hpl_socket_dir "$HPL_DEFAULT_SOCKET")/malformed-next-snapshot"
  run hpl_sweep_run --sweep
  assert_failure
  run grep -E '^(agent|pane|tab) rename|^pane report-metadata' "$HPL_LOG"
  assert_failure
  : > "$HPL_LOG"
  hpl_sweep_run --sweep
  assert_file_contains "$HPL_LOG" '^agent rename pane-1 '
}

function test_scripts_1118_herdr_pane_labels_rejects_a_complete_stale_post_rename_() {
  _bats_test_init 1118 'herdr-pane-labels rejects a complete stale post-rename snapshot and converges later'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude semantic-name
  local state stale
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  stale="$(jq -c '.agents[0].name = "stale-result"' "$state")"
  hpl_after_call_state "$HPL_DEFAULT_SOCKET" 3 "$stale"
  hpl_request_only
  hpl_presentation_run
  assert_equal "$(jq -r '.panes[0].label' "$state")" old
  run grep -E '^(pane|tab) rename|^pane report-metadata' "$HPL_LOG"
  assert_failure

  : > "$HPL_LOG"
  hpl_request_only
  hpl_presentation_run
  assert_file_contains "$HPL_LOG" '^agent rename pane-1 '
  run grep -q '^cc:' <<<"$(jq -r '.panes[0].label' "$state")"
  assert_success
}

function test_scripts_1119_herdr_pane_labels_contains_no_semantic_naming_or_retire() {
  _bats_test_init 1119 'herdr-pane-labels contains no semantic naming or retired worker interface'
  local retired
  for retired in --agent --session --transcript --set --worker; do
    run bash "$HPL_ENGINE" "$retired"
    assert_failure 2
    assert_output --partial 'Usage: herdr-pane-labels'
  done
}


function test_scripts_1121_herdr_pane_labels_presentation_coalesces_event_bursts_i() {
  _bats_test_init 1121 'herdr-pane-labels presentation coalesces event bursts into an active pass and rerun'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old","tokens":{}}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old"}'
  hpl_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  : > "$HPL_WORK/block-herdr"
  hpl_event_run
  hpl_wait_for_file "$HPL_WORK/herdr-blocked"
  hpl_event_run
  hpl_event_run
  hpl_event_run
  : > "$HPL_WORK/release-herdr"
  hpl_wait_for_presentation_quiescence "$HPL_DEFAULT_SOCKET"

  run grep -c '^api snapshot' "$HPL_LOG"
  # One read belongs to the generation invalidated by the burst; the latest
  # generation then performs its required initial and final complete reads.
  assert_output "3"
  run grep -c '^pane rename pane-1 btop$' "$HPL_LOG"
  assert_output "1"
  run grep -c '^tab rename tab-1 btop$' "$HPL_LOG"
  assert_output "1"
}

function test_scripts_1122_herdr_pane_labels_presentation_retries_a_newer_invalida() {
  _bats_test_init 1122 'herdr-pane-labels presentation retries a newer invalidation after transient pass failure'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old","tokens":{}}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old"}'
  hpl_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  local dir="$(hpl_socket_dir "$HPL_DEFAULT_SOCKET")"
  : > "$dir/fail-next-snapshot"
  : > "$HPL_WORK/block-herdr"
  hpl_event_run
  hpl_wait_for_file "$HPL_WORK/herdr-blocked"
  HERDR_PANE_LABELS_TEST_NO_PRESENTATION=1 hpl_event_run
  : > "$HPL_WORK/release-herdr"
  hpl_wait_for_presentation_quiescence "$HPL_DEFAULT_SOCKET"
  run grep -c '^api snapshot' "$HPL_LOG"
  # The failed read is followed by initial and final complete reads.
  assert_output "3"
  assert_equal "$(jq -r '.panes[0].label' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" btop
}

function test_scripts_1123_herdr_pane_labels_presentation_release_recheck_does_not() {
  _bats_test_init 1123 'herdr-pane-labels presentation release recheck does not lose a pending invalidation'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old","tokens":{}}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old"}'
  hpl_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  local pause="$HPL_WORK/release-edge"
  HERDR_PANE_LABELS_TEST_PAUSE_BEFORE_RELEASE="$pause" hpl_event_run
  hpl_wait_for_file "$pause.reached"
  # The second event only has to make an invalidation pending; letting it also
  # start a presentation of its own races the paused pass under load, which
  # adds a third snapshot and reads as a lost invalidation when it is not.
  # Suppressing it keeps the recheck the only route to the second snapshot, so
  # the exact count below still means what the test name says.
  HERDR_PANE_LABELS_TEST_NO_PRESENTATION=1 hpl_event_run
  : > "$pause.release"
  hpl_wait_for_presentation_quiescence "$HPL_DEFAULT_SOCKET"
  run grep -c '^api snapshot' "$HPL_LOG"
  # Both successful generations perform initial and final complete reads.
  assert_output "4"
}

function test_scripts_1124_herdr_pane_labels_event_presentation_leaves_the_hook_pr() {
  _bats_test_init 1124 'herdr-pane-labels event presentation leaves the hook process group'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old","tokens":{}}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old"}'
  hpl_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  local pause="$HPL_WORK/process-group" claim worker_pid worker_pgid hook_pgid

  HERDR_PANE_LABELS_TEST_PAUSE_BEFORE_RELEASE="$pause" hpl_event_run
  hpl_wait_for_file "$pause.reached"
  claim="$(hpl_namespace "$HPL_DEFAULT_SOCKET")/presentation.claim/owner"
  worker_pid="$(hpl_record_number "$claim" pid)"
  worker_pgid="$(ps -p "$worker_pid" -o pgid= | tr -d '[:space:]')"
  hook_pgid="$(ps -p "$$" -o pgid= | tr -d '[:space:]')"
  : > "$pause.release"
  hpl_wait_for_presentation_quiescence "$HPL_DEFAULT_SOCKET"

  run test -n "$worker_pgid"
  assert_success
  run test "$worker_pgid" != "$hook_pgid"
  assert_success
}

function test_scripts_1125_herdr_pane_labels_presentation_automatically_corrects_d() {
  _bats_test_init 1125 'herdr-pane-labels presentation automatically corrects divergent pane and tab labels'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf
  hpl_sweep_run --sweep
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane rename pane-1 divergent-pane
  : > "$HPL_LOG"
  hpl_event_run
  hpl_wait_for_presentation_quiescence "$HPL_DEFAULT_SOCKET"
  run grep '^pane rename' "$HPL_LOG"
  assert_output "pane rename pane-1 cc:red-wolf"
  run grep -c '^tab rename' "$HPL_LOG"
  assert_failure

  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane rename pane-1 divergent-again
  hpl_socket_run "$HPL_DEFAULT_SOCKET" tab rename tab-1 divergent-tab
  : > "$HPL_LOG"
  hpl_event_run
  hpl_wait_for_presentation_quiescence "$HPL_DEFAULT_SOCKET"
  assert_file_contains "$HPL_LOG" '^pane rename pane-1 cc:red-wolf$'
  assert_file_contains "$HPL_LOG" '^tab rename tab-1 cc:red-wolf$'
  run grep -E 'owner|reclaim|notification' "$HPL_LOG"
  assert_failure
}

function test_scripts_1126_herdr_pane_labels_presentation_rejects_an_unsafe_row_wi() {
  _bats_test_init 1126 'herdr-pane-labels presentation rejects an unsafe row without reducing pass scope'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  # A FIELD_SEPARATOR in one pane must abort the whole pass. Labeling only the
  # other pane would turn malformed data into an apparently successful pass.
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"bad\u001flabel","tokens":{}}'
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-2","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-2","agent":null,"label":"old","tokens":{}}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-tab"}'
  hpl_proc_info pane-2 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  hpl_request_only
  hpl_presentation_run
  local state namespace pending completed
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-2") | .label' "$state")" old
  assert_equal "$(jq -r '.tabs[0].label' "$state")" old-tab
  run grep -E '^(agent|pane|tab) rename|^pane report-metadata' "$HPL_LOG"
  assert_failure
  namespace="$(hpl_namespace "$HPL_DEFAULT_SOCKET")"
  pending="$(hpl_record_number "$namespace/reconcile.state" pending_generation)"
  completed="$(hpl_record_number "$namespace/reconcile.state" completed_generation)"
  run test "$pending" -gt "$completed"
  assert_success
}

function test_scripts_1127_herdr_pane_labels_aborts_unsafe_process_and_git_derived() {
  _bats_test_init 1127 'herdr-pane-labels aborts unsafe process and Git-derived positional rows'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_process_pane pane-1 tab-1 ws-1 term-1 /tmp old
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-tab"}'
  hpl_proc_info pane-1 '{"result":{"process_info":{"shell_pid":1,"foreground_process_group_id":2,"foreground_processes":[{"pid":2,"argv":["bad\u001fcommand"]}]}}}'
  hpl_request_only
  hpl_presentation_run

  local namespace pending completed root common unsafe_root
  namespace="$(hpl_namespace "$HPL_DEFAULT_SOCKET")"
  pending="$(hpl_record_number "$namespace/reconcile.state" pending_generation)"
  completed="$(hpl_record_number "$namespace/reconcile.state" completed_generation)"
  run test "$pending" -gt "$completed"
  assert_success
  run grep -E '^(agent|pane|tab) rename|^pane report-metadata' "$HPL_LOG"
  assert_failure
  run find "$namespace/panes" -name location.state -print
  assert_output ""

  hpl_teardown
  hpl_setup
  root="$HPL_WORK/repository"
  common="$root/.git"
  unsafe_root="bad$(printf '\037')root"
  mkdir -p "$root" "$common"
  hpl_git_location_fixture "$root" "$unsafe_root" "$common" refs/heads/main
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-tab"}'
  hpl_set_process_label pane-1 worker
  hpl_request_only
  HERDR_PANE_LABELS_GIT_BUDGET="$HPL_GIT_BUDGET" hpl_presentation_run

  namespace="$(hpl_namespace "$HPL_DEFAULT_SOCKET")"
  pending="$(hpl_record_number "$namespace/reconcile.state" pending_generation)"
  completed="$(hpl_record_number "$namespace/reconcile.state" completed_generation)"
  run test "$pending" -gt "$completed"
  assert_success
  run grep -E '^(agent|pane|tab) rename|^pane report-metadata' "$HPL_LOG"
  assert_failure
  run find "$namespace/panes" -name location.state -print
  assert_output ""
}

function test_scripts_1128_herdr_pane_labels_presentation_skips_pre_read_deletion_() {
  _bats_test_init 1128 'herdr-pane-labels presentation skips pre-read deletion and repairs the post-read race next pass'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old","tokens":{}}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old"}'
  hpl_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  local state missing next dir
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  missing="$(jq -c '.panes = []' "$state")"
  hpl_after_next_call_state "$HPL_DEFAULT_SOCKET" "$missing"
  hpl_request_only
  hpl_presentation_run
  run grep -c '^pane rename' "$HPL_LOG"
  assert_failure

  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-2","agent":null,"label":"wrong","tokens":{}}'
  : > "$HPL_LOG"
  dir="$(hpl_socket_dir "$HPL_DEFAULT_SOCKET")"
  next=$(( $(cat "$dir/call-seq") + 3 ))
  hpl_after_call_script "$HPL_DEFAULT_SOCKET" "$next" "printf '%s' '{\"result\":{\"process_info\":{\"shell_pid\":100,\"foreground_process_group_id\":300,\"foreground_processes\":[{\"pid\":300,\"name\":\"cargo\",\"argv0\":\"cargo\",\"argv\":[\"cargo\",\"test\"]}]}}}' > '$dir/proc-pane-1.json'"
  hpl_request_only
  hpl_presentation_run
  assert_equal "$(jq -r '.panes[0].label' "$state")" btop
  hpl_request_only
  hpl_presentation_run
  assert_equal "$(jq -r '.panes[0].label' "$state")" "cargo test"
}

function test_scripts_1129_herdr_pane_labels_presentation_skips_reused_pane_and_ta() {
  _bats_test_init 1129 'herdr-pane-labels presentation skips reused pane and tab identities at the final read'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"old-pane","tokens":{}}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-tab"}'
  hpl_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[{"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  local state next_state
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  next_state="$(jq -c '
    .panes[0].terminal_id = "term-2"
    | .panes[0].workspace_id = "ws-2"
    | .panes[0].label = "reused-pane"
    | .tabs[0].workspace_id = "ws-2"
    | .tabs[0].label = "reused-tab"
    | .workspaces += [{"workspace_id":"ws-2","label":"ws-2"}]
  ' "$state")"
  hpl_after_next_call_state "$HPL_DEFAULT_SOCKET" "$next_state"

  hpl_request_only
  hpl_presentation_run
  assert_equal "$(jq -r '.panes[0].label' "$state")" reused-pane
  assert_equal "$(jq -r '.tabs[0].label' "$state")" reused-tab
  run grep -E '^(pane|tab) rename' "$HPL_LOG"
  assert_failure

  hpl_request_only
  hpl_presentation_run
  assert_equal "$(jq -r '.panes[0].label' "$state")" btop
  assert_equal "$(jq -r '.tabs[0].label' "$state")" btop
}

function test_scripts_1130_herdr_pane_labels_presentation_isolates_exact_colliding() {
  _bats_test_init 1130 'herdr-pane-labels presentation isolates exact colliding socket identities'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local socket_one="$HPL_WORK/a-b.sock" socket_two="$HPL_WORK/a_b.sock"
  hpl_set_pane "$socket_one" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1a","agent":null,"label":"old-one","tokens":{}}'
  hpl_set_tab "$socket_one" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-one"}'
  hpl_set_pane "$socket_two" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1b","agent":null,"label":"old-two","tokens":{}}'
  hpl_set_tab "$socket_two" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"old-two"}'
  hpl_proc_info_for_socket "$socket_one" pane-1 '{"result":{"process_info":{"shell_pid":1,"foreground_process_group_id":2,"foreground_processes":[{"pid":2,"argv":["one"]}]}}}'
  hpl_proc_info_for_socket "$socket_two" pane-1 '{"result":{"process_info":{"shell_pid":1,"foreground_process_group_id":2,"foreground_processes":[{"pid":2,"argv":["two"]}]}}}'
  hpl_event_run_for_socket "$socket_one"
  hpl_event_run_for_socket "$socket_two"
  hpl_wait_for_presentation_quiescence "$socket_one"
  hpl_wait_for_presentation_quiescence "$socket_two"
  assert_equal "$(jq -r '.panes[0].label' "$(hpl_socket_state "$socket_one")")" one
  assert_equal "$(jq -r '.panes[0].label' "$(hpl_socket_state "$socket_two")")" two
  run test "$(hpl_namespace "$socket_one")" != "$(hpl_namespace "$socket_two")"
  assert_success
}

function test_scripts_1131_herdr_pane_labels_presentation_fails_closed_without_an_() {
  _bats_test_init 1131 'herdr-pane-labels presentation fails closed without an exact socket'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_pane "$HPL_DEFAULT_SOCKET" '{"pane_id":"pane-1","tab_id":"tab-1","workspace_id":"ws-1","terminal_id":"term-1","agent":null,"label":"unchanged","tokens":{}}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":"unchanged"}'
  hpl_proc_info pane-1 '{"result":{"process_info":{"shell_pid":1,"foreground_process_group_id":2,"foreground_processes":[{"pid":2,"argv":["changed"]}]}}}'
  run env -u HERDR_SOCKET_PATH PATH="$HPL_STUB:/usr/bin:/bin" HERDR_PANE_LABELS_STATE_DIR="$HPL_STATE" bash "$HPL_ENGINE" --event
  assert_success
  run env -u HERDR_SOCKET_PATH PATH="$HPL_STUB:/usr/bin:/bin" HERDR_PANE_LABELS_STATE_DIR="$HPL_STATE" bash "$HPL_ENGINE" --sweep
  assert_success
  assert_equal "$(cat "$HPL_LOG")" ""
  assert_equal "$(jq -r '.panes[0].label' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" unchanged
}

function test_scripts_1132_herdr_pane_labels_location_resolves_main_linked_nested_() {
  _bats_test_init 1132 'herdr-pane-labels location resolves main linked nested and administrative paths with strict foreground semantics'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local main="$HPL_WORK/checkouts/repository" linked="$HPL_WORK/linked/feature"
  local common="$main/.git" nongit="$HPL_WORK/outside" state
  mkdir -p "$main/src/nested" "$common/objects" "$common/worktrees/feature/logs" "$linked/deep/path" "$nongit"
  hpl_mark_linked_worktree "$linked" "$common/worktrees/feature"
  printf '%s/.git\n' "$linked" > "$common/worktrees/feature/gitdir"
  hpl_git_location_fixture "$main/src/nested" "$main" "$common" refs/heads/main
  hpl_git_location_fixture "$main" "$main" "$common" refs/heads/main
  hpl_git_location_fixture "$linked" "$linked" "$common" refs/heads/feature
  hpl_git_location_fixture "$linked/deep/path" "$linked" "$common" refs/heads/feature
  hpl_git_fixture "$nongit" "" 1 ready 'fatal: not a git repository'

  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json main-nested tab-1 "$main" present "$main/src/nested")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json main-admin tab-1 "$main" present "$common/objects")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json linked-admin tab-1 "$linked" present "$common/worktrees/feature/logs")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json fallback tab-1 "$linked/deep/path" absent)"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json foreground-wins tab-1 "$linked/deep/path" present "$nongit")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json agent-ignores-foreground tab-1 "$linked/deep/path" present "$nongit" | jq -c '.agent = "pi"')"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repository"}'
  for pane_id in main-nested main-admin linked-admin fallback foreground-wins agent-ignores-foreground; do hpl_set_process_label "$pane_id" "$pane_id"; done
  LANG=fr_FR.UTF-8 LC_ALL= hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"

  assert_equal "$(jq -r '.panes[] | select(.pane_id == "main-nested" or .pane_id == "main-admin") | .tokens.repo' "$state" | sort -u)" repository
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "main-nested" or .pane_id == "main-admin") | .tokens.worktree' "$state" | sort -u)" repository
  # Main checkout: branch icon and the ref, nothing else — a pane with a ref
  # never carries a folder qualifier.
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "main-nested" or .pane_id == "main-admin") | .tokens.git_ref' "$state" | sort -u)" "$HPL_ICON_BRANCH main"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "linked-admin" or .pane_id == "fallback") | .tokens.branch' "$state" | sort -u)" feature
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "linked-admin" or .pane_id == "fallback") | .tokens.worktree' "$state" | sort -u)" feature
  # Linked worktree (.git file at root): worktree icon and the ref; the
  # directory the worktree occupies stays out of the row.
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "linked-admin" or .pane_id == "fallback") | .tokens.git_ref' "$state" | sort -u)" "$HPL_ICON_WORKTREE feature"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "agent-ignores-foreground") | .tokens.branch' "$state")" feature
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "agent-ignores-foreground") | .tokens.worktree' "$state")" feature
  # Foreground cwd outside any checkout: no Git tokens at all, and the folder
  # name is the whole row.
  run jq -e --arg ref "$HPL_ICON_FOLDER outside" '.panes[] | select(.pane_id == "foreground-wins") | (.tokens.repo == null and .tokens.worktree == null and .tokens.branch == null and .tokens.git_ref == $ref)' "$state"
  assert_success
  assert_equal "$(cat "$(hpl_git_fixture_dir "$nongit")/locale")" C
}

function test_scripts_1133_herdr_pane_labels_dangling_administrative_gitdir_retain() {
  _bats_test_init 1133 'herdr-pane-labels dangling administrative gitdir retains stale location'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local main="$HPL_WORK/checkouts/repository" linked="$HPL_WORK/linked/feature"
  local common="$main/.git" admin="$common/worktrees/feature/logs" state
  mkdir -p "$common/worktrees/feature/logs" "$linked"
  hpl_mark_linked_worktree "$linked" "$common/worktrees/feature"
  printf '%s/.git\n' "$linked" > "$common/worktrees/feature/gitdir"
  hpl_git_location_fixture "$linked" "$linked" "$common" refs/heads/feature
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$linked" present "$linked")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 worker
  hpl_location_pass

  printf '%s\n' "$HPL_WORK/missing/.git" > "$common/worktrees/feature/gitdir"
  hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-1 "$linked" "$admin"
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.worktree' "$state")" feature
  assert_equal "$(jq -r '.panes[0].tokens.branch' "$state")" feature
  assert_equal "$(jq -r '.panes[0].tokens.location_status' "$state")" stale
  # Retained stale evidence keeps the worktree place icon and renders stale
  # as a suffix icon on $git_ref, not as a separate row or text marker.
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_WORKTREE feature $HPL_ICON_STALE"
}

function test_scripts_1134_herdr_pane_labels_location_detached_publishes_a_commit_() {
  _bats_test_init 1134 'herdr-pane-labels location detached publishes a commit ref and non-Git clears are source-local with monotonic restart high-water'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/repo" common="$HPL_WORK/repo.git"
  local branch="$root/branch" detached="$root/detached" nongit="$HPL_WORK/non-git" state first_seq second_seq
  mkdir -p "$branch" "$detached" "$nongit" "$common" "$root/.git"
  hpl_git_location_fixture "$branch" "$root" "$common" refs/heads/topic
  hpl_git_location_fixture "$detached" "$root" "$common" HEAD a1b2c3d
  hpl_git_fixture "$nongit" "" 1 ready 'fatal: not a git repository'
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$branch")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hpl_set_process_label pane-1 worker
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane report-metadata pane-1 --source foreign-source --token foreign=kept --seq 900

  HERDR_PANE_LABELS_TEST_NOW_SEQ=1000 hpl_location_pass
  first_seq="$(hpl_location_source_seq "$HPL_DEFAULT_SOCKET" pane-1)"
  hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-1 "$detached" "$detached"
  HERDR_PANE_LABELS_TEST_NOW_SEQ=1 hpl_location_pass
  second_seq="$(hpl_location_source_seq "$HPL_DEFAULT_SOCKET" pane-1)"
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  run test "$second_seq" -gt "$first_seq"
  assert_success
  assert_equal "$(jq -r '.panes[0].tokens.repo' "$state")" repo.git
  assert_equal "$(jq -r '.panes[0].tokens.worktree' "$state")" repo
  # Detached HEAD keeps the location: commit icon plus 7-char short SHA, no
  # stale marker, and no branch token.
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_COMMIT a1b2c3d"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" worker
  run jq -e '.panes[0].tokens.branch == null and .panes[0].tokens.location_status == null and .panes[0].tokens.foreign == "kept"' "$state"
  assert_success

  hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-1 "$nongit" "$nongit"
  HERDR_PANE_LABELS_TEST_NOW_SEQ=0 hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  # The non-Git arm clears every Git token, keeps a foreign source's token, and
  # publishes the directory name as the only thing this pane can report.
  assert_equal "$(jq -c '.panes[0].tokens' "$state")" "$(jq -nc --arg ref "$HPL_ICON_FOLDER non-git" '{foreign:"kept",git_ref:$ref}')"
  run test "$(hpl_location_source_seq "$HPL_DEFAULT_SOCKET" pane-1)" -gt "$second_seq"
  assert_success
}

function test_scripts_1135_herdr_pane_labels_location_real_probe_shape_pays_the_se() {
  _bats_test_init 1135 'herdr-pane-labels location real probe shape pays the second sha call only when detached'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/repo" common="$HPL_WORK/repo.git"
  local branch="$root/branch" detached="$root/detached" state branch_fixture detached_fixture
  mkdir -p "$branch" "$detached" "$common" "$root/.git"
  # given: real-git probe shape — three lines from the first call, the short
  # SHA only from a separate `rev-parse --short=7 HEAD` answered via the
  # stub's stdout.short selector.
  hpl_git_fixture "$branch" "$(printf '%s\n%s\n%s' "$root" "$common" refs/heads/topic)"
  hpl_git_fixture "$detached" "$(printf '%s\n%s\n%s' "$root" "$common" HEAD)"
  branch_fixture="$(hpl_git_fixture_dir "$branch")"
  detached_fixture="$(hpl_git_fixture_dir "$detached")"
  printf 'e4f5a6b\n' > "$branch_fixture/stdout.short"
  printf 'e4f5a6b\n' > "$detached_fixture/stdout.short"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$branch")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hpl_set_process_label pane-1 worker

  # when: a branch pane resolves
  HERDR_PANE_LABELS_TEST_NOW_SEQ=1000 hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  # then: the ref came from the 3-line probe alone — no --short call fired
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_BRANCH topic"
  run grep -c -- '--short=7' "$branch_fixture/calls"
  assert_failure

  # when: the same pane moves to a detached checkout
  hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-1 "$detached" "$detached"
  HERDR_PANE_LABELS_TEST_NOW_SEQ=1001 hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  # then: exactly one second budgeted call fetched the SHA
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_COMMIT e4f5a6b"
  assert_equal "$(grep -c -- '--short=7' "$detached_fixture/calls")" 1
}

function test_scripts_1136_herdr_pane_labels_location_detached_sha_failure_retains() {
  _bats_test_init 1136 'herdr-pane-labels location detached sha failure retains prior identity as stale and never publishes a malformed git_ref'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/repo" common="$HPL_WORK/repo.git"
  local branch="$root/branch" empty_sha="$root/empty-sha" bad_sha="$root/bad-sha" state target fixture
  mkdir -p "$branch" "$empty_sha" "$bad_sha" "$common" "$root/.git"
  # given: real-git probe shape — the detached probes answer 3 lines, and the
  # second `rev-parse --short=7` call yields an empty or non-hex SHA.
  hpl_git_fixture "$branch" "$(printf '%s\n%s\n%s' "$root" "$common" refs/heads/topic)"
  hpl_git_fixture "$empty_sha" "$(printf '%s\n%s\n%s' "$root" "$common" HEAD)"
  hpl_git_fixture "$bad_sha" "$(printf '%s\n%s\n%s' "$root" "$common" HEAD)"
  : > "$(hpl_git_fixture_dir "$empty_sha")/stdout.short"
  printf 'not-a-sha\n' > "$(hpl_git_fixture_dir "$bad_sha")/stdout.short"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$branch")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hpl_set_process_label pane-1 worker
  # given: prior canonical identity from a healthy branch resolve
  hpl_location_pass
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" "$HPL_ICON_BRANCH topic"

  for target in "$empty_sha" "$bad_sha"; do
    # when: the pane moves to a detached checkout whose SHA fetch fails
    hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-1 "$target" "$target"
    hpl_location_pass
    state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
    # then: the second call fired, and the pane retains the prior branch
    # identity as stale — no commit ref built from a malformed SHA.
    fixture="$(hpl_git_fixture_dir "$target")"
    assert_equal "$(grep -c -- '--short=7' "$fixture/calls")" 1
    assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_BRANCH topic $HPL_ICON_STALE"
    assert_equal "$(jq -r '.panes[0].tokens.branch' "$state")" topic
    assert_equal "$(jq -r '.panes[0].tokens.location_status' "$state")" stale
  done
}

function test_scripts_1137_herdr_pane_labels_location_detached_sha_budget_failure_() {
  _bats_test_init 1137 'herdr-pane-labels location detached sha budget failure with no prior state renders no git location and self-heals'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/repo" common="$HPL_WORK/repo.git"
  local detached="$root/detached" fixture state
  mkdir -p "$detached" "$common" "$root/.git"
  # given: real-git probe shape — the first call answers 3 lines in budget,
  # and block.short stalls the second --short=7 call past LOCATION_GIT_BUDGET.
  hpl_git_fixture "$detached" "$(printf '%s\n%s\n%s' "$root" "$common" HEAD)"
  fixture="$(hpl_git_fixture_dir "$detached")"
  printf 'e4f5a6b\n' > "$fixture/stdout.short"
  : > "$fixture/block.short"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$detached")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hpl_set_process_label pane-1 worker
  # when: the very first pass for this pane — no prior location state exists
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  # then: the SHA probe fired, its budget failure discarded the freshly
  # resolved root, and with nothing prior to retain the pane renders with no
  # git location this pass — no half-built commit ref, no stale marker.
  assert_equal "$(grep -c -- '--short=7' "$fixture/calls")" 1
  run jq -e '.panes[0].tokens | (.repo == null and .worktree == null and .branch == null and .location_status == null and .git_ref == null)' "$state"
  assert_success
  assert_equal "$(jq -r '.tabs[0].label' "$state")" worker
  # when: the next sweep finds a responsive SHA probe
  : > "$fixture/release"
  hpl_location_pass
  # then: the pane self-heals to the commit ref without manual repair
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" "$HPL_ICON_COMMIT e4f5a6b"
}

function test_scripts_1138_herdr_pane_labels_location_clears_the_retired_location_() {
  _bats_test_init 1138 'herdr-pane-labels location clears the retired location_label token on both publish and non-git clear paths'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/repo" common="$HPL_WORK/repo.git" nongit="$HPL_WORK/non-git" state
  mkdir -p "$root" "$common" "$nongit"
  hpl_git_location_fixture "$root" "$root" "$common" refs/heads/topic
  hpl_git_fixture "$nongit" "" 1 ready 'fatal: not a git repository'
  # given: panes still carrying the legacy location_label token published by
  # the previously deployed version
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root" | jq -c '.tokens.location_label = "legacy label"')"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$nongit" | jq -c '.tokens = {location_label:"legacy label", git_ref:"stale ref"}')"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repo"}'
  hpl_set_process_label pane-1 worker
  hpl_set_process_label pane-2 shell
  # when: one location/presentation pass runs
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  # then: the Git publish path sheds the legacy token while publishing git_ref
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.git_ref' "$state")" "$HPL_ICON_BRANCH topic"
  run jq -e '.panes[] | select(.pane_id == "pane-1") | .tokens.location_label == null' "$state"
  assert_success
  # then: the non-Git path sheds the legacy token and overwrites the stale
  # git_ref it was carrying with this pane's own directory name
  run jq -e --arg ref "$HPL_ICON_FOLDER non-git" '.panes[] | select(.pane_id == "pane-2") | (.tokens.location_label == null and .tokens.git_ref == $ref)' "$state"
  assert_success
}

function test_scripts_1139_herdr_pane_labels_location_transient_modes_retain_ident() {
  _bats_test_init 1139 'herdr-pane-labels location transient modes retain identity as stale without foreground fallback'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/repo" common="$HPL_WORK/repo.git"
  local fallback="$root/fallback" fresh="$root/fresh" permission="$HPL_WORK/permission" unavailable="$HPL_WORK/unavailable"
  local malformed="$HPL_WORK/malformed" blocked="$HPL_WORK/blocked" missing="$HPL_WORK/missing" state
  mkdir -p "$fresh" "$fallback" "$permission" "$unavailable" "$malformed" "$blocked" "$common"
  hpl_git_location_fixture "$fresh" "$root" "$common" refs/heads/main
  hpl_git_location_fixture "$fallback" "$root" "$common" refs/heads/main
  hpl_git_fixture "$permission" "denied" 126
  hpl_git_fixture "$unavailable" "missing" 127
  hpl_git_fixture "$malformed" "only-one-line" 0
  hpl_git_fixture "$blocked" "never" 0 block
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$fallback" present "$fresh")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$fallback" present "$fresh")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 primary
  hpl_set_process_label pane-2 repaired
  hpl_location_pass

  local transient
  for transient in "$missing" "$permission" "$unavailable" "$malformed"; do
    hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$fallback" present "$transient")"
    hpl_location_pass
    state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
    assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.worktree' "$state")" repo
    assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.location_status' "$state")" stale
  done

  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$fallback" present "")"
  hpl_location_pass
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.location_status' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" stale

  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$fallback" present "$blocked")"
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane rename pane-2 externally-wrong
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.location_status' "$state")" stale
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-2") | .label' "$state")" repaired

  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$fallback" present "$fresh")"
  hpl_location_pass
  run jq -e '.panes[] | select(.pane_id == "pane-1") | .tokens.location_status == null' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_success
}

function test_scripts_1140_herdr_pane_labels_coordinator_resolves_eight_pane_locat() {
  _bats_test_init 1140 'herdr-pane-labels coordinator resolves eight pane locations concurrently within one event envelope'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local i root common cwd fixture blocked_fixture state pane stale_label
  local reconcile pending completed coordinator_pid deadline_pid deadline="$HPL_WORK/coordinator-deadline"
  for i in $(seq 1 8); do
    root="$HPL_WORK/repos/repo-$i"
    common="$HPL_WORK/repos/repo-$i.git"
    cwd="$root/work"
    mkdir -p "$cwd" "$common" "$root/.git"
    if [ "$i" -eq 1 ]; then
      hpl_git_location_fixture "$cwd" "$root" "$common" refs/heads/initial-1
    else
      hpl_git_fixture "$cwd" "" 1 ready 'fatal: not a git repository'
    fi
    pane="$(hpl_process_pane_json "pane-$i" tab-1 "$cwd")"
    pane="$(jq -c --arg label "stable-$i" '.agent = "claude" | .label = $label' <<< "$pane")"
    hpl_set_pane "$HPL_DEFAULT_SOCKET" "$pane"
  done
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_location_pass

  rm -f "$HPL_WORK/git-started"/*
  for i in $(seq 1 8); do
    root="$HPL_WORK/repos/repo-$i"
    common="$HPL_WORK/repos/repo-$i.git"
    cwd="$root/work"
    fixture="$(hpl_git_fixture_dir "$cwd")"
    rm -f "$fixture/started" "$fixture/completed"
    if [ "$i" -eq 1 ]; then
      : > "$fixture/block"
      blocked_fixture="$fixture"
    fi
  done

  stale_label="$HPL_ICON_BRANCH initial-1 $HPL_ICON_STALE stable-1"
  for i in $(seq 2 8); do stale_label="$stale_label · stable-$i"; done
  hpl_set_tab "$HPL_DEFAULT_SOCKET" "$(jq -cn --arg label "$stale_label" \
    '{tab_id:"tab-1",workspace_id:"ws-1",label:$label}')"
  HERDR_PANE_LABELS_TEST_NO_PRESENTATION=1 hpl_event_run
  reconcile="$(hpl_namespace "$HPL_DEFAULT_SOCKET")/reconcile.state"
  pending="$(hpl_record_number "$reconcile" pending_generation)"
  export HERDR_PANE_LABELS_TEST_LOCATION_BARRIER="$HPL_WORK/location-probes-started"
  export HERDR_PANE_LABELS_TEST_LOCATION_BARRIER_COUNT=8
  export HERDR_PANE_LABELS_TEST_LOCATION_BARRIER_RELEASE="$HPL_WORK/location-probes-release"
  export HERDR_PANE_LABELS_GIT_BUDGET=$HPL_GIT_BUDGET
  hpl_presentation_run &
  coordinator_pid=$!
  # The barrier is what proves concurrency: every probe publishes its marker and then
  # spins until all eight exist, so serial probes deadlock on the first one and this
  # wait fails the test before the release below ever happens. The deadline is only a
  # hang guard for that release path, never a performance budget -- a wall-clock bound
  # here measured the serial presentation tail after the probes (~78% of the window),
  # so it went red on slower CI runners without any regression behind it.
  for i in $(seq 1 8); do
    hpl_wait_for_file "$HERDR_PANE_LABELS_TEST_LOCATION_BARRIER/$(hpl_key "pane-$i")"
  done
  (sleep 30; : > "$deadline") &
  deadline_pid=$!
  : > "$HERDR_PANE_LABELS_TEST_LOCATION_BARRIER_RELEASE"
  while :; do
    completed="$(hpl_record_number "$reconcile" completed_generation 2>/dev/null || true)"
    if [ "$completed" = "$pending" ]; then
      break
    fi
    if [ -e "$deadline" ]; then
      kill "$coordinator_pid" 2>/dev/null || true
      wait "$coordinator_pid" 2>/dev/null || true
      fail "coordinator generation did not complete within 30s"
    fi
    sleep 0.005
  done
  kill "$deadline_pid" 2>/dev/null || true
  wait "$deadline_pid" 2>/dev/null || true
  wait "$coordinator_pid"
  unset HERDR_PANE_LABELS_TEST_LOCATION_BARRIER \
    HERDR_PANE_LABELS_TEST_LOCATION_BARRIER_COUNT \
    HERDR_PANE_LABELS_TEST_LOCATION_BARRIER_RELEASE HERDR_PANE_LABELS_GIT_BUDGET

  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  run jq -e '.panes[] | select(.pane_id == "pane-1") | .tokens.branch == "initial-1" and .tokens.location_status == "stale"' "$state"
  assert_success
  for i in $(seq 2 8); do
    # Non-Git panes publish no Git token at all. Their directories all end in
    # "work", so the folder row carries the disambiguating path suffix the
    # token builder assigns, exactly as it does for same-named checkouts.
    run jq -e --arg pane "pane-$i" --arg ref "$HPL_ICON_FOLDER repo-$i/work" \
      '.panes[] | select(.pane_id == $pane) | (.tokens.repo == null and .tokens.worktree == null and .tokens.branch == null and .tokens.location_status == null and .tokens.git_ref == $ref)' "$state"
    assert_success
    fixture="$(hpl_git_fixture_dir "$HPL_WORK/repos/repo-$i/work")"
    assert_file_exists "$fixture/started"
    assert_file_exists "$fixture/completed"
  done
  assert_file_exists "$blocked_fixture/started"
  assert_file_not_exists "$blocked_fixture/completed"
}

function test_scripts_1141_herdr_pane_labels_no_op_location_event_preserves_the_st() {
  _bats_test_init 1141 'herdr-pane-labels no-op location event preserves the state file'
  command -v jq >/dev/null || skip "jq not available"
  command -v perl >/dev/null || skip "perl not available"
  hpl_setup
  local root="$HPL_WORK/repo" common="$HPL_WORK/repo.git" cwd="$HPL_WORK/repo/work"
  local location_file before_link before_mtime after_mtime
  mkdir -p "$cwd" "$common"
  hpl_git_location_fixture "$cwd" "$root" "$common" refs/heads/main
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$cwd")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 task
  hpl_location_pass

  location_file="$(hpl_pane_state_dir "$HPL_DEFAULT_SOCKET" pane-1)/location.state"
  before_link="$HPL_WORK/location-before.state"
  touch -t 200001010000 "$location_file"
  ln "$location_file" "$before_link"
  before_mtime="$(perl -e 'print((stat shift)[9])' "$location_file")"
  hpl_location_pass
  after_mtime="$(perl -e 'print((stat shift)[9])' "$location_file")"

  [ "$location_file" -ef "$before_link" ]
  assert_equal "$after_mtime" "$before_mtime"
}

function test_scripts_1142_herdr_pane_labels_transient_location_preserves_live_tok() {
  _bats_test_init 1142 'herdr-pane-labels transient location preserves live token-only identity when retained state is unavailable'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local missing_one="$HPL_WORK/missing-one" unavailable="$HPL_WORK/unavailable"
  local outside="$HPL_WORK/outside" pane_one pane_two location_two state
  mkdir -p "$outside" "$unavailable"
  hpl_git_fixture "$outside" "" 1 ready 'fatal: not a git repository'
  hpl_git_fixture "$unavailable" unavailable 127
  pane_one="$(hpl_process_pane_json pane-1 tab-1 "$missing_one")"
  pane_one="$(jq -c '.tokens = {repo:"live-repo",worktree:"live-token",branch:"topic-one",pane_inline:"· one"}' <<< "$pane_one")"
  pane_two="$(hpl_process_pane_json pane-2 tab-1 "$unavailable")"
  pane_two="$(jq -c '.tokens = {repo:"live-repo",worktree:"live-token",location_status:"current"}' <<< "$pane_two")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$pane_one"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$pane_two"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-3 tab-1 "$outside")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 one
  hpl_set_process_label pane-2 two
  hpl_set_process_label pane-3 three
  location_two="$(hpl_pane_state_dir "$HPL_DEFAULT_SOCKET" pane-2)/location.state"
  mkdir -p "$(dirname "$location_two")"
  printf '%s\n' not-a-location-record > "$location_two"

  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  # Token-only evidence carries no is_linked proof, so the place icon falls
  # back to the branch icon. Pane one has a ref, so the ref is the whole row;
  # pane two has none, and there the folder icon plus worktree token is all
  # $git_ref can say.
  run jq -e \
    --arg ref_one "$HPL_ICON_BRANCH topic-one $HPL_ICON_STALE" \
    --arg ref_two "$HPL_ICON_FOLDER live-token $HPL_ICON_STALE" '
    (.panes[] | select(.pane_id == "pane-1") | .tokens == {repo:"live-repo",worktree:"live-token",branch:"topic-one",location_status:"stale",git_ref:$ref_one})
    and (.panes[] | select(.pane_id == "pane-2") | .tokens == {repo:"live-repo",worktree:"live-token",location_status:"stale",git_ref:$ref_two})
  ' "$state"
  assert_success
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "one · two · three"
  assert_file_not_exists "$(hpl_pane_state_dir "$HPL_DEFAULT_SOCKET" pane-1)/location.state"
  assert_equal "$(cat "$location_two")" not-a-location-record
}

function test_scripts_1143_herdr_pane_labels_location_authoritative_worktree_delet() {
  _bats_test_init 1143 'herdr-pane-labels location authoritative worktree deletion clears retained evidence'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/linked/deleted" common="$HPL_WORK/main/.git"
  local live="$root/live" missing="$root/gone"
  mkdir -p "$live" "$common"
  hpl_git_location_fixture "$live" "$root" "$common" refs/heads/deleted
  hpl_git_fixture "gitdir:$common" "worktree $HPL_WORK/main\nHEAD 123456\nbranch refs/heads/main" 0
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$live")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 worker
  hpl_location_pass
  assert_equal "$(jq -r '.panes[0].tokens.worktree' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" deleted
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$missing")"
  hpl_location_pass
  run jq -e '.panes[0].tokens.repo == null and .panes[0].tokens.worktree == null and .panes[0].tokens.branch == null and .panes[0].tokens.location_status == null and .panes[0].tokens.git_ref == null' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_success
}

function test_scripts_1144_herdr_pane_labels_formatter_keeps_git_refs_in_metadata_() {
  _bats_test_init 1144 'herdr-pane-labels formatter keeps Git refs in metadata and tab labels names-only'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/project" common="$HPL_WORK/project/.git"
  local one="$root/one" two="$root/two" missing="$root/missing" outside="$HPL_WORK/outside" state
  mkdir -p "$one" "$two" "$outside" "$common"
  hpl_git_location_fixture "$one" "$root" "$common" refs/heads/main
  hpl_git_location_fixture "$two" "$root" "$common" refs/heads/main
  hpl_git_fixture "$outside" "" 1 ready 'fatal: not a git repository'
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$one")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$two")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"project"}'
  hpl_set_process_label pane-1 alpha
  hpl_set_process_label pane-2 beta
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "alpha · beta"
  assert_equal "$(jq -r '.panes[] | .tokens.git_ref' "$state" | sort -u)" "$HPL_ICON_BRANCH main"

  # Stale state changes only the sidebar metadata, not the tab identity.
  hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-2 "$two" "$missing"
  hpl_location_pass
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "alpha · beta"

  hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-1 "$outside" "$outside"
  hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-2 "$outside" "$outside"
  hpl_location_pass
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "alpha · beta"
}

function test_scripts_1145_herdr_pane_labels_formatter_renders_a_main_checkout_ref() {
  _bats_test_init 1145 'herdr-pane-labels formatter renders a main checkout ref in metadata only'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  # Main checkout (.git directory at the root), branch main, and checkout
  # folder equal to the Herdr workspace name.
  local root="$HPL_WORK/my-mac-setup" state
  mkdir -p "$root/.git"
  hpl_git_location_fixture "$root" "$root" "$root/.git" refs/heads/main
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"my-mac-setup"}'
  hpl_set_process_label pane-1 task
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_BRANCH main"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" task
}

function test_scripts_1146_herdr_pane_labels_formatter_renders_a_worktree_ref_in_m() {
  _bats_test_init 1146 'herdr-pane-labels formatter renders a worktree ref in metadata only'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  # A linked worktree in a folder named exactly like its branch. The worktree
  # icon alone carries the place; a folder qualifier would only repeat the ref.
  local root="$HPL_WORK/feature" common="$HPL_WORK/repository/.git" state
  mkdir -p "$root" "$common"
  hpl_mark_linked_worktree "$root" "$common/worktrees/feature"
  hpl_git_location_fixture "$root" "$root" "$common" refs/heads/feature
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"my-mac-setup"}'
  hpl_set_process_label pane-1 task
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_WORKTREE feature"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" task
}

function test_scripts_1147_herdr_pane_labels_formatter_keeps_a_git_backed_all_idle() {
  _bats_test_init 1147 'herdr-pane-labels formatter keeps a Git-backed all-idle tab names-only'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/repository" state
  mkdir -p "$root/.git"
  hpl_git_location_fixture "$root" "$root" "$root/.git" refs/heads/main
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_proc_info pane-1 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[{"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hpl_proc_info pane-2 '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[{"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "~ 1"
  assert_equal "$(jq -r '.panes[] | .label' "$state" | sort -u)" "~"
  assert_equal "$(jq -r '.panes[] | .tokens.git_ref' "$state" | sort -u)" "$HPL_ICON_BRANCH main"
}

function test_scripts_1148_herdr_pane_labels_git_only_location_changes_do_not_rena() {
  _bats_test_init 1148 'herdr-pane-labels Git-only location changes do not rename a names-only tab'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local one="$HPL_WORK/one" two="$HPL_WORK/two" state
  mkdir -p "$one/.git" "$two/.git"
  hpl_git_location_fixture "$one" "$one" "$one/.git" refs/heads/one
  hpl_git_location_fixture "$two" "$two" "$two/.git" refs/heads/two
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$one")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 worker
  hpl_location_pass
  : > "$HPL_LOG"

  hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-1 "$two" "$two"
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" worker
  assert_equal "$(jq -r '.panes[0].tokens.branch' "$state")" two
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_BRANCH two"
  run grep '^tab rename' "$HPL_LOG"
  assert_failure
}

function test_scripts_1149_herdr_pane_labels_formatter_keeps_the_folder_qualifier_() {
  _bats_test_init 1149 'herdr-pane-labels formatter keeps the folder qualifier on a main checkout in a differently-named folder'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  # Plan decision 5 describes the typical main checkout, whose folder repeats
  # the branch or the workspace name. When the folder differs from BOTH it is
  # real location information, so the sidebar qualifier stays — the same
  # suppression rule as every other checkout, no main-checkout special case.
  local root="$HPL_WORK/setup-copy" state
  mkdir -p "$root/.git"
  hpl_git_location_fixture "$root" "$root" "$root/.git" refs/heads/main
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"my-mac-setup"}'
  hpl_set_process_label pane-1 task
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_BRANCH main"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" task
}

function test_scripts_1150_herdr_pane_labels_formatter_reads_the_workspace_display() {
  _bats_test_init 1150 'herdr-pane-labels formatter reads the workspace display name from the legacy name field when label is absent'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  # Older snapshot shapes carry the workspace display name as `name`; the
  # (.label // .name // "") read must still suppress the folder qualifier when
  # the worktree token merely repeats that name.
  local root="$HPL_WORK/legacy-ws" state
  mkdir -p "$root/.git"
  hpl_git_location_fixture "$root" "$root" "$root/.git" refs/heads/topic
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","name":"legacy-ws"}'
  hpl_set_process_label pane-1 task
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_BRANCH topic"
}

function test_scripts_1151_herdr_pane_labels_formatter_gives_a_detached_head_insid() {
  _bats_test_init 1151 'herdr-pane-labels formatter gives a detached HEAD inside a linked worktree the commit icon'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  # The commit place deliberately wins over the worktree place: the detached
  # short SHA locates the pane more precisely than worktree-ness does, and the
  # folder qualifier still names the linked worktree in the sidebar.
  local root="$HPL_WORK/wt-detached" common="$HPL_WORK/repository/.git" state
  mkdir -p "$root" "$common"
  hpl_mark_linked_worktree "$root" "$common/worktrees/wt-detached"
  hpl_git_location_fixture "$root" "$root" "$common" HEAD a1b2c3d
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"repository"}'
  hpl_set_process_label pane-1 task
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_COMMIT a1b2c3d"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" task
}

function test_scripts_1152_herdr_pane_labels_formatter_qualifies_a_divergent_workt() {
  _bats_test_init 1152 'herdr-pane-labels formatter qualifies a divergent worktree folder in metadata only'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  # A divergent folder remains useful in the sidebar while the tab stays
  # limited to the two pane labels.
  local root="$HPL_WORK/wt-hotfix" common="$HPL_WORK/repository/.git" state
  mkdir -p "$root" "$common"
  hpl_mark_linked_worktree "$root" "$common/worktrees/wt-hotfix"
  hpl_git_location_fixture "$root" "$root" "$common" refs/heads/fix-login
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"my-mac-setup"}'
  hpl_set_process_label pane-1 alpha
  hpl_set_process_label pane-2 beta
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[] | .tokens.git_ref' "$state" | sort -u)" "$HPL_ICON_WORKTREE fix-login"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "alpha · beta"
}

function test_scripts_1206_herdr_pane_labels_names_the_space_a_worktree_space_ca() {
  _bats_test_init 1206 'herdr-pane-labels names the space a worktree space came from, and only when it adds something'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  # given: a worktree space labelled by its task, a worktree space whose label
  # already is the repository name, and a space herdr reports no worktree for
  local work="$HPL_WORK/work" state
  mkdir -p "$work"
  hpl_git_fixture "$work" "" 1 ready 'fatal: not a git repository'
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$work")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-2 "$work" | jq -c '.workspace_id = "ws-2"')"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-3 tab-3 "$work" | jq -c '.workspace_id = "ws-3"')"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-2","workspace_id":"ws-2","label":""}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-3","workspace_id":"ws-3","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"Task Name","worktree":{"repo_name":"repository","is_linked_worktree":true}}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-2","label":"repository","worktree":{"repo_name":"repository","is_linked_worktree":false}}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-3","label":"IronVault"}'
  hpl_set_process_label pane-1 one
  hpl_set_process_label pane-2 two
  hpl_set_process_label pane-3 three

  # when: one location/presentation pass runs
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"

  # then: only the space whose label differs from its repository names the parent
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.space_origin' "$state")" repository
  run jq -e '.panes[] | select(.pane_id == "pane-2") | .tokens.space_origin == null' "$state"
  assert_success
  run jq -e '.panes[] | select(.pane_id == "pane-3") | .tokens.space_origin == null' "$state"
  assert_success
}

function test_scripts_1207_herdr_pane_labels_reports_branch_and_counts_as_space_() {
  _bats_test_init 1207 'herdr-pane-labels reports branch and status counts as space metadata, and clears them off a non-Git space'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  # given: a worktree checkout whose status carries every category, and a
  # second space whose pane sits outside any checkout
  local root="$HPL_WORK/wt" common="$HPL_WORK/repository/.git" outside="$HPL_WORK/outside" state
  mkdir -p "$root" "$common" "$outside"
  hpl_mark_linked_worktree "$root" "$common/worktrees/wt"
  hpl_git_location_fixture "$root" "$root" "$common" refs/heads/feature
  hpl_git_status_fixture "$root" '# branch.oid abc
# branch.head feature
# branch.upstream origin/feature
# branch.ab +2 -1
1 M. N... 100644 100644 100644 aaa bbb staged-only.txt
1 .M N... 100644 100644 100644 aaa bbb unstaged-only.txt
1 MM N... 100644 100644 100644 aaa bbb both.txt
u UU N... 100644 100644 100644 100644 aaa bbb ccc conflicted.txt
? untracked.txt'
  hpl_git_fixture "$outside" "" 1 ready 'fatal: not a git repository'
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-2 "$outside" | jq -c '.workspace_id = "ws-2"')"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-2","workspace_id":"ws-2","label":""}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-1","label":"Task Name"}'
  hpl_set_workspace "$HPL_DEFAULT_SOCKET" '{"workspace_id":"ws-2","label":"Elsewhere","tokens":{"branch":"stale","git_status":"stale"}}'
  hpl_set_process_label pane-1 one
  hpl_set_process_label pane-2 two

  # when: one location/presentation pass runs
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"

  # then: the worktree space carries its branch and one count per category,
  # ordered pull, push, conflicts, staged, unstaged, untracked
  assert_equal "$(jq -r '.workspaces[] | select(.workspace_id == "ws-1") | .tokens.branch' "$state")" feature
  assert_equal "$(jq -r '.workspaces[] | select(.workspace_id == "ws-1") | .tokens.git_status' "$state")" \
    "${HPL_ICON_PULL}1 ${HPL_ICON_PUSH}2 ~1 +2 !2 ?1"
  # then: the space with no checkout sheds the tokens it was carrying
  run jq -e '.workspaces[] | select(.workspace_id == "ws-2") | (.tokens // {}) == {}' "$state"
  assert_success
}

function test_scripts_1153_herdr_pane_labels_formatter_keeps_mixed_git_identities_() {
  _bats_test_init 1153 'herdr-pane-labels formatter keeps mixed Git identities out of tabs and repairs external labels'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root_a="$HPL_WORK/a" root_b="$HPL_WORK/b" common_a="$HPL_WORK/a/.git" common_b="$HPL_WORK/b/.git"
  local cwd_a="$root_a/work" cwd_b="$root_b/work" outside="$HPL_WORK/outside" missing="$root_b/missing" state
  mkdir -p "$cwd_a" "$cwd_b" "$outside" "$common_a" "$common_b"
  hpl_git_location_fixture "$cwd_a" "$root_a" "$common_a" refs/heads/dev
  hpl_git_location_fixture "$cwd_b" "$root_b" "$common_b" refs/heads/main
  hpl_git_fixture "$outside" "" 1 ready 'fatal: not a git repository'
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$cwd_a")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$cwd_b")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 first
  hpl_set_process_label pane-2 second
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "first · second"

  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$cwd_b" present "$missing")"
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane rename pane-1 divergent-pane
  hpl_socket_run "$HPL_DEFAULT_SOCKET" tab rename tab-1 divergent-tab
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .label' "$state")" first
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "first · second"

  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$outside")"
  hpl_location_pass
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "first · second"
}

function test_scripts_1154_herdr_pane_labels_formatter_joins_only_pane_labels_when() {
  _bats_test_init 1154 'herdr-pane-labels formatter joins only pane labels when three panes span two repositories'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root_a="$HPL_WORK/a" root_b="$HPL_WORK/b" state
  mkdir -p "$root_a/.git" "$root_b/.git"
  hpl_git_location_fixture "$root_a" "$root_a" "$root_a/.git" refs/heads/dev
  hpl_git_location_fixture "$root_b" "$root_b" "$root_b/.git" refs/heads/main
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root_a")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$root_a")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-3 tab-1 "$root_b")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 one
  hpl_set_process_label pane-2 two
  hpl_set_process_label pane-3 three
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" \
    "one · two · three"
}

function test_scripts_1155_herdr_pane_labels_worktree_tokens_use_shortest_unique_s() {
  _bats_test_init 1155 'herdr-pane-labels worktree tokens use shortest unique slash suffixes for basename collisions'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local one="$HPL_WORK/team/feature" two="$HPL_WORK/release/feature" common="$HPL_WORK/repository/.git" state
  mkdir -p "$one" "$two" "$common"
  hpl_mark_linked_worktree "$one" "$common/worktrees/one"
  hpl_mark_linked_worktree "$two" "$common/worktrees/two"
  hpl_git_location_fixture "$one" "$one" "$common" refs/heads/one
  hpl_git_location_fixture "$two" "$two" "$common" refs/heads/two
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$one")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$two")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 alpha
  hpl_set_process_label pane-2 beta
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.worktree' "$state")" team/feature
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-2") | .tokens.worktree' "$state")" release/feature
  # The slash-suffix folder token appears only in the sidebar qualifier.
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-1") | .tokens.git_ref' "$state")" "$HPL_ICON_WORKTREE one"
  assert_equal "$(jq -r '.panes[] | select(.pane_id == "pane-2") | .tokens.git_ref' "$state")" "$HPL_ICON_WORKTREE two"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "alpha · beta"
}

function test_scripts_1156_herdr_pane_labels_worktree_tokens_digest_overlong_roots() {
  _bats_test_init 1156 'herdr-pane-labels worktree tokens digest overlong roots and extend colliding digest prefixes'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local unique="$HPL_WORK/extraordinarily-long-worktree"
  local one="$HPL_WORK/parent-component-that-is-long-one/shared-overlong-name"
  local two="$HPL_WORK/parent-component-that-is-long-two/shared-overlong-name"
  local common="$HPL_WORK/repository/.git" digests="$HPL_WORK/digests" state token_one token_two
  mkdir -p "$unique" "$one" "$two" "$common"
  hpl_git_location_fixture "$unique" "$unique" "$common" refs/heads/unique
  hpl_git_location_fixture "$one" "$one" "$common" refs/heads/one
  hpl_git_location_fixture "$two" "$two" "$common" refs/heads/two
  printf '%s\037%s\n%s\037%s\n' "$one" abcdef00000000000000000000000000 "$two" abcdef10000000000000000000000000 > "$digests"
  export HERDR_PANE_LABELS_TEST_DIGEST_FILE="$digests"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$unique")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$one")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-3 tab-1 "$two")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  for pane_id in pane-1 pane-2 pane-3; do hpl_set_process_label "$pane_id" task; done
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  run jq -e '[.panes[].tokens.worktree | select(length <= 18 and test("^[A-Za-z0-9._/-]+~[0-9a-f]{6,}$"))] | length == 3' "$state"
  assert_success
  token_one="$(jq -r '.panes[] | select(.pane_id == "pane-2") | .tokens.worktree' "$state")"
  token_two="$(jq -r '.panes[] | select(.pane_id == "pane-3") | .tokens.worktree' "$state")"
  run test "$token_one" != "$token_two"
  assert_success
  run grep -Eq 'abcdef$' <<<"$token_one
$token_two"
  assert_success
  run grep -Eq 'abcdef[01]$' <<<"$token_one
$token_two"
  assert_success
}

function test_scripts_1157_herdr_pane_labels_worktree_token_ordinal_fallback_is_un() {
  _bats_test_init 1157 'herdr-pane-labels worktree token ordinal fallback is unique and stable under pane reordering'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local common="$HPL_WORK/repository/.git" digests="$HPL_WORK/digests" panes='[]' before after i root
  mkdir -p "$common"
  : > "$digests"
  for i in $(seq 1 12); do
    root="$HPL_WORK/parent-component-that-is-deliberately-long-$i/shared-overlong-name"
    mkdir -p "$root"
    hpl_git_location_fixture "$root" "$root" "$common" "refs/heads/b$i"
    printf '%s\037%s\n' "$root" ffffffffffffffffffffffffffffffff >> "$digests"
    panes="$(jq -c --argjson pane "$(hpl_process_pane_json "pane-$i" tab-1 "$root")" '. + [$pane]' <<< "$panes")"
    hpl_set_process_label "pane-$i" task
  done
  export HERDR_PANE_LABELS_TEST_DIGEST_FILE="$digests"
  hpl_pane_list "$(jq -cn --argjson panes "$panes" '{result:{panes:$panes}}')"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_location_pass
  before="$(jq -c '[.panes | sort_by(.pane_id)[] | [.pane_id,.tokens.worktree]]' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")"
  run jq -e '[.panes[].tokens.worktree] | length == 12 and (unique | length == 12) and all(.[]; length <= 18)' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_success
  local state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")" tmp="$HPL_WORK/reversed.json"
  jq '.panes |= reverse' "$state" > "$tmp" && mv "$tmp" "$state"
  hpl_location_pass
  after="$(jq -c '[.panes | sort_by(.pane_id)[] | [.pane_id,.tokens.worktree]]' "$state")"
  assert_equal "$after" "$before"
}

function test_scripts_1158_herdr_pane_labels_long_branch_refs_stay_in_metadata_and() {
  _bats_test_init 1158 'herdr-pane-labels long branch refs stay in metadata and do not alter the tab label'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/worktree" common="$HPL_WORK/repository/.git" state
  local long_ref="feature/very-long-branch-name-that-overflows"
  mkdir -p "$root" "$common"
  hpl_mark_linked_worktree "$root" "$common/worktrees/one"
  hpl_git_location_fixture "$root" "$root" "$common" "refs/heads/$long_ref"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 task
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" task
  assert_equal "$(jq -r '.panes[0].tokens.branch' "$state")" "$long_ref"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_WORKTREE $long_ref"
}

function test_scripts_1159_herdr_pane_labels_long_repository_names_do_not_alter_a_() {
  _bats_test_init 1159 'herdr-pane-labels long repository names do not alter a multi-repo tab label'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local one="$HPL_WORK/integration-platform-connectors"
  local two="$HPL_WORK/internal-developer-tooling"
  local common_one="$one/.git" common_two="$two/.git" state
  mkdir -p "$common_one" "$common_two"
  hpl_git_location_fixture "$one" "$one" "$common_one" refs/heads/feat/connector-runtime-rewrite
  hpl_git_location_fixture "$two" "$two" "$common_two" refs/heads/fix/oauth-refresh-loop-retry
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$one")"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-2 tab-1 "$two")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 first
  hpl_set_process_label pane-2 second
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.tabs[0].label' "$state")" "first · second"
  assert_equal "$(jq -r '.panes[] | .tokens.repo' "$state" | sort)" $'integration-platform-connectors\ninternal-developer-tooling'
}

function test_scripts_1160_herdr_pane_labels_location_clears_a_retired_location_la() {
  _bats_test_init 1160 'herdr-pane-labels location clears a retired location_label even when every published token already matches'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/repository" common="$HPL_WORK/repository/.git" state
  mkdir -p "$common"
  hpl_git_location_fixture "$root" "$root" "$common" refs/heads/topic
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 worker
  # given: one pass has already published every current token
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_BRANCH topic"
  assert_equal "$(jq -r '.panes[0].tokens.location_label // ""' "$state")" ""
  # given: a stale daemon of the retired version puts location_label back while
  # leaving every token this version compares untouched. It reports under the
  # same source at the sequence the last pass used, which is what an old daemon
  # sharing the generation counter does.
  local legacy_seq
  legacy_seq="$(jq -r '.metadata["pane-1"]["location-sync"].seq' "$state")"
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane report-metadata pane-1 \
    --source location-sync --seq "$legacy_seq" --token 'location_label=repository/topic'
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.location_label' "$state")" repository/topic
  # when: the next pass computes identical tokens and would otherwise skip
  hpl_location_pass
  # then: the legacy token is gone and the live tokens are unharmed
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].tokens.location_label // ""' "$state")" ""
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_BRANCH topic"
  assert_equal "$(jq -r '.panes[0].tokens.branch' "$state")" topic
}

function test_scripts_1161_herdr_pane_labels_location_and_formatter_add_only_appro() {
  _bats_test_init 1161 'herdr-pane-labels location and formatter add only approved static icon glyphs and no forbidden ownership state'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local root="$HPL_WORK/plain-worktree" common="$HPL_WORK/repository/.git" state
  mkdir -p "$root" "$common"
  hpl_mark_linked_worktree "$root" "$common/worktrees/plain"
  hpl_git_location_fixture "$root" "$root" "$common" refs/heads/plain
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$root")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_set_process_label pane-1 plain-task
  hpl_location_pass
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  run grep -ER 'manual_owner|reclaim|label_ledger|server_epoch|takeover|prepare_rollback' "$(hpl_namespace "$HPL_DEFAULT_SOCKET")"
  assert_failure
  # After removing every approved codicon glyph, only plain ASCII (plus the
  # label separator and ellipsis) may remain in published labels and tokens.
  run jq -e --arg icons "$HPL_ICON_BRANCH$HPL_ICON_WORKTREE$HPL_ICON_COMMIT$HPL_ICON_FOLDER$HPL_ICON_STALE" '
    [.panes[0].label, .tabs[0].label, .panes[0].tokens.worktree, .panes[0].tokens.git_ref]
    | all(.[]; (. // "") | explode - ($icons | explode) | implode | test("^[A-Za-z0-9._:/ ~\u00b7\u2026-]*$"))
  ' "$state"
  assert_success
  assert_equal "$(jq -r '.tabs[0].label' "$state")" plain-task
  assert_equal "$(jq -r '.panes[0].tokens.git_ref' "$state")" "$HPL_ICON_WORKTREE plain"
  # pane_inline stays deferred per the label-system plan: no pass publishes it.
  assert_equal "$(jq -r '.panes[0].tokens.pane_inline // ""' "$state")" ""
}

function test_scripts_1208_herdr_pane_labels_icon_constants_stay_independent_of_th() {
  _bats_test_init 1208 'herdr-pane-labels icon constants stay independent of the engine glyph table'
  # Every HPL_ICON_* comparison above is only a test while its expected bytes
  # come from somewhere the engine cannot reach. A harness that read the ICON_
  # table out of the engine was removed once and then carried back in by a
  # rename, and while it was in place a changed codepoint moved both sides at
  # once and every icon assertion stayed green. Load the harness against a source
  # tree whose engine declares a different ICON_BRANCH: a derived constant
  # follows the mutation, a pinned one does not. Rewriting the whole assignment
  # keeps this test independent of whichever codepoint ICON_BRANCH holds today.
  local root="$BATS_TEST_TMPDIR/mutated-engine" harness
  harness="$BATS_TEST_DIRNAME/helpers/herdr_pane_labels.bash"
  mkdir -p "$root/bin"
  # U+2714 heavy check mark — a glyph the pane-label grammar never uses.
  sed "s|^ICON_BRANCH=.*|ICON_BRANCH=\"\$(printf '\\\\342\\\\234\\\\224')\"|" \
    "$HPL_ENGINE" > "$root/bin/herdr-pane-labels"
  assert_file_contains "$root/bin/herdr-pane-labels" \
    'ICON_BRANCH=.*\\342\\234\\224'

  run env SOURCE_ROOT="$root" bash -c 'source "$1"; printf %s "$HPL_ICON_BRANCH"' _ "$harness"
  assert_success
  assert_output "$HPL_ICON_BRANCH"
}

function test_scripts_1162_herdr_pane_labels_plugin_exposes_only_the_approved_pane() {
  _bats_test_init 1162 'herdr-pane-labels plugin exposes only the approved pane and tab invalidations'
  local manifest="$HPL_PLUGIN_DIR/herdr-plugin.toml"
  run awk '
    /^on = "/ {
      event = $0
      sub(/^on = "/, "", event)
      sub(/"$/, "", event)
      next
    }
    /^command = / && event != "" {
      command = $0
      sub(/^command = /, "", command)
      print event "|" command
      event = ""
    }
  ' "$manifest"
  assert_success
  assert_output $'pane.created|["sh", "bin/ensure.sh", "--event"]\npane.moved|["sh", "bin/ensure.sh", "--event"]\npane.exited|["sh", "bin/ensure.sh", "--event"]\npane.closed|["sh", "bin/ensure.sh", "--event"]\npane.agent_detected|["sh", "bin/ensure.sh", "--event"]\npane.agent_status_changed|["sh", "bin/ensure.sh", "--event"]\ntab.created|["sh", "bin/ensure.sh", "--event"]\ntab.closed|["sh", "bin/ensure.sh", "--event"]\ntab.moved|["sh", "bin/ensure.sh", "--event"]\ntab.renamed|["sh", "bin/ensure.sh", "--event"]\nworktree.created|["sh", "bin/ensure.sh", "--event"]\nworktree.opened|["sh", "bin/ensure.sh", "--event"]'
  assert_file_contains "$manifest" '^min_herdr_version = "0\.8\.2"$'
  assert_file_contains "$manifest" '^id = "sweep"$'
  assert_file_contains "$manifest" '^title = "Pane labels: refresh now"$'
  assert_file_contains "$manifest" '^command = \["sh", "bin/sweep\.sh"\]$'
  run grep -E '^on = ".*\*|^on = "(pane\.updated|workspace\.focused|tab\.focused|pane\.focused)"|reclaim' "$manifest"
  assert_failure
}

function test_scripts_1163_herdr_pane_labels_plugin_wrappers_invoke_one_engine_mod() {
  _bats_test_init 1163 'herdr-pane-labels plugin wrappers invoke one engine mode and isolate failures'
  local package="$BATS_TEST_TMPDIR/package" engine_log="$BATS_TEST_TMPDIR/plugin-engine.log"
  mkdir -p "$package/bin"
  cp "$HPL_PLUGIN_DIR/bin/ensure.sh" "$package/bin/ensure.sh"
  cp "$HPL_PLUGIN_DIR/bin/sweep.sh" "$package/bin/sweep.sh"
  cat > "$package/bin/herdr-pane-labels" <<'SH'
#!/bin/sh
printf '%s|%s|%s\n' "${HPL_PLUGIN_CASE:-}" "$1" "${HERDR_SOCKET_PATH:-}" >> "$HPL_PLUGIN_ENGINE_LOG"
printf 'unexpected stdout\n'
printf 'unexpected stderr\n' >&2
[ "${HPL_PLUGIN_FAIL_ARG:-}" != "$1" ] || exit 23
exit 0
SH
  chmod +x "$package/bin/herdr-pane-labels"

  run env HOME="$BATS_TEST_TMPDIR/home" HERDR_SOCKET_PATH=/tmp/u5.sock \
    HPL_PLUGIN_ENGINE_LOG="$engine_log" HPL_PLUGIN_CASE=startup \
    HPL_PLUGIN_FAIL_ARG=--ensure-sweep-daemon sh "$package/bin/ensure.sh"
  assert_success
  assert_output ""
  run env HOME="$BATS_TEST_TMPDIR/home" HERDR_SOCKET_PATH=/tmp/u5.sock \
    HPL_PLUGIN_ENGINE_LOG="$engine_log" HPL_PLUGIN_CASE=event-fails \
    HPL_PLUGIN_FAIL_ARG=--event sh "$package/bin/ensure.sh" --event
  assert_success
  assert_output ""
  run env HOME="$BATS_TEST_TMPDIR/home" HERDR_SOCKET_PATH=/tmp/u5.sock \
    HPL_PLUGIN_ENGINE_LOG="$engine_log" HPL_PLUGIN_CASE=sweep \
    HPL_PLUGIN_FAIL_ARG=--sweep sh "$package/bin/sweep.sh"
  assert_success
  assert_output ""
  run cat "$engine_log"
  assert_output $'startup|--ensure-sweep-daemon|/tmp/u5.sock\nevent-fails|--event|/tmp/u5.sock\nsweep|--sweep|/tmp/u5.sock'
}

function test_scripts_1164_herdr_pane_labels_event_requests_reconciliation_and_ens() {
  _bats_test_init 1164 'herdr-pane-labels event requests reconciliation and ensures the daemon fail-open'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local namespace reconcile sweep_lock pending pid owner start socket_record
  namespace="$(hpl_namespace "$HPL_DEFAULT_SOCKET")"
  reconcile="$namespace/reconcile.state"
  sweep_lock="$namespace/sweep.lock"

  HERDR_PANE_LABELS_TEST_NO_PRESENTATION=1 hpl_event_run
  pending="$(hpl_record_number "$reconcile" pending_generation)"
  mkdir "$namespace/presentation-inbox.lock"
  owner="event-test-owner"
  start="$(ps -p "$$" -o lstart= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  socket_record="owner_id=$(printf '%s' "$owner" | base64 | tr -d '\n')
pid=$$
process_start=$(printf '%s' "$start" | base64 | tr -d '\n')
socket_path=$(printf '%s' "$HPL_DEFAULT_SOCKET" | base64 | tr -d '\n')"
  printf '%s\n' "$socket_record" > "$namespace/presentation-inbox.lock/owner"

  export HERDR_PANE_LABELS_TEST_NO_DAEMON=
  export HERDR_PANE_LABELS_LOCK_ATTEMPTS=1
  run hpl_event_run
  unset HERDR_PANE_LABELS_TEST_NO_DAEMON HERDR_PANE_LABELS_LOCK_ATTEMPTS
  assert_success
  hpl_wait_for_file "$sweep_lock/pid"
  assert_equal "$(hpl_record_number "$reconcile" pending_generation)" "$pending"
  pid="$(cat "$sweep_lock/pid")"
  kill "$pid" 2>/dev/null || true
  rm -f "$namespace/presentation-inbox.lock/owner"
  rmdir "$namespace/presentation-inbox.lock"

}

function test_scripts_1165_herdr_pane_labels_sweep_repairs_an_external_pane_rename() {
  _bats_test_init 1165 'herdr-pane-labels sweep repairs an external pane rename without pane.updated'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf
  hpl_sweep_run --sweep
  hpl_socket_run "$HPL_DEFAULT_SOCKET" pane rename pane-1 external-label
  assert_equal "$(jq -r '.panes[0].label' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" external-label

  : > "$HPL_LOG"
  run hpl_sweep_run --sweep
  assert_success
  assert_equal "$(jq -r '.panes[0].label' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" cc:red-wolf
  assert_file_contains "$HPL_LOG" '^pane rename pane-1 cc:red-wolf$'
}

function test_scripts_1166_herdr_pane_labels_sweep_repairs_process_and_cwd_changes() {
  _bats_test_init 1166 'herdr-pane-labels sweep repairs process and CWD changes through the presentation coordinator'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local old="$HPL_WORK/repos/old" new="$HPL_WORK/repos/new-worktree" common="$HPL_WORK/repos/.git"
  mkdir -p "$old" "$new" "$common"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(hpl_process_pane_json pane-1 tab-1 "$old" present "$old")"
  hpl_set_tab "$HPL_DEFAULT_SOCKET" '{"tab_id":"tab-1","workspace_id":"ws-1","label":""}'
  hpl_git_location_fixture "$old" "$old" "$common" refs/heads/old
  hpl_set_process_label pane-1 btop
  # hpl_location_pass, not bare hpl_event_run: this pass asserts a worktree
  # token, so its git probe needs the calibrated HPL_GIT_BUDGET instead of the
  # shipped 75 ms bound (killed probe -> tokens.worktree null under load).
  hpl_location_pass
  assert_equal "$(jq -r '.panes[0].label' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" btop
  assert_equal "$(jq -r '.panes[0].tokens.worktree' "$(hpl_socket_state "$HPL_DEFAULT_SOCKET")")" old

  hpl_git_location_fixture "$new" "$new" "$common" refs/heads/new-branch
  hpl_set_pane_location "$HPL_DEFAULT_SOCKET" pane-1 "$new" "$new"
  hpl_set_process_label pane-1 'cargo test'
  : > "$HPL_LOG"
  run hpl_sweep_run --sweep
  assert_success

  local state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  assert_equal "$(jq -r '.panes[0].label' "$state")" "cargo test"
  assert_equal "$(jq -r '.panes[0].tokens.worktree' "$state")" new-worktree
  assert_file_contains "$HPL_LOG" '^api snapshot$'
  assert_file_contains "$HPL_LOG" '^pane rename pane-1 cargo test$'
}

function test_scripts_1167_herdr_pane_labels_names_a_command_pane_after_the_proces() {
  _bats_test_init 1167 'herdr-pane-labels names a command pane after the process group leader'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","name":"red-wolf","label":"agent-label"},
    {"pane_id":"pane-2","tab_id":"tab-1","agent":null,"label":null}]}}'
  hpl_proc_info pane-2 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[
      {"pid":201,"name":"node","argv0":"node","argv":["node","-e","timer"]},
      {"pid":200,"name":"bun","argv0":"bun","argv":["bun","run","dev"]}]}}}'
  hpl_sweep_run --sweep
  assert_equal "$(hpl_pane_label pane-2)" "bun run dev"
  run grep -m1 '^tab rename' "$HPL_LOG"
  assert_output "tab rename tab-1 cc:red-wolf · bun run dev"
}

# A pane whose foreground process group is its own shell runs nothing. It keeps
# its slot in the tab label under a placeholder instead of disappearing.
function test_scripts_1168_herdr_pane_labels_names_an_idle_pane_with_the_placehold() {
  _bats_test_init 1168 'herdr-pane-labels names an idle pane with the placeholder'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","name":"red-wolf","label":"agent-label"},
    {"pane_id":"pane-2","tab_id":"tab-1","agent":null,"label":"btop"}]}}'
  hpl_proc_info pane-2 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hpl_sweep_run --sweep
  assert_equal "$(hpl_pane_label pane-2)" "~"
  run grep -m1 '^tab rename' "$HPL_LOG"
  assert_output "tab rename tab-1 cc:red-wolf · ~"
}

# The session coordinator knows tab position, so task invalidation and sweeps
# use the same numbered placeholder for an all-idle tab.
function test_scripts_1169_herdr_pane_labels_presentation_numbers_an_all_idle_tab() {
  _bats_test_init 1169 'herdr-pane-labels presentation numbers an all-idle tab'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":null,"label":null}]}}'
  hpl_proc_info pane-1 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hpl_sweep_run --sweep
  assert_equal "$(hpl_pane_label pane-1)" "~"
}

# One pane must not eat the whole tab label, so a long command name is cut to
# 24 characters with a trailing ellipsis. Flags and paths drop out entirely.
function test_scripts_1170_herdr_pane_labels_truncates_a_long_command_name() {
  _bats_test_init 1170 'herdr-pane-labels truncates a long command name'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":null,"label":null}]}}'
  hpl_proc_info pane-1 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[
      {"pid":200,"name":"long","argv0":"/opt/bin/averyveryverylongcommandname",
       "argv":["/opt/bin/averyveryverylongcommandname","--flag","/tmp/path","sub"]}]}}}'
  hpl_sweep_run --sweep
  run grep -m1 '^tab rename' "$HPL_LOG"
  assert_output "tab rename tab-1 averyveryverylongcomman…"
}

# A naming call refreshes only its own tab, so a command that ends and an agent
# that quits leave a stale label behind. The sweep is the observer for both: it
# walks every tab herdr knows, not just the one that triggered it.
function test_scripts_1171_herdr_pane_labels_sweep_relabels_every_tab() {
  _bats_test_init 1171 'herdr-pane-labels --sweep relabels every tab'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_tab_list '{"result":{"tabs":[
    {"tab_id":"tab-1","label":"1"},
    {"tab_id":"tab-2","label":"2"}]}}'
  hpl_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","label":"agent-label"},
    {"pane_id":"pane-2","tab_id":"tab-2","agent":null,"label":null}]}}'
  hpl_proc_info pane-2 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[
      {"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  run hpl_sweep_run --sweep
  assert_success
  run grep -c '^tab rename' "$HPL_LOG"
  assert_output "2"
  run grep '^tab rename tab-2' "$HPL_LOG"
  assert_output "tab rename tab-2 btop"
}

function test_scripts_1172_herdr_pane_labels_sweep_reports_a_failed_reconciliation() {
  _bats_test_init 1172 'herdr-pane-labels --sweep reports a failed reconciliation'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local dir
  dir="$(hpl_socket_dir "$HPL_DEFAULT_SOCKET")"
  : > "$dir/fail-snapshot"

  run hpl_sweep_run --sweep

  assert_failure
}

function test_scripts_1173_herdr_pane_labels_strict_sweep_rejects_failed_and_unapp() {
  _bats_test_init 1173 'herdr-pane-labels strict sweep rejects failed and unapplied presentation writes'
  command -v jq >/dev/null || skip "jq not available"
  local marker
  for marker in fail-pane-rename drop-pane-rename fail-tab-rename drop-tab-rename; do
    hpl_setup
    hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf
    : > "$HPL_WORK/$marker"
    export HERDR_PANE_LABELS_STRICT_SWEEP=1

    run hpl_sweep_run --sweep

    assert_failure
    unset HERDR_PANE_LABELS_STRICT_SWEEP
    hpl_teardown
  done

  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude red-wolf
  hpl_transform_state "$HPL_DEFAULT_SOCKET" '.panes[0].tokens = {repo:"repo",worktree:"main",branch:"main",git_ref:"main",location_label:"legacy"}'
  : > "$HPL_WORK/fail-pane-report"
  export HERDR_PANE_LABELS_STRICT_SWEEP=1
  run hpl_sweep_run --sweep
  assert_failure
  unset HERDR_PANE_LABELS_STRICT_SWEEP
}

# The daemon sweeps every few seconds. Renaming a tab to the label it already
# carries would churn the tab row and the socket for nothing.
function test_scripts_1174_herdr_pane_labels_sweep_leaves_an_unchanged_tab_label_a() {
  _bats_test_init 1174 'herdr-pane-labels --sweep leaves an unchanged tab label alone'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_tab_list '{"result":{"tabs":[{"tab_id":"tab-1","label":"btop"}]}}'
  hpl_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":null,"label":"btop"}]}}'
  hpl_proc_info pane-1 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":200,"foreground_processes":[
      {"pid":200,"name":"btop","argv0":"btop","argv":["btop"]}]}}}'
  run hpl_sweep_run --sweep
  assert_success
  run cat "$HPL_LOG"
  refute_output --partial "tab rename"
  refute_output --partial "pane rename"
}

# An all-idle tab is numbered instead of skipped, or its last composed label
# would outlive the pane that produced it. The number counts tabs inside one
# workspace, because a tab row shows one workspace at a time.
function test_scripts_1175_herdr_pane_labels_sweep_numbers_all_idle_tabs_per_works() {
  _bats_test_init 1175 'herdr-pane-labels --sweep numbers all-idle tabs per workspace'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_tab_list '{"result":{"tabs":[
    {"tab_id":"tab-1","workspace_id":"ws-1","label":"1"},
    {"tab_id":"tab-2","workspace_id":"ws-1","label":"stale name"},
    {"tab_id":"tab-3","workspace_id":"ws-2","label":"2"}]}}'
  hpl_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":null,"label":null},
    {"pane_id":"pane-2","tab_id":"tab-2","agent":null,"label":null},
    {"pane_id":"pane-3","tab_id":"tab-3","workspace_id":"ws-2","agent":null,"label":null}]}}'
  hpl_proc_info pane-1 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hpl_proc_info pane-2 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  hpl_proc_info pane-3 '{"result":{"process_info":{
    "shell_pid":100,"foreground_process_group_id":100,"foreground_processes":[
      {"pid":100,"name":"zsh","argv0":"zsh","argv":["-zsh"]}]}}}'
  run hpl_sweep_run --sweep
  assert_success
  run grep '^tab rename' "$HPL_LOG"
  assert_line "tab rename tab-1 ~ 1"
  assert_line "tab rename tab-2 ~ 2"
  assert_line "tab rename tab-3 ~ 1"
}

# herdr fires the plugin hook on every agent state change, so the guard has to
# be cheap and exact: one daemon per machine, however often it is called.
function test_scripts_1176_herdr_pane_labels_ensure_sweep_daemon_keeps_a_single_da() {
  _bats_test_init 1176 'herdr-pane-labels --ensure-sweep-daemon keeps a single daemon'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  sleep 30 &
  local live=$! sweep_lock="$(hpl_namespace "$HPL_DEFAULT_SOCKET")/sweep.lock"
  mkdir -p "$sweep_lock"
  printf '%s' "$live" > "$sweep_lock/pid"
  ps -p "$live" -o lstart= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' > "$sweep_lock/start"
  run hpl_sweep_run --ensure-sweep-daemon
  assert_success
  assert_equal "$(cat "$sweep_lock/pid")" "$live"
  cat > "$HPL_STUB/ps" <<'SH'
#!/bin/sh
exit 1
SH
  chmod +x "$HPL_STUB/ps"
  run hpl_sweep_run --ensure-sweep-daemon
  assert_success
  assert_equal "$(cat "$sweep_lock/pid")" "$live"
  kill "$live" 2>/dev/null || true
}

# A daemon killed with its herdr session leaves the lock behind. The next hook
# must clear it and start a new daemon, or labels stay frozen until a restart.
function test_scripts_1177_herdr_pane_labels_ensure_sweep_daemon_replaces_a_dead_d() {
  _bats_test_init 1177 'herdr-pane-labels --ensure-sweep-daemon replaces a dead daemon'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  hpl_tab_list '{"result":{"tabs":[{"tab_id":"tab-1","label":"1"}]}}'
  hpl_pane_list '{"result":{"panes":[
    {"pane_id":"pane-1","tab_id":"tab-1","agent":"claude","label":"agent-label"}]}}'
  local sweep_lock="$(hpl_namespace "$HPL_DEFAULT_SOCKET")/sweep.lock"
  mkdir -p "$sweep_lock"
  # A pid that cannot be running: process ids are allocated from 1 upwards.
  printf '%s' "999999" > "$sweep_lock/pid"
  run hpl_sweep_run --ensure-sweep-daemon
  assert_success
  hpl_wait_for_call 'tab rename'
  local pid; pid="$(cat "$sweep_lock/pid" 2>/dev/null)"
  [ -n "$pid" ] && [ "$pid" != "999999" ]
  kill "$pid" 2>/dev/null || true
}

function test_scripts_1178_herdr_pane_labels_sweep_daemon_exits_after_three_unreac() {
  _bats_test_init 1178 'herdr-pane-labels sweep daemon exits after three unreachable snapshots'
  command -v jq >/dev/null || skip "jq not available"
  hpl_setup
  local dir daemon_pid i ps_attempts="$HPL_WORK/ps-attempts"
  dir="$(hpl_socket_dir "$HPL_DEFAULT_SOCKET")"
  : > "$dir/fail-snapshot"
  cat > "$HPL_STUB/ps" <<'SH'
#!/usr/bin/env bash
attempt=0
[ ! -f "$HPL_PS_ATTEMPTS" ] || attempt="$(cat "$HPL_PS_ATTEMPTS")"
attempt=$((attempt + 1))
printf '%s' "$attempt" > "$HPL_PS_ATTEMPTS"
[ "$attempt" -ne 1 ] || exit 1
exec /bin/ps "$@"
SH
  chmod +x "$HPL_STUB/ps"
  HPL_PS_ATTEMPTS="$ps_attempts" HPL_SWEEP_INTERVAL=0.01 \
    hpl_sweep_run --sweep-daemon &
  daemon_pid=$!
  for i in $(seq 1 $HPL_WAIT_POLLS); do
    kill -0 "$daemon_pid" 2>/dev/null || break
    sleep 0.01
  done
  if kill -0 "$daemon_pid" 2>/dev/null; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    fail "sweep daemon kept polling an unreachable socket"
  fi
  wait "$daemon_pid"
  run test "$(cat "$ps_attempts")" -ge 2
  assert_success
  run grep -c '^api snapshot$' "$HPL_LOG"
  assert_output "3"
  assert_dir_not_exists "$(hpl_namespace "$HPL_DEFAULT_SOCKET")/sweep.lock"
}

function test_scripts_1179_herdr_pane_labels_names_an_agent_whose_fresh_pane_repor() {
  _bats_test_init 1179 'herdr-pane-labels names an agent whose fresh pane reports no label yet'
  command -v jq >/dev/null || skip "jq not available"
  source "$HERDR_ALIASES"
  hpl_setup
  hpl_set_agent_pane "$HPL_DEFAULT_SOCKET" pane-1 tab-1 ws-1 term-1 claude
  # herdr 0.8.2 omits `label` from a pane that has never been renamed. The
  # engine must read that as an empty label, not reject the snapshot: rejecting
  # deadlocks the pipeline, because this engine is the only label writer.
  hpl_transform_state "$HPL_DEFAULT_SOCKET" 'del(.panes[0].label)'

  run hpl_sweep_run --sweep
  assert_success

  local state alias
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  alias="$(jq -r '.agents[0].name // ""' "$state")"
  run herdr_alias_in_pool "$alias"
  assert_success
  assert_equal "$(jq -r '.panes[0].label' "$state")" "cc:$alias"
}

function tear_down() { _bats_run_teardown; }

function tear_down_after_script() { _bats_file_cleanup; }
