#!/usr/bin/env bash
set -euo pipefail

REAL_BIN="${TOLMO_REAL_BIN:-__REAL_BIN__}"

if [[ ! -x "$REAL_BIN" ]]; then
  echo "Error: tolmo wrapper could not find the real binary at '$REAL_BIN'" >&2
  exit 1
fi

is_short_finding_id() {
  local candidate="${1:-}"
  [[ -n "$candidate" && ${#candidate} -lt 36 && "$candidate" =~ ^[0-9A-Fa-f-]+$ ]]
}

resolve_finding_id() {
  local prefix="$1"
  shift

  local findings_json=""
  if ! findings_json="$("$REAL_BIN" "$@" findings list --json)"; then
    echo "Error: failed to list findings while resolving short id '$prefix'" >&2
    return 1
  fi

  local matches=""
  local status=0
  set +e
  matches="$(printf '%s' "$findings_json" | perl -MJSON::PP -e '
use strict;
use warnings;

my $prefix = lc(shift @ARGV // q{});
local $/;
my $raw = <STDIN>;
my $data = eval { JSON::PP::decode_json($raw) };
if (!$data || ref($data) ne "ARRAY") {
  exit 2;
}

my @matches = grep { index(lc($_), $prefix) == 0 }
              map { ref($_) eq "HASH" && defined $_->{id} ? $_->{id} : () } @$data;

if (@matches == 1) {
  print $matches[0];
  exit 0;
}

if (@matches == 0) {
  exit 3;
}

print join("\n", @matches);
exit 4;
' "$prefix")"
  status=$?
  set -e

  case "$status" in
    0)
      printf '%s' "$matches"
      ;;
    3)
      echo "Error: no finding matches short id '$prefix'" >&2
      return 1
      ;;
    4)
      echo "Error: short id '$prefix' is ambiguous. Matching IDs:" >&2
      printf '%s\n' "$matches" >&2
      return 1
      ;;
    *)
      echo "Error: failed to parse findings JSON while resolving short id '$prefix'" >&2
      return 1
      ;;
  esac
}

main() {
  local -a args=("$@")
  local -a prefix_args=()
  local idx=0
  local arg_count="${#args[@]}"

  while (( idx < arg_count )); do
    if [[ "${args[idx]}" == "findings" ]]; then
      break
    fi

    prefix_args+=("${args[idx]}")
    ((idx += 1))
  done

  if (( idx + 2 < arg_count )) && [[ "${args[idx]}" == "findings" ]]; then
    local action="${args[idx + 1]}"
    local id_index=$((idx + 2))
    local candidate="${args[id_index]}"

    if [[ "$action" =~ ^(get|update|delete)$ ]] && [[ "$candidate" != -* ]] && is_short_finding_id "$candidate"; then
      args[id_index]="$(resolve_finding_id "$candidate" "${prefix_args[@]}")"
    fi
  fi

  exec "$REAL_BIN" "${args[@]}"
}

main "$@"
