# Herdr pane-labels Bats harness.
# Load this after the package test header so SOURCE_ROOT and bashunit assertions exist.

HPL_ENGINE="$SOURCE_ROOT/bin/herdr-pane-labels"
# shellcheck disable=SC2034 # The loading Bats file reads this shared harness value.
HPL_PLUGIN_DIR="$SOURCE_ROOT"

# Codicon glyphs of the $git_ref grammar, pinned as literal octal UTF-8
# sequences. Do NOT derive these from executable_herdr-pane-labels. An earlier
# harness read the engine's own ICON_ table out with sed and re-expanded it,
# which made every HPL_ICON_* assertion compare the engine against itself: a
# changed codepoint moved both sides at once and the suite stayed green. That
# extraction was removed once and then carried back in by the
# herdr-task-sync -> herdr-pane-labels rename, so the duplication below is
# deliberate rather than an oversight waiting to be tidied away.
#
# "Spell the octal table once" is the rule for the *generator* — the engine must
# build each glyph from a single octal printf, see
# docs/solutions/design-patterns/generate-pua-glyphs-from-octal-printf.md — and
# the exact inverse for an *oracle*, which discriminates only while it holds a
# copy the thing under test cannot move. These glyphs are a user-facing
# pane-label contract with no config or environment override, so a mismatch is a
# real regression, never drift the user is entitled to cause.
#
# Raw PUA glyphs are lost when files pass through editors and agents, so neither
# side may hold the character verbatim; both spell it as octal. Test 1208 in
# scripts_test.sh asserts these constants stay invariant when the engine's table
# is perturbed.
# shellcheck disable=SC2034
HPL_ICON_BRANCH="$(printf '\356\261\257')"   # nf-cod-git_branch U+EC6F
# shellcheck disable=SC2034
HPL_ICON_WORKTREE="$(printf '\356\261\276')" # nf-cod-worktree U+EC7E
# shellcheck disable=SC2034
HPL_ICON_COMMIT="$(printf '\356\253\274')"   # nf-cod-git_commit U+EAFC
# shellcheck disable=SC2034
HPL_ICON_FOLDER="$(printf '\356\252\203')"   # nf-cod-folder U+EA83
# shellcheck disable=SC2034
HPL_ICON_PULL="$(printf '\342\207\243')"     # U+21E3 downwards dashed arrow
HPL_ICON_PUSH="$(printf '\342\207\241')"     # U+21E1 upwards dashed arrow
HPL_ICON_STALE="$(printf '\356\252\202')"    # nf-cod-history U+EA82

hpl_teardown() {
  # Reap a background reader a failed test left running BEFORE deleting its
  # HPL_WORK: the loop only stops via a file inside HPL_WORK, so once that
  # directory is gone the orphan spins forever and its ENOENT stderr lands on
  # top of the real failure output.
  if [[ -n "${HPL_READER_PID:-}" ]]; then
    kill "$HPL_READER_PID" 2>/dev/null || true
    wait "$HPL_READER_PID" 2>/dev/null || true
    unset HPL_READER_PID
  fi
  if [[ -n "${HPL_CUTOVER_HOME:-}" ]]; then
    for pid_file in \
      "$HPL_CUTOVER_HOME"/.cache/herdr-task-sync/sweep.lock/pid \
      "$HPL_CUTOVER_HOME"/.cache/herdr-task-sync/sockets/*/sweep.lock/pid \
      "$HPL_CUTOVER_HOME"/.cache/herdr-pane-labels/sockets/*/sweep.lock/pid; do
      [[ -f "$pid_file" ]] || continue
      kill "$(cat "$pid_file")" 2>/dev/null || true
    done
  fi
  [[ -n "${HPL_WORK:-}" ]] && rm -rf "$HPL_WORK" || true
  unset HPL_WORK HPL_STUB HPL_STATE HPL_LOG HPL_DEFAULT_SOCKET HPL_SOCKET_ROOT
  unset HPL_CUTOVER_HOME HPL_CUTOVER_BEFORE HPL_CUTOVER_AFTER HPL_CUTOVER_TRACE
}

# The four stub scripts and the fixture library are invariant: they read
# HPL_WORK and the fixture registry at run time, so nothing in them depends on
# which test is running. Writing them once per file and linking them into each
# test's stub directory keeps every setup from rewriting them. The jq lookup is
# hoisted for the same reason.
hpl_setup_assets() {
  [[ -z "${HPL_ASSETS:-}" ]] || hpl_teardown_assets
  HPL_ASSETS="$(mktemp -d "${BATS_TMPDIR:-/tmp}/hpl-assets.XXXXXX")"
  HPL_JQ_BIN="$(command -v jq 2>/dev/null || true)"
  export HPL_ASSETS HPL_JQ_BIN

  # The mutable fixture uses exact socket paths as identities. Numeric storage
  # directories avoid the collision caused by replacing punctuation in names.
  cat > "$HPL_ASSETS/fixture-lib.sh" <<'SH'
# The stub emulates the `herdr api snapshot` envelope of herdr 0.8.2, which
# reports protocol 20. Both numbers come from the installed binary rather than
# from an assumption: `herdr --version`, and
# `herdr api snapshot | jq .result.snapshot.protocol`. The engine never reads
# .protocol, so this literal records what the fake claims to be rather than
# behaviour under test. Test 1209 in scripts_test.sh is what keeps the record
# honest -- it compares this stub's top-level result keys against the real
# binary's, and skips where herdr is absent.
hpl_fixture_init_dir() {
  mkdir -p "$1/calls" "$1/completions" "$1/locks" "$1/after"
  [ -f "$1/state.json" ] || printf '%s\n' \
    '{"complete":true,"protocol":20,"panes":[],"tabs":[],"agents":[],"layouts":[],"workspaces":[],"metadata":{}}' \
    > "$1/state.json"
  [ -f "$1/call-seq" ] || printf '%s' 0 > "$1/call-seq"
  [ -f "$1/herdr.log" ] || : > "$1/herdr.log"
}

hpl_fixture_socket_dir() {
  local socket_path="${1:-${HERDR_SOCKET_PATH:-$HPL_DEFAULT_SOCKET}}"
  local dir id lock="$HPL_SOCKET_ROOT/registry.lock" attempts=0
  [ -d "$HPL_SOCKET_ROOT" ] || return 1
  while ! mkdir "$lock" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ -d "$HPL_SOCKET_ROOT" ] && [ "$attempts" -lt 1000 ] || return 1
    sleep 0.01
  done
  for dir in "$HPL_SOCKET_ROOT"/socket-*; do
    [ -d "$dir" ] || continue
    if [ -f "$dir/socket-path" ] && [ "$(cat "$dir/socket-path")" = "$socket_path" ]; then
      rmdir "$lock"
      printf '%s\n' "$dir"
      return 0
    fi
  done
  id="$(cat "$HPL_SOCKET_ROOT/next-id")"
  printf '%s' $((id + 1)) > "$HPL_SOCKET_ROOT/next-id"
  dir="$HPL_SOCKET_ROOT/socket-$id"
  mkdir -p "$dir"
  printf '%s' "$socket_path" > "$dir/socket-path"
  hpl_fixture_init_dir "$dir"
  rmdir "$lock"
  printf '%s\n' "$dir"
}

hpl_fixture_log() {
  if [ -f "$1/log-path" ]; then
    cat "$1/log-path"
  else
    printf '%s/herdr.log\n' "$1"
  fi
}

hpl_fixture_next_call() {
  local dir="$1" lock="$1/locks/call-seq" seq attempts=0
  [ -d "$dir/locks" ] || return 1
  while ! mkdir "$lock" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ -d "$dir/locks" ] && [ "$attempts" -lt 1000 ] || return 1
    sleep 0.01
  done
  seq=$(( $(cat "$dir/call-seq") + 1 ))
  printf '%s' "$seq" > "$dir/call-seq"
  rmdir "$lock"
  printf '%s\n' "$seq"
}

hpl_fixture_state_lock() {
  local attempts=0
  [ -d "$1/locks" ] || return 1
  while ! mkdir "$1/locks/state" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ -d "$1/locks" ] && [ "$attempts" -lt 1000 ] || return 1
    sleep 0.01
  done
}

hpl_fixture_state_unlock() {
  rmdir "$1/locks/state"
}
SH

  # Every read is generated from current state. Rename and metadata calls
  # mutate that state before their exact per-socket completion marker appears.
  cat > "$HPL_ASSETS/herdr" <<'SH'
