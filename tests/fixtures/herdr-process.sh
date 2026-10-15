# shellcheck shell=bash
# Shared process hygiene for detached Herdr workers.

# Public API consumed by herdr-pane-labels. A breaking change raises this
# version and requires a matching herdr-pane-labels release.
# shellcheck disable=SC2034
HERDR_PROCESS_API=1

# Public contract:
# - process_start_marker prints a canonical UTC ps lstart marker.
# - process_start_matches <pid> <marker> <format> returns 0 for a match, 1
#   for a malformed or different identity, and 2 when the format or live
#   marker is unknown. The supported format is ps-lstart-c-utc-v1.
# - close_inherited_descriptors closes inherited descriptors above stderr.

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

# Canonical ps lstart token: C locale, UTC, single spaces between fields.
_normalize_process_start_marker() {
  local weekday month day clock year extra
  local IFS=$' \t\n'
  read -r weekday month day clock year extra <<< "$1"
  [ -n "$year" ] && [ -z "$extra" ] || return 1
  printf '%s %s %s %s %s' "$weekday" "$month" "$day" "$clock" "$year"
}

# Prints a stable start timestamp for a live process. A recorded PID alone
# cannot identify an owner across time because the kernel reuses PIDs; the
# start timestamp retains ps lstart's one-second precision.
process_start_marker() {
  local pid="$1" marker
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  marker="$(LC_ALL=C TZ=UTC ps -p "$pid" -o lstart= 2>/dev/null)" || return 1
  marker="$(_normalize_process_start_marker "$marker")"
  [ -n "$marker" ] || return 1
  printf '%s' "$marker"
}

# Return 0 for the same process, 1 for a malformed or different identity, and
# 2 when the identity format or live marker is unknown.
process_start_matches() {
  local pid="$1" expected="$2" format="${3:-}" current
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  [ -n "$expected" ] || return 1
  [ "$format" = ps-lstart-c-utc-v1 ] || return 2
  expected="$(_normalize_process_start_marker "$expected")" || return 1
  [ -n "$expected" ] || return 1
  current="$(process_start_marker "$pid")" || return 2
  [ "$current" = "$expected" ]
}
