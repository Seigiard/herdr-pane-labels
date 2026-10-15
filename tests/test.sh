#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENGINE="$ROOT/bin/herdr-pane-labels"
FIXTURE="$ROOT/tests/fixtures/herdr-process.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/herdr-pane-labels-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

prepare_home() {
  local home="$1"
  mkdir -p "$home/.local/lib"
  cp "$FIXTURE" "$home/.local/lib/herdr-process.sh"
}

test_alias_contract() {
  local candidates count unique home="$WORK/alias-home"
  prepare_home "$home"
  candidates="$(HOME="$home" HERDR_ALIAS_TEST_SEED=contract "$ENGINE" --alias-candidates contract)" || fail 'alias command exits successfully'
  count="$(printf '%s\n' "$candidates" | wc -l | tr -d ' ')"
  [ "$count" -ge 1024 ] || fail 'alias pool has at least 1024 candidates'
  unique="$(printf '%s\n' "$candidates" | sort -u | wc -l | tr -d ' ')"
  [ "$unique" = "$count" ] || fail 'alias candidates are unique'
  printf '%s\n' "$candidates" | awk '!/^[a-z]+-[a-z]+$/ { exit 1 }' || fail 'aliases use the supported grammar'
  pass 'alias contract'
}

test_package_diagnostics() {
  local output home="$WORK/diagnostics-home"
  prepare_home "$home"
  output="$(HOME="$home" "$ENGINE" --diagnostics)"
  [[ "$output" == *'version=0.2.3'* ]] || fail 'diagnostics reports package version'
  [[ "$output" == *"engine=$ENGINE"* ]] || fail 'diagnostics reports engine path'
  pass 'package diagnostics'
}

test_clean_install() {
  local home="$WORK/install-home" before installed_files
  mkdir -p "$home/.local/lib"
  cp "$FIXTURE" "$home/.local/lib/herdr-process.sh"
  before="$home/before-herdr-process.sh"
  cp "$home/.local/lib/herdr-process.sh" "$before"
  HOME="$home" "$ROOT/scripts/install-cli-shim.sh"
  [ -x "$home/.local/bin/herdr-pane-labels" ] || fail 'install creates CLI shim'
  cmp "$before" "$home/.local/lib/herdr-process.sh" || fail 'install preserves the canonical process library'
  [ -f "$home/.local/lib/herdr-pane-labels/herdr-aliases.sh" ] || fail 'install creates package-owned alias library'
  [ -f "$home/.local/lib/herdr-pane-labels/herdr-pane-labels.version" ] || fail 'install creates package-owned version file'
  installed_files="$(find "$home/.local" -type f | sed "s|$home/.local/||" | sort)"
  [ "$installed_files" = $'bin/herdr-pane-labels\nlib/herdr-pane-labels/herdr-aliases.sh\nlib/herdr-pane-labels/herdr-pane-labels.version\nlib/herdr-process.sh' ] || \
    fail 'install writes only the shim and package-owned files beside the canonical library'
  HOME="$home" "$home/.local/bin/herdr-pane-labels" --alias-candidates clean >/dev/null || fail 'installed CLI exposes alias contract'
  HOME="$home" "$home/.local/bin/herdr-pane-labels" --diagnostics >/dev/null || fail 'installed CLI exposes diagnostics'
  HOME="$home" "$ENGINE" --diagnostics >/dev/null || fail 'checkout CLI exposes diagnostics'

  home="$WORK/absent-home"
  HOME="$home" "$ROOT/scripts/install-cli-shim.sh"
  [ ! -e "$home/.local/lib/herdr-process.sh" ] || fail 'install does not create the canonical process library'
  pass 'clean install'
}

test_alias_contract
test_package_diagnostics
test_clean_install