#!/usr/bin/env bash
source "$HPL_WORK/fixture-lib.sh"
if [ "$1" = "session" ] && [ "$2" = "list" ] && [ "${3:-}" = "--json" ]; then
  count=0
  [ ! -f "$HPL_WORK/session-list-count" ] || read -r count < "$HPL_WORK/session-list-count"
  count=$((count + 1))
  printf '%s\n' "$count" > "$HPL_WORK/session-list-count"
  [ ! -f "$HPL_WORK/fail-session-list" ] || exit 1
  [ ! -f "$HPL_WORK/fail-session-list-at" ] || [ "$(cat "$HPL_WORK/fail-session-list-at")" != "$count" ] || exit 1
  cat "$HPL_WORK/sessions.json"
  exit 0
fi
if [ "$1" = "plugin" ] || { [ "$1" = "server" ] && [ "$2" = "reload-config" ]; }; then
  printf '%s\n' "$*" >> "$HPL_WORK/plugin.log"
  printf '%s|%s\n' "${HERDR_SOCKET_PATH:-}" "$*" >> "$HPL_WORK/plugin-sockets.log"
  [ ! -f "$HPL_WORK/fail-plugin-command" ] || exit 1
  if [ "$1 ${2:-}" = "plugin link" ] && [ -f "$HPL_WORK/sessions-after-link.json" ]; then
    cp "$HPL_WORK/sessions-after-link.json" "$HPL_WORK/sessions.json"
  fi
  if [ "$1 ${2:-}" = "plugin enable" ] && [ -f "$HPL_WORK/sessions-before-enable.json" ] && \
    [ ! -f "$HPL_WORK/sessions-before-enable.applied" ]; then
    cp "$HPL_WORK/sessions-before-enable.json" "$HPL_WORK/sessions.json"
    : > "$HPL_WORK/sessions-before-enable.applied"
  fi
  if [ -f "$HPL_WORK/fail-live-plugin-command-without-sessions" ] && \
    { [ "$1 ${2:-}" = "plugin enable" ] || [ "$1 ${2:-}" = "server reload-config" ]; } && \
    ! grep -q '"running":true' "$HPL_WORK/sessions.json"; then
    exit 1
  fi
  if [ -f "$HPL_WORK/require-live-plugin-command-socket" ] && \
    { [ "$1 ${2:-}" = "plugin enable" ] || [ "$1 ${2:-}" = "plugin disable" ] || \
      [ "$1 ${2:-}" = "server reload-config" ]; } && \
    ! jq -e --arg socket "${HERDR_SOCKET_PATH:-}" \
      '.result.sessions[] | select(.running == true and .socket_path == $socket)' \
      "$HPL_WORK/sessions.json" >/dev/null; then
    exit 1
  fi
  exit 0
fi
if [ -f "$HPL_WORK/block-herdr" ]; then
  block_attempts=0
  release_file="${HPL_DESCRIPTOR_RELEASE_FILE:-$HPL_WORK/release-herdr}"
  : > "$HPL_WORK/herdr-blocked"
  # Publish the blocking process itself, so a caller can prove it was still
  # blocked rather than inferring it from an ancestor that outlives the give-up
  # below. Only the descriptor test sets this.
  if [ -n "${HPL_DESCRIPTOR_BLOCKED_PID_FILE:-}" ]; then
    printf '%s\n' "$$" > "$HPL_DESCRIPTOR_BLOCKED_PID_FILE"
  fi
  # The 3000-poll default (~30 s) is what every other user of this stub gets.
  # Only the descriptor test raises it, and it exports the raised value itself.
  while [ ! -f "$release_file" ]; do
    block_attempts=$((block_attempts + 1))
    if [ "$block_attempts" -ge "${HPL_BLOCKED_HERDR_POLLS:-3000}" ]; then
      # Record the give-up durably. A caller cannot detect it by polling this
      # process for liveness -- that is a race it will usually lose -- and a
      # give-up silently invalidates any conclusion drawn about what was holding
      # a descriptor while it was supposed to be blocked.
      if [ -n "${HPL_DESCRIPTOR_BLOCKED_PID_FILE:-}" ]; then
        : > "$HPL_DESCRIPTOR_BLOCKED_PID_FILE.gave-up"
      fi
      exit 124
    fi
    sleep 0.01
  done
fi
dir="$(hpl_fixture_socket_dir)" || exit 1
log="$(hpl_fixture_log "$dir")"
call="$*"
seq="$(hpl_fixture_next_call "$dir")" || exit 1
printf '%s\n' "$call" >> "$log"
printf '%s\n' "$call" > "$dir/calls/$seq"

finish_call() {
  if [ -f "$dir/after/$seq.json" ]; then
    hpl_fixture_state_lock "$dir" || return
    cp "$dir/after/$seq.json" "$dir/state.json"
    hpl_fixture_state_unlock "$dir"
  fi
  if [ -f "$dir/after/$seq.sh" ]; then
    bash "$dir/after/$seq.sh"
  fi
  : > "$dir/completions/$seq"
}
trap finish_call EXIT

state="$dir/state.json"
if [ "$1" = "pane" ] && [ "$2" = "list" ]; then
  jq -c '{id:"cli:pane:list",result:{panes:.panes,type:"pane_list"}}' "$state"
elif [ "$1" = "pane" ] && [ "$2" = "get" ]; then
  pane="$(jq -c --arg id "$3" '.panes[] | select(.pane_id == $id)' "$state")"
  [ -n "$pane" ] || exit 1
  jq -cn --argjson pane "$pane" '{id:"cli:pane:get",result:{pane:$pane,type:"pane_info"}}'
elif [ "$1" = "pane" ] && [ "$2" = "process-info" ]; then
  cat "$dir/proc-${4:-$3}.json" 2>/dev/null
elif [ "$1" = "tab" ] && [ "$2" = "list" ]; then
  jq -c '{id:"cli:tab:list",result:{tabs:.tabs,type:"tab_list"}}' "$state"
elif [ "$1" = "tab" ] && [ "$2" = "get" ]; then
  tab="$(jq -c --arg id "$3" '.tabs[] | select(.tab_id == $id)' "$state")"
  [ -n "$tab" ] || exit 1
  jq -cn --argjson tab "$tab" '{id:"cli:tab:get",result:{tab:$tab,type:"tab_info"}}'
elif [ "$1" = "api" ] && [ "$2" = "snapshot" ]; then
  [ ! -f "$dir/fail-snapshot" ] || exit 1
  if [ -f "$dir/malformed-next-snapshot" ]; then
    rm -f "$dir/malformed-next-snapshot"
    printf '%s\n' 'not-json'
    exit 0
  fi
  if [ -f "$dir/fail-next-snapshot" ]; then
    rm -f "$dir/fail-next-snapshot"
    exit 1
  fi
  if [ "$(jq -r '.complete' "$state")" = "true" ]; then
    jq -c '{id:"cli:api:snapshot",result:{snapshot:{protocol:.protocol,panes:.panes,tabs:.tabs,agents:.agents,layouts:.layouts,workspaces:.workspaces},type:"session_snapshot"}}' "$state"
  else
    jq -c '{id:"cli:api:snapshot",result:{snapshot:{protocol:.protocol,panes:.panes},type:"session_snapshot"}}' "$state"
  fi
elif [ "$1" = "agent" ] && [ "$2" = "rename" ]; then
  count=0
  [ ! -f "$dir/agent-rename-count" ] || read -r count < "$dir/agent-rename-count"
  count=$((count + 1))
  printf '%s' "$count" > "$dir/agent-rename-count"
  if [ -f "$dir/agent-rename-error-$count.json" ]; then
    cat "$dir/agent-rename-error-$count.json" >&2
    exit 1
  fi
  tmp="$state.tmp.$$"
  hpl_fixture_state_lock "$dir" || exit 1
  jq --arg pane "$3" --arg name "$4" \
    '.agents |= map(if .pane_id == $pane then .name = $name else . end)' \
    "$state" > "$tmp" && mv "$tmp" "$state"
  result=$?
  hpl_fixture_state_unlock "$dir"
  [ "$result" -eq 0 ] || exit "$result"
  printf '{"result":{"type":"agent_renamed"}}\n'
