#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENGINE="$ROOT/bin/herdr-pane-labels"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

test_alias_contract() {
  local candidates count unique
  candidates="$(HERDR_ALIAS_TEST_SEED=contract "$ENGINE" --alias-candidates contract)" || fail 'alias command exits successfully'
  count="$(printf '%s\n' "$candidates" | wc -l | tr -d ' ')"
  [ "$count" -ge 1024 ] || fail 'alias pool has at least 1024 candidates'
  unique="$(printf '%s\n' "$candidates" | sort -u | wc -l | tr -d ' ')"
  [ "$unique" = "$count" ] || fail 'alias candidates are unique'
  printf '%s\n' "$candidates" | awk '!/^[a-z]+-[a-z]+$/ { exit 1 }' || fail 'aliases use the supported grammar'
  pass 'alias contract'
}

test_package_diagnostics() {
  local output
  output="$(HOME="$ROOT/tests/home" "$ENGINE" --diagnostics)"
  [[ "$output" == *'version=0.2.3'* ]] || fail 'diagnostics reports package version'
  [[ "$output" == *"engine=$ENGINE"* ]] || fail 'diagnostics reports engine path'
  pass 'package diagnostics'
}

test_clean_install() {
  local home="$ROOT/tests/.home.$$"
  rm -rf "$home"
  HOME="$home" "$ROOT/scripts/install-cli-shim.sh"
  [ -x "$home/.local/bin/herdr-pane-labels" ] || fail 'install creates CLI shim'
  [ -f "$home/.local/lib/herdr-aliases.sh" ] || fail 'install creates private alias library'
  HOME="$home" "$home/.local/bin/herdr-pane-labels" --alias-candidates clean >/dev/null || fail 'installed CLI exposes alias contract'
  rm -rf "$home"
  pass 'clean install'
}

test_alias_contract
test_package_diagnostics
test_clean_install
