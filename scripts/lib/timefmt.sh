#!/usr/bin/env bash
# scripts/lib/timefmt.sh — portable time + random helpers for endy scripts.

_endy_iso_to_epoch() {
  python3 -c 'import sys, datetime; s=sys.argv[1]; print(int(datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()))' "$1" 2>/dev/null || echo 0
}

_endy_rand_hex4() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 2
  else
    printf '%04x' $(( RANDOM % 65536 ))
  fi
}
