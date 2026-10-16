#!/usr/bin/env bash

HERDR_ALIAS_COLORS=(
  amber aqua azure beige black blue brown coral
  cream cyan gold gray green ivory jade khaki
  lilac lime navy ochre olive pink red teal
)

HERDR_ALIAS_ANIMALS=(
  akita
  ant
  baiji
  barb
  bat
  bear
  bison
  boar
  bongo
  booby
  camel
  carp
  cat
  coati
  cobra
  coral
  cow
  crab
  crane
  crow
  deer
  dhole
  dingo
  dodo
  dog
  dogo
  duck
  eagle
  eel
  elk
  emu
  finch
  fish
  fluke
  fly
  fossa
  fox
  frog
  gar
  gecko
  goat
  goose
  hare
  heron
  horse
  human
  hyena
  ibex
  ibis
  kiwi
  koala
  krill
  kudu
  lemur
  liger
  lion
  llama
  loach
  lynx
  macaw
  mole
  molly
  moose
  moth
  mouse
  mule
  newt
  okapi
  olm
  otter
  panda
  pig
  pika
  polar
  prawn
  pug
  quail
  quoll
  rat
  raven
  robin
  seal
  shark
  sheep
  skunk
  sloth
  snail
  snake
  squid
  stoat
  swan
  tetra
  tiger
  toad
  tuna
  wasp
  whale
  wolf
  worm
  zebra
  zebu
)

# A microsecond floor for monotonic reconciliation generations and metadata.
herdr_now_seq() {
  if command -v python3 >/dev/null 2>&1; then
    local value
    value="$(python3 -c 'import time; print(int(time.time()*1000000))' 2>/dev/null)"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  fi
  printf '%s000000' "$(date +%s)"
}

herdr_alias_is_valid() {
  [[ $# -eq 1 ]] || return 2
  local alias="$1"

  [[ ${#alias} -le 32 && "$alias" =~ ^[a-z]+-[a-z]+$ ]]
}

herdr_alias_in_pool() {
  [[ $# -eq 1 ]] || return 2
  local alias="$1"
  local color animal word
  local color_found=0 animal_found=0

  herdr_alias_is_valid "$alias" || return 1
  color="${alias%%-*}"
  animal="${alias#*-}"

  for word in "${HERDR_ALIAS_COLORS[@]}"; do
    if [[ "$word" == "$color" ]]; then
      color_found=1
      break
    fi
  done
  for word in "${HERDR_ALIAS_ANIMALS[@]}"; do
    if [[ "$word" == "$animal" ]]; then
      animal_found=1
      break
    fi
  done

  [[ $color_found -eq 1 && $animal_found -eq 1 ]]
}

_herdr_alias_validate_words() {
  local kind="$1"
  shift
  local words=("$@")
  local word duplicate

  if [[ ${#words[@]} -eq 0 ]]; then
    printf 'herdr aliases: %s list is empty\n' "$kind" >&2
    return 1
  fi

  for word in "${words[@]}"; do
    if [[ ! "$word" =~ ^[a-z]+$ ]]; then
      printf 'herdr aliases: invalid %s word: %s\n' "$kind" "$word" >&2
      return 1
    fi
  done

  # One sort beats the pairwise scan this replaces. Every alias allocation
  # revalidates both dictionaries, and the pairwise form was quadratic: at 252
  # animals it cost ~200ms per call on a developer machine and several times
  # that on a CI runner, which is what pushed the suite past its job budget.
  # Bash 3.2 is the floor here, so there is no associative array to dedupe
  # with. The reported word is the lexicographically first duplicate rather
  # than the first in declaration order; both name a word that must be
  # removed.
  duplicate="$(printf '%s\n' "${words[@]}" | sort | uniq -d | head -n 1)"
  if [[ -n "$duplicate" ]]; then
    printf 'herdr aliases: duplicate %s word: %s\n' "$kind" "$duplicate" >&2
    return 1
  fi
}

herdr_alias_validate_pool() {
  local color_count=${#HERDR_ALIAS_COLORS[@]}
  local animal_count=${#HERDR_ALIAS_ANIMALS[@]}

  _herdr_alias_validate_words color "${HERDR_ALIAS_COLORS[@]}" || return 1
  _herdr_alias_validate_words animal "${HERDR_ALIAS_ANIMALS[@]}" || return 1
  if ((color_count * animal_count < 1024)); then
    printf 'herdr aliases: pool has fewer than 1024 candidates\n' >&2
    return 1
  fi
}

herdr_alias_candidates() {
  [[ $# -eq 1 ]] || return 2
  herdr_alias_validate_pool || return 1

  local seed checksum_line checksum
  local color_count=${#HERDR_ALIAS_COLORS[@]}
  local animal_count=${#HERDR_ALIAS_ANIMALS[@]}
  local pool_size=$((color_count * animal_count))
  local offset

  if [[ -n "${HERDR_ALIAS_TEST_SEED+x}" ]]; then
    seed="$HERDR_ALIAS_TEST_SEED"
  else
    seed="$1"
  fi
  checksum_line="$(printf '%s' "$seed" | cksum)" || return 1
  checksum="${checksum_line%%[[:space:]]*}"
  [[ "$checksum" =~ ^[0-9]+$ ]] || return 1
  offset=$((checksum % pool_size))

  # awk walks the 2424-entry rotation in one process; the bash loop it
  # replaces spent ~150ms per call on printf alone. The blank line separates
  # the two dictionaries on stdin, which no word can collide with because
  # every word already matched ^[a-z]+$ above.
  {
    printf '%s\n' "${HERDR_ALIAS_COLORS[@]}"
    printf '\n'
    printf '%s\n' "${HERDR_ALIAS_ANIMALS[@]}"
  } | awk -v offset="$offset" '
    /^$/ && !seen_separator { seen_separator = 1; next }
    !seen_separator { colors[++color_count] = $0; next }
    { animals[++animal_count] = $0 }
    END {
      pool = color_count * animal_count
      for (step = 0; step < pool; step++) {
        position = (offset + step) % pool
        printf "%s-%s\n", \
          colors[int(position / animal_count) + 1], \
          animals[(position % animal_count) + 1]
      }
    }
  '
}