elif [ "$1" = "pane" ] && [ "$2" = "rename" ]; then
  [ ! -f "$HPL_WORK/fail-pane-rename" ] || exit 1
  [ ! -f "$HPL_WORK/drop-pane-rename" ] || exit 0
  tmp="$state.tmp.$$"
  hpl_fixture_state_lock "$dir" || exit 1
  jq --arg id "$3" --arg label "$4" \
    '.panes |= map(if .pane_id == $id then .label = $label else . end)' \
    "$state" > "$tmp" && mv "$tmp" "$state"
  result=$?
  hpl_fixture_state_unlock "$dir"
  [ "$result" -eq 0 ] || exit "$result"
elif [ "$1" = "tab" ] && [ "$2" = "rename" ]; then
  [ ! -f "$HPL_WORK/fail-tab-rename" ] || exit 1
  [ ! -f "$HPL_WORK/drop-tab-rename" ] || exit 0
  tmp="$state.tmp.$$"
  hpl_fixture_state_lock "$dir" || exit 1
  jq --arg id "$3" --arg label "$4" \
    '.tabs |= map(if .tab_id == $id then .label = $label else . end)' \
    "$state" > "$tmp" && mv "$tmp" "$state"
  result=$?
  hpl_fixture_state_unlock "$dir"
  [ "$result" -eq 0 ] || exit "$result"
