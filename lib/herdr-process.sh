# shellcheck shell=bash
# Shared process hygiene for detached Herdr workers.

# Agent and test harnesses can keep control pipes on descriptors above stderr.
# Detached descendants must not keep those pipes alive after their caller exits.
# Bash 3.2 reserves descriptor 255 for the running script.
close_inherited_descriptors() {
  local descriptor fd
  for descriptor in /dev/fd/*; do
    fd="${descriptor##*/}"
    case "$fd" in
      0 | 1 | 2 | 255 | *[!0-9]*) continue ;;
    esac
    eval "exec ${fd}>&-" 2>/dev/null || true
  done
}

# Normalize both current markers and persisted markers written by older callers,
# which trimmed ps output differently.
_normalize_process_start_marker() {
  local marker="$1" LC_ALL=C
  marker="${marker#"${marker%%[![:space:]]*}"}"
  marker="${marker%"${marker##*[![:space:]]}"}"
  printf '%s' "$marker"
}

# Prints a stable start timestamp for a live process. A recorded PID alone
# cannot identify an owner across time because the kernel reuses PIDs; the
# start timestamp makes the pair unique.
process_start_marker() {
  local pid="$1" marker
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  marker="$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null)" || return 1
  marker="$(_normalize_process_start_marker "$marker")"
  [ -n "$marker" ] || return 1
  printf '%s' "$marker"
}

# Return 0 for the same process, 1 for a malformed or different identity, and
# 2 when the live marker cannot be read. The ambient-locale comparison keeps
# short-lived records written by older worktree and pane workers valid across
# deployment; every new record uses the canonical C-locale marker above.
process_start_matches() {
  local pid="$1" expected="$2" current legacy
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  expected="$(_normalize_process_start_marker "$expected")"
  [ -n "$expected" ] || return 1
  current="$(process_start_marker "$pid")" || return 2
  [ "$current" != "$expected" ] || return 0
  legacy="$(ps -p "$pid" -o lstart= 2>/dev/null)" || return 2
  legacy="$(_normalize_process_start_marker "$legacy")"
  [ -n "$legacy" ] || return 2
  [ "$legacy" = "$expected" ]
}
