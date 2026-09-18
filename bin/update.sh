#!/bin/sh
set -u

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
repo="${HERDR_PANE_LABELS_REPOSITORY:-Seigiard/herdr-pane-labels}"
labels="$script_dir/herdr-pane-labels"
socket="${HERDR_SOCKET_PATH:-}"

restart_after_failure() {
  [ -n "$socket" ] || return 0
  HERDR_SOCKET_PATH="$socket" "$labels" --ensure-sweep-daemon >/dev/null 2>&1 || true
}

if [ -n "$socket" ]; then
  HERDR_SOCKET_PATH="$socket" "$labels" --stop || exit 1
fi

if ! herdr plugin install "$repo" -y </dev/null; then
  restart_after_failure
  exit 1
fi

enable_output=""
if ! enable_output="$(herdr plugin enable seigi.pane-labels </dev/null 2>&1)"; then
  case "$enable_output" in
    *server_not_running*)
      herdr plugin list --json </dev/null 2>/dev/null | jq -e \
        '.result.plugins[] | select(.plugin_id == "seigi.pane-labels" and .enabled == true)' \
        >/dev/null 2>&1 || {
          [ -z "$enable_output" ] || printf '%s\n' "$enable_output" >&2
          restart_after_failure
          exit 1
        }
      ;;
    *)
      [ -z "$enable_output" ] || printf '%s\n' "$enable_output" >&2
      restart_after_failure
      exit 1
      ;;
  esac
fi

reload_output=""
if ! reload_output="$(herdr server reload-config </dev/null 2>&1)"; then
  case "$reload_output" in
    *server_not_running*) ;;
    *)
      [ -z "$reload_output" ] || printf '%s\n' "$reload_output" >&2
      restart_after_failure
      exit 1
      ;;
  esac
fi

if [ -n "$socket" ]; then
  if ! HERDR_SOCKET_PATH="$socket" HERDR_PANE_LABELS_STRICT_SWEEP=1 "$labels" --sweep || \
    ! HERDR_SOCKET_PATH="$socket" "$labels" --ensure-sweep-daemon; then
    restart_after_failure
    exit 1
  fi
fi
printf 'updated %s\n' "$repo"