elif [ "$1" = "workspace" ] && [ "$2" = "report-metadata" ]; then
  [ ! -f "$HPL_WORK/fail-workspace-report" ] || exit 1
  shift 2
  source_id= workspace_id= report_seq= tokens='{}' clear_tokens='[]'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) source_id="$2"; shift 2 ;;
      --seq) report_seq="$2"; shift 2 ;;
      --token) tokens="$(jq -c --arg pair "$2" '. + {($pair | split("=")[0]): ($pair | split("=")[1:] | join("="))}' <<< "$tokens")"; shift 2 ;;
      --clear-token) clear_tokens="$(jq -c --arg name "$2" '. + [$name]' <<< "$clear_tokens")"; shift 2 ;;
      --*) shift 2 ;;
      *) workspace_id="$1"; shift ;;
    esac
  done
  [ -n "$source_id" ] && [ -n "$workspace_id" ] || exit 2
  tmp="$state.tmp.$$"
  hpl_fixture_state_lock "$dir" || exit 1
  jq --arg ws "$workspace_id" --argjson tokens "$tokens" --argjson clears "$clear_tokens" '
      .workspaces |= map(if .workspace_id == $ws then
        .tokens = ((reduce $clears[] as $key ((.tokens // {}); del(.[$key]))) + $tokens)
        | if (.tokens | length) == 0 then del(.tokens) else . end
      else . end)' "$state" > "$tmp" && mv "$tmp" "$state"
  result=$?
  hpl_fixture_state_unlock "$dir"
  [ "$result" -eq 0 ] || exit "$result"
elif [ "$1" = "pane" ] && [ "$2" = "report-metadata" ]; then
  [ ! -f "$HPL_WORK/fail-pane-report" ] || exit 1
  [ ! -f "$HPL_WORK/drop-pane-report" ] || exit 0
  shift 2
  source_id= pane_id= report_seq= report_seq_set=0 tokens='{}' clear_tokens='[]'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) source_id="$2"; shift 2 ;;
      --seq) report_seq="$2"; report_seq_set=1; shift 2 ;;
      --token) tokens="$(jq -c --arg pair "$2" '. + {($pair | split("=")[0]): ($pair | split("=")[1:] | join("="))}' <<< "$tokens")"; shift 2 ;;
      --clear-token) clear_tokens="$(jq -c --arg name "$2" '. + [$name]' <<< "$clear_tokens")"; shift 2 ;;
      --*) shift 2 ;;
      *) pane_id="$1"; shift ;;
    esac
  done
  [ -n "$source_id" ] && [ -n "$pane_id" ] || exit 2
  [ -n "$report_seq" ] || report_seq=0
  tmp="$state.tmp.$$"
  hpl_fixture_state_lock "$dir" || exit 1
  jq --arg pane "$pane_id" --arg source "$source_id" --argjson seq "$report_seq" \
    --argjson sequenced "$report_seq_set" \
    --argjson tokens "$tokens" --argjson clears "$clear_tokens" '
      (.metadata[$pane][$source].seq // -1) as $current
      | if $sequenced == 1 and $seq < $current then . else
          .metadata[$pane][$source].seq = (if $sequenced == 1 then $seq else $current end)
          | .metadata[$pane][$source].tokens = ((.metadata[$pane][$source].tokens // {}) + $tokens | with_entries(select(.key as $key | $clears | index($key) | not)))
          | (.metadata[$pane] // {} | [.[] | .tokens // {}] | add // {}) as $merged
          | .panes |= map(if .pane_id == $pane then
              .tokens = ((reduce $clears[] as $key ((.tokens // {}); del(.[$key]))) + $merged)
            else . end)
        end' "$state" > "$tmp" && mv "$tmp" "$state"
  result=$?
  hpl_fixture_state_unlock "$dir"
  [ "$result" -eq 0 ] || exit "$result"
fi
SH

  # Git fixtures are selected by exact CWD. A blocked target lets an actual
  # 75 ms watchdog expire while seven independent probes complete normally.
  cat > "$HPL_ASSETS/git" <<'SH'
#!/usr/bin/env bash
cwd= command_args="$*"
if [ "$1" = "-C" ]; then
  cwd="$2"
  shift 2
elif [ "${1#--git-dir=}" != "$1" ]; then
  cwd="gitdir:${1#--git-dir=}"
  shift
elif [ "$1" = "--git-dir" ]; then
  cwd="gitdir:$2"
  shift 2
fi
fixture="$(awk -F "$(printf '\037')" -v cwd="$cwd" '$1 == cwd { print $2; exit }' "$HPL_WORK/git-fixtures/registry" 2>/dev/null)"
if [ -d "$fixture" ]; then
  printf '%s\n' "$command_args" >> "$fixture/calls"
  printf '%s' "${LC_ALL:-}" > "$fixture/locale"
  : > "$fixture/started"
  mkdir -p "$HPL_WORK/git-started"
  : > "$HPL_WORK/git-started/${fixture##*/}"
  if [ -n "${HPL_GIT_PROBE_ID:-}" ]; then
    : > "$HPL_WORK/git-started/$HPL_GIT_PROBE_ID"
  fi
  if [ -f "$fixture/block" ]; then
    while [ ! -f "$fixture/release" ]; do sleep 0.01; done
  fi
  # block.short stalls only the second (--short=7) probe of a detached-HEAD
  # resolve, so the first probe of the same fixture still answers in budget.
  case "$command_args" in
    *"--short=7"*)
      if [ -f "$fixture/block.short" ]; then
        while [ ! -f "$fixture/release" ]; do sleep 0.01; done
      fi
      ;;
  esac
  : > "$fixture/completed"
  cat "$fixture/stderr" >&2
  out="$fixture/stdout"
  case "$command_args" in
    *"--short=7"*) [ ! -f "$fixture/stdout.short" ] || out="$fixture/stdout.short" ;;
    *"--porcelain=v2"*) [ ! -f "$fixture/stdout.status" ] || out="$fixture/stdout.status" ;;
  esac
  cat "$out"
  exit "$(cat "$fixture/status")"
fi
exit 1
SH


  cat > "$HPL_ASSETS/hpl-crash-worker" <<'SH'
#!/usr/bin/env bash
set -e
state="$1"
crash_after="${2:-none}"
markers="$state.markers"
mkdir -p "$markers"
[ -f "$state" ] || printf '%s\n' '{"completed":[],"complete":false}' > "$state"
for boundary in enqueue state presentation; do
  if jq -e --arg boundary "$boundary" '.completed | index($boundary)' "$state" >/dev/null; then
    continue
  fi
  tmp="$state.tmp.$$"
  jq --arg boundary "$boundary" '.completed += [$boundary]' "$state" > "$tmp"
  mv "$tmp" "$state"
  : > "$markers/$boundary"
  [ "$crash_after" != "$boundary" ] || exit 97
done
tmp="$state.tmp.$$"
jq '.complete = true' "$state" > "$tmp"
mv "$tmp" "$state"
SH
  chmod +x "$HPL_ASSETS/herdr" "$HPL_ASSETS/git" "$HPL_ASSETS/hpl-crash-worker"
}

hpl_teardown_assets() {
  [[ -n "${HPL_ASSETS:-}" ]] && rm -rf "$HPL_ASSETS" || true
  unset HPL_ASSETS HPL_JQ_BIN
}

# Build a sandbox with a stub `herdr` that records its argv. PATH is pinned to
# the stub directory plus the system directories, so a real `pi` or `claude`
# outside them can never be reached: a missing engine is then a property of the
# test, not of the machine that runs it.
hpl_setup() {
  [[ -z "${HPL_WORK:-}" ]] || hpl_teardown
  HPL_WORK="$(mktemp -d "${BATS_TMPDIR:-/tmp}/hpl.XXXXXX")"
  HPL_STUB="$HPL_WORK/stub"
  HPL_STATE="$HPL_WORK/state"
  HPL_LOG="$HPL_WORK/herdr.log"
  HPL_DEFAULT_SOCKET="$HPL_WORK/session.sock"
  HPL_SOCKET_ROOT="$HPL_WORK/sockets"
  export HPL_WORK HPL_DEFAULT_SOCKET HPL_SOCKET_ROOT
  export HERDR_SOCKET_PATH="$HPL_DEFAULT_SOCKET"
  mkdir -p "$HPL_STUB" "$HPL_STATE" "$HPL_SOCKET_ROOT/socket-1"
  : > "$HPL_LOG"
  printf '%s' "$HPL_DEFAULT_SOCKET" > "$HPL_SOCKET_ROOT/socket-1/socket-path"
  printf '%s' "$HPL_LOG" > "$HPL_SOCKET_ROOT/socket-1/log-path"
  printf '%s' 2 > "$HPL_SOCKET_ROOT/next-id"
  hpl_init_socket_dir "$HPL_SOCKET_ROOT/socket-1"
  # A per-file asset directory holds the invariant stubs; each test gets links
  # to them, so a test that renames one (herdr.unavailable) still only moves its
  # own link. The lazy build covers a file that loads this harness without
  # calling hpl_setup_assets from set_up_before_script.
  [[ -n "${HPL_ASSETS:-}" && -d "${HPL_ASSETS:-}" ]] || hpl_setup_assets
  ln -s "$HPL_ASSETS/fixture-lib.sh" "$HPL_WORK/fixture-lib.sh"
  ln -s "$HPL_ASSETS/herdr" "$HPL_STUB/herdr"
  ln -s "$HPL_ASSETS/git" "$HPL_STUB/git"
  ln -s "$HPL_ASSETS/hpl-crash-worker" "$HPL_STUB/hpl-crash-worker"
  "$HPL_STUB/git" --version >/dev/null 2>&1 || true
  # jq lives outside /usr/bin on Homebrew installs (macOS and the Linux test
  # container alike), so link it in rather than widening the pinned PATH — a
  # wider PATH would also expose the real pi and claude.
  [[ -n "${HPL_JQ_BIN:-}" ]] && ln -s "$HPL_JQ_BIN" "$HPL_STUB/jq"
  return 0
}

hpl_pane_list() {
  local state tmp panes
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  tmp="$state.tmp"
  panes="$(jq -c '
    [.result.panes[] | .pane_id as $id
      | .tab_id = (.tab_id // "tab-1")
      | .workspace_id = (.workspace_id // "ws-1")
      | .terminal_id = (.terminal_id // ("term-" + $id))
      | .revision = (.revision // 1)
      | .label = (.label // "")
      | .tokens = (.tokens // {})]
  ' <<< "$1")"
  jq --argjson panes "$panes" '
    .panes = $panes
    | .agents = [$panes[] | select((.agent // "") != "")
        | {pane_id,terminal_id,tab_id,workspace_id,revision,agent,
           state_change_seq:(.state_change_seq // 1)}
          + (if has("name") and .name != null then {name} else {} end)
          + (if .agent_session == null then {} else {agent_session:.agent_session} end)]
    | reduce $panes[] as $pane (.;
        if any(.tabs[]; .tab_id == $pane.tab_id) then .
        else .tabs += [{tab_id:$pane.tab_id,workspace_id:$pane.workspace_id,label:""}] end)
    | reduce $panes[] as $pane (.;
        if any(.workspaces[]; .workspace_id == $pane.workspace_id) then .
        else .workspaces += [{workspace_id:$pane.workspace_id,label:$pane.workspace_id}] end)
  ' "$state" > "$tmp" && mv "$tmp" "$state"
}

# $1 = pane id, $2 = the `pane process-info` payload the stub replays for it
hpl_proc_info() {
  hpl_proc_info_for_socket "$HPL_DEFAULT_SOCKET" "$@"
}

hpl_proc_info_for_socket() {
  local dir
  dir="$(hpl_socket_dir "$1")"
  printf '%s' "$3" > "$dir/proc-$2.json"
}

hpl_tab_list() {
  local state tmp
  state="$(hpl_socket_state "$HPL_DEFAULT_SOCKET")"
  tmp="$state.tmp"
  jq --argjson tabs "$(jq -c '[.result.tabs[] | .workspace_id = (.workspace_id // "ws-1") | .label = (.label // "")]' <<< "$1")" '
    .tabs = $tabs
    | reduce $tabs[] as $tab (.;
        if any(.workspaces[]; .workspace_id == $tab.workspace_id) then .
        else .workspaces += [{workspace_id:$tab.workspace_id,label:$tab.workspace_id}] end)
  ' "$state" > "$tmp" && mv "$tmp" "$state"
}

# herdr 0.8.2 / protocol 20 -- see the note above hpl_fixture_init_dir.
hpl_init_socket_dir() {
  mkdir -p "$1/calls" "$1/completions" "$1/locks" "$1/after"
  printf '%s\n' \
    '{"complete":true,"protocol":20,"panes":[],"tabs":[],"agents":[],"layouts":[],"workspaces":[],"metadata":{}}' \
    > "$1/state.json"
  printf '%s' 0 > "$1/call-seq"
  : > "$1/herdr.log"
}

hpl_socket_dir() {
  # shellcheck source=/dev/null
  source "$HPL_WORK/fixture-lib.sh"
  hpl_fixture_socket_dir "$1"
}

hpl_socket_state() {
  printf '%s/state.json\n' "$(hpl_socket_dir "$1")"
}

hpl_socket_log() {
  local dir
  dir="$(hpl_socket_dir "$1")"
  if [[ -f "$dir/log-path" ]]; then
    cat "$dir/log-path"
  else
    printf '%s/herdr.log\n' "$dir"
  fi
}

hpl_socket_run() {
  local socket_path="$1"
  shift
  env PATH="$HPL_STUB:/usr/bin:/bin" HERDR_SOCKET_PATH="$socket_path" herdr "$@"
}

# Upsert one object into a snapshot array, replacing any element that already
# carries the same id. Serves panes, tabs, and workspaces alike.
hpl_upsert() {
  local socket="$1" array="$2" id_field="$3" object="$4" state tmp
  state="$(hpl_socket_state "$socket")"
  tmp="$state.tmp"
  jq --arg array "$array" --arg id "$id_field" --argjson object "$object" \
    '.[$array] = ([.[$array][] | select(.[$id] != $object[$id])] + [$object])' \
    "$state" > "$tmp" && mv "$tmp" "$state"
}

hpl_set_pane() {
  local pane
  pane="$(jq -c '
    .pane_id as $id
    | .tab_id = (.tab_id // "tab-1")
    | .workspace_id = (.workspace_id // "ws-1")
    | .terminal_id = (.terminal_id // ("term-" + $id))
    | .revision = (.revision // 1)
    | .label = (.label // "")
    | .tokens = (.tokens // {})
  ' <<< "$2")"
  hpl_upsert "$1" panes pane_id "$pane"
  hpl_set_tab "$1" "$(jq -cn --arg id "$(jq -r .tab_id <<< "$pane")" \
    --arg ws "$(jq -r .workspace_id <<< "$pane")" '{tab_id:$id,workspace_id:$ws,label:""}')"
  hpl_set_workspace "$1" "$(jq -cn --arg id "$(jq -r .workspace_id <<< "$pane")" '{workspace_id:$id,label:$id}')"
  if [[ "$(jq -r '.agent // ""' <<< "$pane")" != "" ]]; then
    hpl_set_agent "$1" "$(jq -c '
      {pane_id,terminal_id,tab_id,workspace_id,revision,agent,
       state_change_seq:(.state_change_seq // 1)}
      + (if has("name") and .name != null then {name} else {} end)
      + (if .agent_session == null then {} else {agent_session:.agent_session} end)
    ' <<< "$pane")"
  else
    hpl_remove_agent "$1" "$(jq -r .pane_id <<< "$pane")"
  fi
}

hpl_set_agent_pane() {
  local socket="$1" pane="$2" tab="$3" workspace="$4" terminal="$5" runtime="$6" name="${7:-}"
  local record
  record="$(jq -cn --arg pane "$pane" --arg tab "$tab" --arg workspace "$workspace" \
    --arg terminal "$terminal" --arg runtime "$runtime" --arg name "$name" '
      {pane_id:$pane,tab_id:$tab,workspace_id:$workspace,terminal_id:$terminal,
       revision:1,state_change_seq:1,agent:$runtime,label:"old",tokens:{}}
      | if $name == "" then . else .name = $name end')"
  hpl_set_pane "$socket" "$record"
}

hpl_replace_state() {
  local state tmp
  state="$(hpl_socket_state "$1")"
  tmp="$state.tmp"
  printf '%s\n' "$2" | jq . > "$tmp" && mv "$tmp" "$state"
}

hpl_transform_state() {
  local state tmp
  state="$(hpl_socket_state "$1")"
  tmp="$state.tmp"
  jq "$2" "$state" > "$tmp" && mv "$tmp" "$state"
}

hpl_remove_pane() {
  local state tmp
  state="$(hpl_socket_state "$1")"
  tmp="$state.tmp"
  jq --arg id "$2" '
    .panes |= map(select(.pane_id != $id))
    | .agents |= map(select(.pane_id != $id))
  ' "$state" > "$tmp" && mv "$tmp" "$state"
}

hpl_set_tab() {
  local tab
  tab="$(jq -c '.workspace_id = (.workspace_id // "ws-1") | .label = (.label // "")' <<< "$2")"
  hpl_upsert "$1" tabs tab_id "$tab"
  hpl_set_workspace "$1" "$(jq -cn --arg id "$(jq -r .workspace_id <<< "$tab")" '{workspace_id:$id,label:$id}')"
}

# Workspace names come from the snapshot's workspaces array; the formatter
# suppresses the $git_ref folder qualifier when the worktree token equals
# the pane's workspace name.
hpl_set_workspace() {
  hpl_upsert "$1" workspaces workspace_id "$2"
}

hpl_set_agent() {
  hpl_upsert "$1" agents pane_id "$2"
}

hpl_remove_agent() {
  local state tmp
  state="$(hpl_socket_state "$1")"
  tmp="$state.tmp"
  jq --arg pane "$2" '.agents |= map(select(.pane_id != $pane))' "$state" > "$tmp" && mv "$tmp" "$state"
}

hpl_set_process_pane() {
  local id="$1" tab="$2" workspace="$3" terminal="$4" cwd="$5" label="$6"
  hpl_set_pane "$HPL_DEFAULT_SOCKET" "$(jq -cn --arg id "$id" --arg tab "$tab" \
    --arg workspace "$workspace" --arg terminal "$terminal" --arg cwd "$cwd" --arg label "$label" \
    '{pane_id:$id,tab_id:$tab,workspace_id:$workspace,terminal_id:$terminal,revision:1,cwd:$cwd,foreground_cwd:$cwd,label:$label,tokens:{}}')"
}

hpl_snapshot_complete() {
  local state tmp
  state="$(hpl_socket_state "$1")"
  tmp="$state.tmp"
  jq --argjson complete "$2" '.complete = $complete' "$state" > "$tmp" && mv "$tmp" "$state"
}

hpl_after_next_call_state() {
  local dir next
  dir="$(hpl_socket_dir "$1")"
  next=$(( $(cat "$dir/call-seq") + 1 ))
  printf '%s\n' "$2" > "$dir/after/$next.json"
}

hpl_after_call_state() {
  local dir
  dir="$(hpl_socket_dir "$1")"
  printf '%s\n' "$3" > "$dir/after/$2.json"
}

hpl_after_call_script() {
  local dir
  dir="$(hpl_socket_dir "$1")"
  printf '%s\n' "$3" > "$dir/after/$2.sh"
}

hpl_fail_next_agent_rename() {
  local dir count
  dir="$(hpl_socket_dir "$1")"
  count=0
  [[ ! -f "$dir/agent-rename-count" ]] || read -r count < "$dir/agent-rename-count"
  printf '{"error":{"code":"%s","message":"fixture failure"}}\n' "$2" \
    > "$dir/agent-rename-error-$((count + 1)).json"
}

# Git-probe budget for every location pass, via hpl_location_pass's own default.
# It only has to be long enough for a HEALTHY probe to finish: the engine's
# watchdog cancels its timer the moment the probe returns, so a generous value
# costs a passing run nothing. At 0.075 it was calibrated on an idle machine and
# SIGKILLs healthy probes as soon as the suite runs with --jobs, which reads as a
# coordinator bug rather than as the load artifact it is.
#
# Three tests do pay it in full, because they point a probe at a `block` fixture
# that spins on a `release` file they never create, and a budget only expires
# when nothing returns. That is ~1.9 s each. A second, smaller constant for
# those three would not be safe: each of them runs healthy probes on the same
# pass -- the eight-pane coordinator test runs seven -- and a tighter budget
# would SIGKILL those, which is the failure this value exists to prevent.
HPL_GIT_BUDGET="${HPL_GIT_BUDGET:-2}"

# Ceiling for the "poll until the state settles" helpers. The helpers sleep at
# three different intervals, so each gets its own poll count derived from the one
# ceiling rather than a separately hand-computed literal. Every one of them
# returns the moment its condition holds, so a high ceiling costs a healthy run
# nothing; it only decides how long a genuinely stuck run waits before it reports
# failure. The previous 10s and 15s ceilings were calibrated on an idle machine,
# and a multi-step fixture under --jobs contention can legitimately exceed them
# -- which surfaced as a hang that was really load.
HPL_WAIT_CEILING_SECONDS="${HPL_WAIT_CEILING_SECONDS:-60}"
HPL_WAIT_POLLS="${HPL_WAIT_POLLS:-$((HPL_WAIT_CEILING_SECONDS * 100))}"        # sleep 0.01
HPL_WAIT_SLOW_POLLS="${HPL_WAIT_SLOW_POLLS:-$((HPL_WAIT_CEILING_SECONDS * 4))}"  # sleep 0.25
HPL_WAIT_MATCH_POLLS="${HPL_WAIT_MATCH_POLLS:-$((HPL_WAIT_CEILING_SECONDS * 40))}" # sleep 0.025
export HPL_WAIT_POLLS

# The two bounds around the nested Bats run in "bounded Bats invocation exits
# after detached work". They are deliberately two numbers, not one, because a
# hang guard and an assertion are different budgets: the old single 90 s budget
# covered the whole nested run, most of which was Bats parsing every test in
# tests/scripts.bats to reach the one the filter selects. The nested run now
# targets a dedicated one-test file, so the progress guard covers setup and the
# probe itself rather than a whole-suite parse.
#
# The causal remedy docs/solutions/design-patterns/idle-machine-wall-clock-bounds-are-latent-flakes.md
# prefers is unavailable here: a
# held pipe and a released one differ only in elapsed time, with no marker a test
# could block on. So the split is the fallback, applied deliberately.
#
# PROGRESS is the hang guard. It covers the nested run up to the probe writing
# its pid file. It never fires in a healthy run or in the guarded regression --
# only a genuine hang reaches it. Sixty seconds is intentionally still a guard,
# not a performance budget: it is far above the measured dedicated-file run, and
# far enough below the macOS job's timeout-minutes: 25 that it prints its own
# message instead of the job being killed with none.
HPL_INNER_BATS_PROGRESS_SECONDS="${HPL_INNER_BATS_PROGRESS_SECONDS:-60}"
# EXIT is the assertion, and the only bound here that can fire on a healthy run.
# It covers Bats teardown and exit alone -- not the parse -- which is what takes
# the load sensitivity out. Sized from measurement, not intuition: the driver
# prints its elapsed value on every run, and this is a large multiple of the
# ~0.2 s observed under CPU saturation on a 10-core host. Must stay below
# HPL_BLOCKED_HERDR_CEILING_SECONDS below, which is stated in the same unit so
# the two can be compared; see that comment for the window it has to clear.
HPL_INNER_BATS_EXIT_SECONDS="${HPL_INNER_BATS_EXIT_SECONDS:-30}"
# The driver runs as its own process, so both bounds have to be exported to
# reach it -- like HPL_WAIT_POLLS above. Without this the driver silently falls
# back to its own literals and editing the values here changes nothing, which is
# the same two-sources-of-truth failure this whole change is about.
export HPL_INNER_BATS_PROGRESS_SECONDS HPL_INNER_BATS_EXIT_SECONDS

# How long the blocked herdr stub waits for its release before giving up. This
# is a non-vacuity guard, not a budget. If the stub gives up first, the detached
# worker exits on its own, nothing is holding a descriptor when the driver looks,
# and the test would have passed having proved nothing.
#
# So the ceiling has to outlast the entire window the stub must stay blocked for,
# which is NOT just the exit bound. The stub starts blocking inside the nested
# test body -- it writes herdr-blocked before the probe writes its pid file -- so
# the window runs from there through the rest of the progress phase, all of the
# exit bound, and the liveness check. Derived rather than hardcoded so that
# relation holds by construction: a hand-picked number silently inverts the first
# time either bound above moves, and the failure it produces is a misdiagnosis
# (the run reports "the fixture gave up" when what actually happened is the hang
# guard's case).
#
# Stated in seconds like its counterparts: the stub polls at 0.01 s, and under
# --jobs contention each iteration costs more than that, so the poll count
# derived below is a floor on the real wall clock, never a cap.
HPL_BLOCKED_HERDR_CEILING_SECONDS="${HPL_BLOCKED_HERDR_CEILING_SECONDS:-$((HPL_INNER_BATS_PROGRESS_SECONDS + HPL_INNER_BATS_EXIT_SECONDS + 60))}"
HPL_BLOCKED_HERDR_POLLS="${HPL_BLOCKED_HERDR_POLLS:-$((HPL_BLOCKED_HERDR_CEILING_SECONDS * 100))}" # sleep 0.01
# Deliberately NOT exported at file scope. Two other tests use the same blocking
# stub (search block-herdr) and release it promptly; handing them a ceiling two
# orders of magnitude larger only slows down their failure paths, where the stub
# would otherwise give up quickly inside an already-deleted work dir. The one
# test that needs the raised ceiling exports it for itself.



hpl_wait_for_file() {
  local file="$1" _
  for _ in $(seq 1 "$HPL_WAIT_POLLS"); do
    [[ -e "$file" ]] && return 0
    sleep 0.01
  done
  return 1
}

# Waits for a file to CONTAIN something, not merely to exist. A detached stub
# can write its line after the caller returns, so on a loaded machine the log
# can be absent or empty at the moment the test reads it.
hpl_wait_for_file_match() {
  local file="$1" pattern="$2" _
  for _ in $(seq 1 "$HPL_WAIT_MATCH_POLLS"); do
    if [[ -e "$file" ]] && grep -q -- "$pattern" "$file"; then
      # Settle briefly so a second, unwanted line would also have landed --
      # this test asserts the log holds exactly one call, and returning the
      # instant the first line appears would hide a duplicate.
      sleep 0.1
      return 0
    fi
    sleep 0.025
  done
  return 1
}

hpl_wait_for_socket_call() {
  local dir="$1" call_number="$2"
  hpl_wait_for_file "$dir/calls/$call_number"
}

hpl_wait_for_socket_completion() {
  local dir="$1" call_number="$2"
  hpl_wait_for_file "$dir/completions/$call_number"
}

hpl_git_fixture() {
  local id fixture next="$HPL_WORK/git-fixtures/next"
  mkdir -p "$HPL_WORK/git-fixtures"
  id="$(cat "$next" 2>/dev/null || printf '%s' 1)"
  printf '%s' $((id + 1)) > "$next"
  fixture="$HPL_WORK/git-fixtures/$id"
  mkdir -p "$fixture"
  printf '%s' "$1" > "$fixture/cwd"
  printf '%s\n' "$2" > "$fixture/stdout"
  printf '%s' "${3:-0}" > "$fixture/status"
  printf '%s\n' "${5:-}" > "$fixture/stderr"
  : > "$fixture/calls"
  printf '%s\037%s\n' "$1" "$fixture" >> "$HPL_WORK/git-fixtures/registry"
  [[ "${4:-ready}" = "block" ]] && : > "$fixture/block"
  return 0
}

# The location probe's stdout is four lines: checkout root, common Git
# directory, symbolic ref (literally HEAD when detached), 7-char short SHA.
hpl_git_location_fixture() {
  local branch="${4:-refs/heads/main}" sha="${5:-abc9876}"
  hpl_git_fixture "$1" "$(printf '%s\n%s\n%s\n%s' "$2" "$3" "$branch" "$sha")" "${6:-0}" "${7:-ready}"
}

# A linked worktree carries a .git FILE at its root; the main checkout has a
# .git directory. The resolver's is_linked check reads only this marker.
hpl_mark_linked_worktree() {
  printf 'gitdir: %s\n' "${2:-$1.gitdir}" > "$1/.git"
}

hpl_git_fixture_dir() {
  awk -F "$(printf '\037')" -v cwd="$1" '$1 == cwd { print $2; exit }' \
    "$HPL_WORK/git-fixtures/registry"
}

hpl_process_pane_json() {
  local id="$1" tab="$2" cwd="$3" foreground_mode="${4:-present}" foreground="$3"
  [ "$#" -lt 5 ] || foreground="$5"
  jq -cn --arg id "$id" --arg tab "$tab" --arg cwd "$cwd" --arg fg "$foreground" \
    --arg mode "$foreground_mode" '
      {pane_id:$id,tab_id:$tab,workspace_id:"ws-1",terminal_id:("term-" + $id),agent:null,label:"",tokens:{},cwd:$cwd}
      | if $mode == "absent" then . else .foreground_cwd = $fg end'
}

# Attaches a `status --porcelain=v2` body to the fixture already registered for
# this cwd, so one fixture answers both the identity probe and the status probe.
hpl_git_status_fixture() {
  local fixture
  fixture="$(hpl_git_fixture_dir "$1")"
  [ -n "$fixture" ] || return 1
  printf '%s\n' "$2" > "$fixture/stdout.status"
}

hpl_set_process_label() {
  hpl_proc_info "$1" "$(jq -cn --arg command "$2" '{result:{process_info:{shell_pid:1,foreground_process_group_id:2,foreground_processes:[{pid:2,argv:[$command]}]}}}')"
}

hpl_set_pane_location() {
  local state tmp foreground="$4"
  state="$(hpl_socket_state "$1")"
  tmp="$state.tmp"
  jq --arg id "$2" --arg cwd "$3" --arg fg "$foreground" --arg mode "${5:-present}" '
    .panes |= map(if .pane_id == $id then
      .cwd = $cwd
      | if $mode == "absent" then del(.foreground_cwd) else .foreground_cwd = $fg end
    else . end)' "$state" > "$tmp" && mv "$tmp" "$state"
}

hpl_location_pass() {
  HERDR_PANE_LABELS_GIT_BUDGET="${HERDR_PANE_LABELS_GIT_BUDGET:-$HPL_GIT_BUDGET}" hpl_event_run
  hpl_wait_for_presentation_quiescence "$HPL_DEFAULT_SOCKET"
}

hpl_location_source_tokens() {
  jq -c --arg pane "$2" '.metadata[$pane]["location-sync"].tokens // {}' "$(hpl_socket_state "$1")"
}

hpl_location_source_seq() {
  jq -r --arg pane "$2" '.metadata[$pane]["location-sync"].seq // 0' "$(hpl_socket_state "$1")"
}

hpl_git_probe() {
  local pane="$1" cwd="$2" result_dir="$HPL_WORK/git-results" git_pid timer_pid git_status
  mkdir -p "$result_dir"
  env PATH="$HPL_STUB:/usr/bin:/bin" HPL_GIT_PROBE_ID="$pane" \
    git -C "$cwd" rev-parse --show-toplevel \
    > "$result_dir/$pane.output" 2>/dev/null &
  git_pid=$!
  hpl_wait_for_file "$HPL_WORK/git-started/$pane"
  (
    sleep 0.075
    if kill -0 "$git_pid" 2>/dev/null; then
      : > "$result_dir/$pane.timed-out"
      kill "$git_pid" 2>/dev/null || true
    fi
  ) &
  timer_pid=$!
  if wait "$git_pid"; then git_status=0; else git_status=$?; fi
  kill "$timer_pid" 2>/dev/null || true
  wait "$timer_pid" 2>/dev/null || true
  if [[ -e "$result_dir/$pane.timed-out" || "$git_status" -ne 0 ]]; then
    printf '%s\n' stale > "$result_dir/$pane"
  else
    printf 'fresh:%s\n' "$(cat "$result_dir/$pane.output")" > "$result_dir/$pane"
  fi
}

hpl_crash_run() {
  "$HPL_STUB/hpl-crash-worker" "$1" "${2:-none}"
}

# Sweep modes run the script directly. The git budget mirrors hpl_location_pass: the
# shipped 75 ms SIGKILL bound is a UI-latency budget calibrated against real
# git on an idle machine, and a forked bash-stub probe under --jobs load loses
# that race, degrades the pane to location_status=stale, and flakes any
# location assertion (the pattern
# docs/solutions/design-patterns/idle-machine-wall-clock-bounds-are-latent-flakes.md names;
# this was its third missed call site after 543ca9e and 7f675e1).
hpl_sweep_run() {
  env PATH="$HPL_STUB:/usr/bin:/bin" \
    HERDR_PANE_LABELS_STATE_DIR="$HPL_STATE" \
    HERDR_PANE_LABELS_SWEEP_INTERVAL="${HPL_SWEEP_INTERVAL:-1}" \
    HERDR_PANE_LABELS_GIT_BUDGET="${HERDR_PANE_LABELS_GIT_BUDGET:-$HPL_GIT_BUDGET}" \
    HERDR_ALIAS_TEST_SEED="${HERDR_ALIAS_TEST_SEED:-}" \
    bash "$HPL_ENGINE" "$@"
}

hpl_event_run() {
  env PATH="$HPL_STUB:/usr/bin:/bin" \
    HERDR_SOCKET_PATH="$HPL_DEFAULT_SOCKET" \
    HERDR_PANE_LABELS_STATE_DIR="$HPL_STATE" \
    HERDR_PANE_LABELS_TEST_NO_PRESENTATION="${HERDR_PANE_LABELS_TEST_NO_PRESENTATION:-}" \
    HERDR_PANE_LABELS_TEST_PAUSE_BEFORE_RELEASE="${HERDR_PANE_LABELS_TEST_PAUSE_BEFORE_RELEASE:-}" \
    HERDR_PANE_LABELS_TEST_NOW_SEQ="${HERDR_PANE_LABELS_TEST_NOW_SEQ:-}" \
    HERDR_PANE_LABELS_TEST_DIGEST_FILE="${HERDR_PANE_LABELS_TEST_DIGEST_FILE:-}" \
    HERDR_PANE_LABELS_TEST_TRACE_FILE="${HERDR_PANE_LABELS_TEST_TRACE_FILE:-$HPL_WORK/presentation.trace}" \
    HERDR_PANE_LABELS_GIT_BUDGET="${HERDR_PANE_LABELS_GIT_BUDGET:-}" \
    HERDR_ALIAS_TEST_SEED="${HERDR_ALIAS_TEST_SEED:-}" \
    HERDR_PANE_LABELS_TEST_NO_DAEMON="${HERDR_PANE_LABELS_TEST_NO_DAEMON-1}" \
    bash "$HPL_ENGINE" --event
}

hpl_request_only() {
  HERDR_PANE_LABELS_TEST_NO_PRESENTATION=1 hpl_event_run
}

hpl_event_run_for_socket() {
  local socket_path="$1"
  env PATH="$HPL_STUB:/usr/bin:/bin" \
    HERDR_SOCKET_PATH="$socket_path" \
    HERDR_PANE_LABELS_STATE_DIR="$HPL_STATE" \
    HERDR_PANE_LABELS_TEST_NO_PRESENTATION="${HERDR_PANE_LABELS_TEST_NO_PRESENTATION:-}" \
    HERDR_PANE_LABELS_TEST_NO_DAEMON="${HERDR_PANE_LABELS_TEST_NO_DAEMON-1}" \
    bash "$HPL_ENGINE" --event
}

hpl_presentation_run() {
  env PATH="$HPL_STUB:/usr/bin:/bin" \
    HERDR_SOCKET_PATH="$HPL_DEFAULT_SOCKET" \
    HERDR_PANE_LABELS_STATE_DIR="$HPL_STATE" \
    HERDR_PANE_LABELS_TEST_CRASH_AFTER="${HERDR_PANE_LABELS_TEST_CRASH_AFTER:-}" \
    HERDR_PANE_LABELS_TEST_NOW_SEQ="${HERDR_PANE_LABELS_TEST_NOW_SEQ:-}" \
    HERDR_PANE_LABELS_TEST_DIGEST_FILE="${HERDR_PANE_LABELS_TEST_DIGEST_FILE:-}" \
    HERDR_PANE_LABELS_GIT_BUDGET="${HERDR_PANE_LABELS_GIT_BUDGET:-}" \
    HERDR_PANE_LABELS_TEST_LOCATION_BARRIER="${HERDR_PANE_LABELS_TEST_LOCATION_BARRIER:-}" \
    HERDR_PANE_LABELS_TEST_LOCATION_BARRIER_COUNT="${HERDR_PANE_LABELS_TEST_LOCATION_BARRIER_COUNT:-}" \
    HERDR_PANE_LABELS_TEST_LOCATION_BARRIER_RELEASE="${HERDR_PANE_LABELS_TEST_LOCATION_BARRIER_RELEASE:-}" \
    HERDR_PANE_LABELS_TEST_TRACE_FILE="${HERDR_PANE_LABELS_TEST_TRACE_FILE:-$HPL_WORK/presentation.trace}" \
    HERDR_ALIAS_TEST_SEED="${HERDR_ALIAS_TEST_SEED:-}" \
    bash "$HPL_ENGINE" --presentation-worker
}

# The worker logs several herdr calls in a row, so a test that reads a later
# call must wait for that call and not for the first line of the log.
hpl_wait_for_call() {
  local _
  for _ in $(seq 1 "$HPL_WAIT_SLOW_POLLS"); do
    grep -q -- "$1" "$HPL_LOG" && return 0
    sleep 0.25
  done
  return 1
}

hpl_pane_label() {
  sed -n "s/^pane rename ${1:-pane-1} //p" "$HPL_LOG" | tail -1
}

hpl_key() {
  printf '%s' "$1" | base64 | tr '/+' '_-' | tr -d '=\n'
}

hpl_namespace() {
  printf '%s/sockets/%s\n' "$HPL_STATE" "$(hpl_key "$1")"
}

hpl_pane_state_dir() {
  printf '%s/panes/%s\n' "$(hpl_namespace "$1")" "$(hpl_key "$2")"
}

hpl_cutover_setup() {
  hpl_setup
  HPL_CUTOVER_HOME="$HPL_WORK/home"
  HPL_CUTOVER_BEFORE="$HPL_WORK/cutover-before.sh"
  HPL_CUTOVER_AFTER="$HPL_WORK/cutover-after.sh"
  HPL_CUTOVER_TRACE="$HPL_WORK/cutover.trace"
  mkdir -p "$HPL_CUTOVER_HOME/.local/bin" "$HPL_CUTOVER_HOME/.local/lib" \
    "$HPL_CUTOVER_HOME/.config/herdr/plugins"
  cp "$HPL_ENGINE" "$HPL_CUTOVER_HOME/.local/bin/herdr-pane-labels"
  cat > "$HPL_CUTOVER_HOME/.local/bin/herdr-child" <<'SH'
#!/bin/sh
printf '%s\n' 'legacy herdr-child --name launcher' >&2
exit 1
SH
  cp "$SOURCE_ROOT/dot_local/lib/herdr-aliases.sh" "$HPL_CUTOVER_HOME/.local/lib/herdr-aliases.sh"
  cp "$SOURCE_ROOT/dot_local/lib/herdr-process.sh" "$HPL_CUTOVER_HOME/.local/lib/herdr-process.sh"
  cp -R "$HPL_PLUGIN_DIR" "$HPL_CUTOVER_HOME/.config/herdr/plugins/herdr-pane-labels"
  chmod +x "$HPL_CUTOVER_HOME/.local/bin/herdr-pane-labels" "$HPL_CUTOVER_HOME/.local/bin/herdr-child"
  printf '%s\n' '{"result":{"sessions":[{"running":true,"socket_path":"'"$HPL_DEFAULT_SOCKET"'"}]}}' > "$HPL_WORK/sessions.json"
  : > "$HPL_WORK/plugin.log"
  : > "$HPL_WORK/plugin-sockets.log"
  : > "$HPL_CUTOVER_TRACE"

  cat > "$HPL_CUTOVER_HOME/.local/bin/herdr-task-sync" <<'SH'
#!/usr/bin/env bash
set -u
cache="${HERDR_TASK_SYNC_STATE_DIR:-$HOME/.cache/herdr-task-sync}"
socket="${HERDR_SOCKET_PATH:-}"
key="$(printf '%s' "$socket" | base64 | tr '/+' '_-' | tr -d '=\n')"
namespace="$cache/sockets/$key"
write_socket() {
  mkdir -p "$namespace"
  printf 'socket_path=%s\n' "$(printf '%s' "$socket" | base64 | tr -d '\n')" > "$namespace/socket.state"
}
case "${1:-}" in
  --ensure-daemon)
    write_socket
    if [ -f "$namespace/sweep.lock/pid" ] && kill -0 "$(cat "$namespace/sweep.lock/pid")" 2>/dev/null; then exit 0; fi
    mkdir -p "$namespace/sweep.lock"
    nohup bash "$0" --sweep-daemon </dev/null >/dev/null 2>&1 &
    ;;
  --sweep-daemon)
    write_socket
    mkdir -p "$namespace/sweep.lock"
    printf '%s' "$$" > "$namespace/sweep.lock/pid"
    trap 'rm -f "$namespace/sweep.lock/pid"; rmdir "$namespace/sweep.lock" 2>/dev/null || true; exit 0' INT TERM EXIT
    while :; do sleep 1; done
    ;;
  --presentation-worker|--worker)
    trap 'exit 0' INT TERM
    while :; do sleep 1; done
    ;;
  *)
    printf '%s\n' "$*" >> "${HPL_LEGACY_ADAPTER_LOG:-/dev/null}"
    ;;
esac
SH
  chmod +x "$HPL_CUTOVER_HOME/.local/bin/herdr-task-sync"

  chezmoi_full_fixture execute-template -S "$SOURCE_ROOT" --file "$HPL_CUTOVER_BEFORE_TEMPLATE" > "$HPL_CUTOVER_BEFORE"
  chezmoi_full_fixture execute-template -S "$SOURCE_ROOT" --file "$HPL_CUTOVER_AFTER_TEMPLATE" > "$HPL_CUTOVER_AFTER"
  chmod +x "$HPL_CUTOVER_BEFORE" "$HPL_CUTOVER_AFTER"
}

hpl_cutover_sessions() {
  local json='{"result":{"sessions":[]}}' socket
  for socket in "$@"; do
    json="$(jq -c --arg socket "$socket" '.result.sessions += [{running:true,socket_path:$socket}]' <<< "$json")"
  done
  printf '%s\n' "$json" > "$HPL_WORK/sessions.json"
}

hpl_cutover_run() {
  env HOME="$HPL_CUTOVER_HOME" PATH="$HPL_STUB:/usr/bin:/bin" \
    HPL_WORK="$HPL_WORK" HPL_DEFAULT_SOCKET="$HPL_DEFAULT_SOCKET" HPL_SOCKET_ROOT="$HPL_SOCKET_ROOT" \
    HPL_LEGACY_ADAPTER_LOG="$HPL_WORK/legacy-adapter.log" \
    HERDR_PANE_LABELS_CUTOVER_TRACE="$HPL_CUTOVER_TRACE" \
    HERDR_PANE_LABELS_CUTOVER_POLL=0.01 \
    HERDR_PANE_LABELS_CUTOVER_TEST_HOOK="${HERDR_PANE_LABELS_CUTOVER_TEST_HOOK:-}" \
    bash "$1"
}

hpl_pid_is_live() {
  local state
  kill -0 "$1" 2>/dev/null || return 1
  state="$(ps -p "$1" -o stat= 2>/dev/null)" || return 0
  if [[ "$state" != *Z* ]]; then
    return 0
  fi
  return 1
}

hpl_cutover_namespace() {
  printf '%s/.cache/%s/sockets/%s\n' "$HPL_CUTOVER_HOME" "$1" "$(hpl_key "$2")"
}

hpl_cutover_write_socket_state() {
  local namespace="$1" socket="$2"
  mkdir -p "$namespace"
  printf 'socket_path=%s\n' "$(printf '%s' "$socket" | base64 | tr -d '\n')" > "$namespace/socket.state"
}

hpl_cutover_spawn_owner() {
  local mode="$1" socket="$2" lock="$3" pid start namespace owner_file
  if [[ "$mode" = --worker ]]; then
    HERDR_SOCKET_PATH="$socket" bash "$HPL_CUTOVER_HOME/.local/bin/herdr-task-sync" "$mode" --agent claude \
      </dev/null >/dev/null 2>&1 &
  else
    HERDR_SOCKET_PATH="$socket" bash "$HPL_CUTOVER_HOME/.local/bin/herdr-task-sync" "$mode" \
      </dev/null >/dev/null 2>&1 &
  fi
  pid=$!
  namespace="$(hpl_cutover_namespace herdr-task-sync "$socket")"
  hpl_cutover_write_socket_state "$namespace" "$socket"
  mkdir -p "$namespace/$lock"
  owner_file="$namespace/$lock/owner"
  start="$(ps -p "$pid" -o lstart= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  printf 'owner_id=%s\npid=%s\nprocess_start=%s\nsocket_path=%s\n' \
    "$(printf owner-$pid | base64 | tr -d '\n')" "$pid" \
    "$(printf '%s' "$start" | base64 | tr -d '\n')" \
    "$(printf '%s' "$socket" | base64 | tr -d '\n')" > "$owner_file"
  printf '%s\n' "$pid"
}

hpl_cutover_start_old_daemon() {
  local socket="$1" namespace pid
  HERDR_SOCKET_PATH="$socket" HOME="$HPL_CUTOVER_HOME" \
    "$HPL_CUTOVER_HOME/.local/bin/herdr-task-sync" --ensure-daemon
  namespace="$(hpl_cutover_namespace herdr-task-sync "$socket")"
  hpl_wait_for_file "$namespace/sweep.lock/pid"
  pid="$(cat "$namespace/sweep.lock/pid")"
  printf '%s\n' "$pid"
}

hpl_record_number() {
  sed -n "s/^${2}=//p" "$1" | head -1
}

hpl_wait_for_presentation_quiescence() {
  local namespace reconcile claim _ pending completed
  namespace="$(hpl_namespace "$1")"
  reconcile="$namespace/reconcile.state"
  claim="$namespace/presentation.claim"
  for _ in $(seq 1 "$HPL_WAIT_POLLS"); do
    pending="$(hpl_record_number "$reconcile" pending_generation 2>/dev/null || true)"
    completed="$(hpl_record_number "$reconcile" completed_generation 2>/dev/null || true)"
    if [[ -n "$pending" && "$pending" -gt 0 && "$pending" = "$completed" && ! -d "$claim" ]]; then
      sleep 0.02
      [[ ! -d "$claim" ]] && return 0
    fi
    sleep 0.01
  done
  printf 'presentation did not quiesce: pending=%s completed=%s claim=%s\n' \
    "${pending:-missing}" "${completed:-missing}" "$([[ -d "$claim" ]] && printf present || printf absent)" >&2
  [[ ! -f "$reconcile" ]] || { printf '%s\n' 'reconcile.state:' >&2; sed 's/^/  /' "$reconcile" >&2; }
  [[ ! -f "$HPL_WORK/presentation.trace" ]] || { printf '%s\n' 'presentation phases:' >&2; sed 's/^/  /' "$HPL_WORK/presentation.trace" >&2; }
  [[ ! -f "$HPL_LOG" ]] || { printf '%s\n' 'herdr calls:' >&2; sed 's/^/  /' "$HPL_LOG" >&2; }
  return 1
}
