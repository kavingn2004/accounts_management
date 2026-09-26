#!/usr/bin/env bash
# Run the app connected to Supabase, reading credentials from supabase.env.
#
# The bash counterpart of tool/run_web.ps1 — same contract, same env file.
# Without the two dart-defines the app falls back to on-device storage, which
# is a different store entirely: cloud rows and local rows never mix.
#
# Usage:
#   ./tool/run.sh                 # default device
#   ./tool/run.sh -d chrome       # any flutter run args are passed through
#   ./tool/run.sh --release
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$root/supabase.env"

if [[ ! -f "$env_file" ]]; then
  echo "Missing $env_file. Copy supabase.env.example and fill in:" >&2
  echo "  SUPABASE_URL=https://xxxx.supabase.co" >&2
  echo "  SUPABASE_ANON_KEY=your-anon-key" >&2
  exit 1
fi

# Parse KEY=VALUE, ignoring blanks and comments. Values are read as literals —
# no eval, no sourcing, so a stray character in the key can't run as a command.
url=""
key=""
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line#"${line%%[![:space:]]*}"}"   # ltrim
  [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
  name="${line%%=*}"
  value="${line#*=}"
  name="$(echo "$name" | tr -d '[:space:]')"
  value="${value%"${value##*[![:space:]]}"}"  # rtrim
  case "$name" in
    SUPABASE_URL) url="$value" ;;
    SUPABASE_ANON_KEY) key="$value" ;;
  esac
done < "$env_file"

for pair in "SUPABASE_URL:$url" "SUPABASE_ANON_KEY:$key"; do
  if [[ -z "${pair#*:}" ]]; then
    echo "supabase.env is missing ${pair%%:*}" >&2
    exit 1
  fi
done

echo "Connecting to ${url}"
cd "$root"
exec flutter run \
  --dart-define=SUPABASE_URL="$url" \
  --dart-define=SUPABASE_ANON_KEY="$key" \
  "$@"
