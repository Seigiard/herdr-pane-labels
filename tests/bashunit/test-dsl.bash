# Test DSL for this repo's bashunit 0.50.1 suites (tests/bashunit/*_test.sh).
#
# Historically a bats-core 1.14 compatibility layer (the suite migrated from
# bats with oracle-verified parity — docs/benchmarks/
# bashunit-full-suite-experiment.md); now the permanent vocabulary the tests
# are written in. It exists because bashunit natively has neither `run` nor
# implicit-assertion semantics: without the ERR trap below, a failing bare
# command (`cd`, `grep -q`, `[ ... ]`) would NOT fail its test.
#
# Vocabulary policy (hybrid): keep `run`/`$status`/`$output`/assert_output-
# style asserts as the house style; when touching a test, native bashunit
# assert names may replace 1:1 equivalents (assert_equal -> assert_equals),
# but never replace the `run` capture or the ERR-trap semantics.
#
# Semantics this DSL guarantees:
#
# - Failure detection is an ERR trap with errtrace (set -E, no errexit) plus
#   the body's final exit status. This matches bats' set -eET on the same
#   interpreter — helper-depth command failures fail the test, while the
#   bash-3.2 quirk stays: a mid-body `[[ ]]`/`(( ))` false is inert
#   (docs/solutions/test-failures/bats-mid-test-compound-conditionals-bypass-errexit.md).
# - `run` executes in a command substitution (subshell), captures merged
#   stdout+stderr with trailing newlines stripped, and splits $lines on
#   newlines with empty lines dropped — exactly bats' default capture.
# - `skip` marks the test skipped from any call depth and stops the body via
#   `exit 0`; bashunit's own EXIT handling still runs tear_down afterwards,
#   matching bats' teardown-after-skip guarantee.
# - Converted files adapt setup/teardown through _bats_test_init and a
#   generated tear_down wrapper; tear_down failure fails the test (bats parity).
#
# Must stay bash-3.2-clean: no declare -A, no ${var,,}, no readarray.

status=0
output=""
lines=()

_BATS_ERR_TRAP='_bats_err_trap "$?" "$BASH_COMMAND"'

_bats_err_trap() {
  # Mirrors bats' "`cmd' failed [with status N]" diagnostic for a failing
  # command, then ends the test with that status. errtrace (set -E in
  # _bats_test_init) extends coverage into helper functions, matching bats'
  # set -eET; failures inside bashunit's own runner internals are not test
  # failures and are ignored.
  local st="$1" cmd="$2"
  case "${FUNCNAME[1]:-}" in bashunit::*) return 0 ;; esac
  trap - ERR
  if [ "$st" -eq 1 ]; then
    printf "\`%s' failed\n" "$cmd" >&2
  else
    printf "\`%s' failed with status %s\n" "$cmd" "$st" >&2
  fi
  exit "$st"
}

_bats_assert_pass() {
  trap - ERR
  bashunit::state::add_assertions_passed
  trap "$_BATS_ERR_TRAP" ERR
  return 0
}

_bats_assert_fail() {
  # Print a bats-assert style block and end the test as failed.
  trap - ERR
  bashunit::state::add_assertions_failed
  printf '%s\n' "$1" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Core bats vocabulary
# ---------------------------------------------------------------------------

load() {
  local name="$1" path
  case "$name" in
    */bats-support/load|*/bats-assert/load|*/bats-file/load)
      return 0 ;;  # vocabulary supplied by this shim
  esac
  case "$name" in
    /*) path="$name" ;;
    *)  path="$BATS_TEST_DIRNAME/$name" ;;
  esac
  if [ ! -f "$path" ]; then
    path="$path.bash"
  fi
  # shellcheck disable=SC1090
  source "$path"
}

run() {
  trap - ERR
  status=0
  output=""
  lines=()
  stderr=""
  stderr_lines=()
  local _bats_sep_stderr=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --separate-stderr) _bats_sep_stderr=1; shift ;;
      --keep-empty-lines) shift ;;  # not used by this suite; ignore
      --) shift; break ;;
      *) break ;;
    esac
  done
  # Subshell for bats-like state isolation, FILE capture for bats-like fd
  # semantics: a daemon left running by the command inherits a writable file,
  # not a pipe that closes when capture ends — a command-substitution capture
  # SIGPIPEs detached continuations that write after run returns.
  # No external commands here: tests legitimately empty PATH before `run`
  # (e.g. palette's missing-python3 scenario), so capture must be pure bash.
  _BATS_RUN_SEQ=$((${_BATS_RUN_SEQ:-0} + 1))
  local _bats_run_out="$BATS_TEST_TMPDIR/.bats-run-out.$$.$_BATS_RUN_SEQ"
  if [ "$_bats_sep_stderr" -eq 1 ]; then
    local _bats_run_err="$BATS_TEST_TMPDIR/.bats-run-err.$$.$_BATS_RUN_SEQ"
    ( "$@" ) > "$_bats_run_out" 2> "$_bats_run_err"
    status=$?
    output=$(< "$_bats_run_out")
    stderr=$(< "$_bats_run_err")
    _bats_split_stderr_lines
  else
    ( "$@" ) > "$_bats_run_out" 2>&1
    status=$?
    output=$(< "$_bats_run_out")
  fi
  _bats_split_lines
  trap "$_BATS_ERR_TRAP" ERR
  return 0
}

_bats_split_stderr_lines() {
  local had_f=0
  case $- in *f*) had_f=1 ;; esac
  set -f
  local IFS=$'\n'
  # shellcheck disable=SC2206
  stderr_lines=( $stderr )
  if [ "$had_f" -eq 0 ]; then
    set +f
  fi
}

_bats_split_lines() {
  local had_f=0
  case $- in *f*) had_f=1 ;; esac
  set -f
  local IFS=$'\n'
  # shellcheck disable=SC2206
  lines=( $output )
  if [ "$had_f" -eq 0 ]; then
    set +f
  fi
}

skip() {
  trap - ERR
  bashunit::skip "${1:-}"
  exit 0
}

fail() {
  # bats-support fail(): print to stderr, return 1. At body level the ERR trap
  # turns that into a test failure; helpers rely on the explicit return value.
  printf '%s\n' "${1:-}" >&2
  return 1
}

# ---------------------------------------------------------------------------
# bats-assert subset used by this suite
# ---------------------------------------------------------------------------

assert() {
  # bats-assert generic form: fail unless the given command succeeds.
  if "$@"; then
    _bats_assert_pass
  else
    _bats_assert_fail "-- assertion failed --
command : $*
--"
  fi
}

assert_success() {
  if [ "$status" -ne 0 ]; then
    _bats_assert_fail "-- command failed --
status : $status
output : $output
--"
  fi
  _bats_assert_pass
}

assert_failure() {
  if [ $# -ge 1 ]; then
    if [ "$status" -ne "$1" ]; then
      _bats_assert_fail "-- command failed as expected, but status differs --
expected : $1
actual   : $status
output   : $output
--"
    fi
  elif [ "$status" -eq 0 ]; then
    _bats_assert_fail "-- command succeeded, but it was expected to fail --
output : $output
--"
  fi
  _bats_assert_pass
}

assert_equal() {
  if [ "$1" != "$2" ]; then
    _bats_assert_fail "-- values do not equal --
expected : $2
actual   : $1
--"
  fi
  _bats_assert_pass
}

# Shared matcher: _bats_match <mode> <haystack> <needle>
# mode: exact | partial | regexp ; returns 0 on match.
_bats_match() {
  case "$1" in
    partial) case "$2" in *"$3"*) return 0 ;; esac; return 1 ;;
    regexp)  [[ "$2" =~ $3 ]] ;;
    *)       [ "$2" = "$3" ] ;;
  esac
}

_bats_output_args() {
  # Parses assert_output/refute_output style args.
  # Sets _bats_mode and _bats_expected (reads stdin for `-`/`--stdin`).
  _bats_mode=exact
  _bats_expected=""
  local use_stdin=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -p|--partial) _bats_mode=partial; shift ;;
      -e|--regexp)  _bats_mode=regexp; shift ;;
      -|--stdin)    use_stdin=1; shift ;;
      --)           shift; break ;;
      *)            break ;;
    esac
  done
  if [ "$use_stdin" -eq 1 ]; then
    _bats_expected=$(cat -)
  else
    _bats_expected="${1-}"
  fi
}

assert_output() {
  _bats_output_args "$@"
  if ! _bats_match "$_bats_mode" "$output" "$_bats_expected"; then
    _bats_assert_fail "-- output does not match ($_bats_mode) --
expected : $_bats_expected
actual   : $output
--"
  fi
  _bats_assert_pass
}

refute_output() {
  _bats_output_args "$@"
  if _bats_match "$_bats_mode" "$output" "$_bats_expected"; then
    _bats_assert_fail "-- output should not match ($_bats_mode) --
unexpected : $_bats_expected
actual     : $output
--"
  fi
  _bats_assert_pass
}

assert_stderr() {
  _bats_output_args "$@"
  if ! _bats_match "$_bats_mode" "$stderr" "$_bats_expected"; then
    _bats_assert_fail "-- stderr does not match ($_bats_mode) --
expected : $_bats_expected
actual   : $stderr
--"
  fi
  _bats_assert_pass
}

refute_stderr() {
  _bats_output_args "$@"
  if _bats_match "$_bats_mode" "$stderr" "$_bats_expected"; then
    _bats_assert_fail "-- stderr should not match ($_bats_mode) --
unexpected : $_bats_expected
actual     : $stderr
--"
  fi
  _bats_assert_pass
}

_bats_line_args() {
  # Parses assert_line/refute_line args. Sets _bats_mode, _bats_index (or -1),
  # _bats_expected.
  _bats_mode=exact
  _bats_index=-1
  _bats_expected=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--index)   _bats_index="$2"; shift 2 ;;
      -p|--partial) _bats_mode=partial; shift ;;
      -e|--regexp)  _bats_mode=regexp; shift ;;
      --)           shift; break ;;
      *)            break ;;
    esac
  done
  _bats_expected="${1-}"
}

assert_line() {
  _bats_line_args "$@"
  local i
  if [ "$_bats_index" -ge 0 ]; then
    if ! _bats_match "$_bats_mode" "${lines[$_bats_index]-}" "$_bats_expected"; then
      _bats_assert_fail "-- line at index $_bats_index does not match ($_bats_mode) --
expected : $_bats_expected
actual   : ${lines[$_bats_index]-}
--"
    fi
  else
    local found=1
    i=0
    while [ "$i" -lt "${#lines[@]}" ]; do
      if _bats_match "$_bats_mode" "${lines[$i]}" "$_bats_expected"; then
        found=0
        break
      fi
      i=$((i + 1))
    done
    if [ "$found" -ne 0 ]; then
      _bats_assert_fail "-- no output line matches ($_bats_mode) --
expected : $_bats_expected
output   : $output
--"
    fi
  fi
  _bats_assert_pass
}

refute_line() {
  _bats_line_args "$@"
  local i
  if [ "$_bats_index" -ge 0 ]; then
    if _bats_match "$_bats_mode" "${lines[$_bats_index]-}" "$_bats_expected"; then
      _bats_assert_fail "-- line at index $_bats_index should not match ($_bats_mode) --
unexpected : $_bats_expected
actual     : ${lines[$_bats_index]-}
--"
    fi
  else
    i=0
    while [ "$i" -lt "${#lines[@]}" ]; do
      if _bats_match "$_bats_mode" "${lines[$i]}" "$_bats_expected"; then
        _bats_assert_fail "-- an output line should not match ($_bats_mode) --
unexpected : $_bats_expected
line       : ${lines[$i]}
index      : $i
--"
      fi
      i=$((i + 1))
    done
  fi
  _bats_assert_pass
}

# ---------------------------------------------------------------------------
# bats-file subset used by this suite
# ---------------------------------------------------------------------------

# bats-file semantics kept for oracle parity: -f (regular file), NOT -e.
# A directory at the path makes assert_file_not_exists vacuously pass —
# directory expectations must use assert_dir_not_exists / assert_dir_exists.
assert_file_exists() {
  if [ ! -f "$1" ]; then
    _bats_assert_fail "-- file does not exist --
path : $1
--"
  fi
  _bats_assert_pass
}

assert_file_not_exists() {
  if [ -f "$1" ]; then
    _bats_assert_fail "-- file exists, but it was expected to be absent --
path : $1
--"
  fi
  _bats_assert_pass
}

assert_dir_exists() {
  if [ ! -d "$1" ]; then
    _bats_assert_fail "-- directory does not exist --
path : $1
--"
  fi
  _bats_assert_pass
}

assert_dir_not_exists() {
  if [ -d "$1" ]; then
    _bats_assert_fail "-- directory exists, but it was expected to be absent --
path : $1
--"
  fi
  _bats_assert_pass
}

assert_file_executable() {
  if [ ! -x "$1" ]; then
    _bats_assert_fail "-- file is not executable --
path : $1
--"
  fi
  _bats_assert_pass
}

assert_file_contains() {
  # bats-file: default engine is plain grep (BRE); optional third arg selects
  # grep|egrep|pcregrep.
  local file="$1" regex="$2" cmd="${3:-grep}"
  if ! "$cmd" -q -- "$regex" "$file"; then
    _bats_assert_fail "-- file does not contain regex --
path  : $file
regex : $regex
--"
  fi
  _bats_assert_pass
}

assert_file_permission() {
  local permission="$1" file="$2" actual
  if [[ "$OSTYPE" == darwin* ]]; then
    actual=$(stat -f '%A' "$file")
  else
    actual=$(stat -c '%a' "$file")
  fi
  if [ "$actual" != "$permission" ]; then
    _bats_assert_fail "-- file does not have permissions $permission --
path   : $file
actual : $actual
--"
  fi
  _bats_assert_pass
}

# ---------------------------------------------------------------------------
# Per-test initialization (emitted by the converter as the first body line)
# ---------------------------------------------------------------------------

# _bats_test_init <test-number> <original test name>
# BATS_TEST_FILENAME/BATS_TEST_DIRNAME are set by the generated file header.
_bats_test_init() {
  BATS_TEST_NUMBER="$1"
  BATS_TEST_DESCRIPTION="$2"
  BATS_TEST_NAME="$2"
  bashunit::set_test_title "$2"
  # Historical Bats numbers can repeat after suites are merged. Bashunit's
  # runtime identity is unique per test, including under parallel execution.
  BATS_TEST_TMPDIR="$_BATS_FILE_TMPROOT/$BASHUNIT_CURRENT_TEST_ID"
  mkdir -p "$BATS_TEST_TMPDIR"
  export BATS_TEST_NUMBER BATS_TEST_DESCRIPTION BATS_TEST_NAME BATS_TEST_TMPDIR
  # -E: inherit the ERR trap into helper functions (bats runs tests with
  # set -eET; without this a helper failing mid-way but returning 0 is green
  # here and red under bats).
  set -E
  trap "$_BATS_ERR_TRAP" ERR
  if declare -F setup >/dev/null; then
    setup
  fi
}

# Called from the generated set_up_before_script wrapper.
_bats_file_init() {
  # Called with the test file itself (tests/bashunit/<name>_test.sh).
  # BATS_TEST_DIRNAME keeps its historical contract = tests/ — the suite root
  # where helpers/ and fixture files live — one level above the file's own
  # directory. Test bodies resolve helpers, fixtures, and the repo root
  # ($BATS_TEST_DIRNAME/..) through it.
  BATS_TEST_FILENAME=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
  BATS_TEST_DIRNAME=$(cd "$(dirname "$1")/.." && pwd)
  # bats exports BATS_TMPDIR as $TMPDIR (trailing slash stripped) or /tmp;
  # helpers using ${BATS_TMPDIR:-/tmp} must land in the same place they do
  # under bats, or leak comparisons see the same debris class at two paths.
  BATS_TMPDIR="${TMPDIR:-/tmp}"
  BATS_TMPDIR="${BATS_TMPDIR%/}"
  export BATS_TMPDIR
  _BATS_FILE_TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/bats-compat-run.XXXXXX")
  BATS_RUN_TMPDIR="$_BATS_FILE_TMPROOT"
  BATS_FILE_TMPDIR="$_BATS_FILE_TMPROOT/file"
  mkdir -p "$BATS_FILE_TMPDIR"
  export BATS_TEST_FILENAME BATS_TEST_DIRNAME _BATS_FILE_TMPROOT \
    BATS_RUN_TMPDIR BATS_FILE_TMPDIR
}

# Called from the generated tear_down_after_script wrapper.
_bats_file_cleanup() {
  if [ -n "${_BATS_FILE_TMPROOT:-}" ] && [ -d "$_BATS_FILE_TMPROOT" ]; then
    rm -rf "$_BATS_FILE_TMPROOT"
  fi
}

# Generated tear_down wrapper body: run the original teardown with the ERR trap
# off; a failing teardown fails the test through the hook's exit status.
# (Known deviation: bats aborts a teardown at its first failing inner command;
# here only teardown's final status counts. The suite's teardowns are
# ||-guarded cleanup, where the two agree.)
_bats_run_teardown() {
  trap - ERR
  set +E
  if declare -F teardown >/dev/null; then
    teardown
  fi
}
