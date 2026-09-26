#!/usr/bin/env bash
# Print your Supabase rows locally, for inspection and debugging.
#
# Every table is protected by row-level security keyed on auth.uid(), so the
# anon key alone returns [] — it has no user. This signs in the same way the
# app does, then reads with that session's token.
#
# The password is read without echo and never written anywhere: not to a file,
# not to the shell history, not to the process list.
#
# Usage:
#   ./tool/dump_supabase.sh                # every table, summarised
#   ./tool/dump_supabase.sh investments    # one table, in full
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$root/supabase.env"
[[ -f "$env_file" ]] || { echo "Missing $env_file" >&2; exit 1; }

url="$(sed -n 's/^SUPABASE_URL=//p' "$env_file" | tr -d '[:space:]')"
key="$(sed -n 's/^SUPABASE_ANON_KEY=//p' "$env_file" | tr -d '[:space:]')"
[[ -n "$url" && -n "$key" ]] || { echo "supabase.env is incomplete" >&2; exit 1; }

read -rp "Supabase email: " email
read -rsp "Password: " password
echo

# --data-binary @- keeps the password off the process list, where a plain
# --data argument would expose it to anyone running ps.
token="$(
  printf '{"email":%s,"password":%s}' \
    "$(printf '%s' "$email" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$(printf '%s' "$password" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" |
  curl -s "$url/auth/v1/token?grant_type=password" \
    -H "apikey: $key" -H 'Content-Type: application/json' \
    --data-binary @- |
  python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))'
)"
unset password

if [[ -z "$token" ]]; then
  echo "Sign-in failed — check the email and password." >&2
  exit 1
fi

fetch() {
  curl -s "$url/rest/v1/$1?select=*" \
    -H "apikey: $key" -H "Authorization: Bearer $token"
}

if [[ $# -gt 0 ]]; then
  fetch "$1" | python3 -m json.tool
  exit 0
fi

for table in accounts income expenses savings_goals investments debtors \
             creditors bills loans transfers cash_moves debt_payments \
             sip_installments module_events alerts; do
  body="$(fetch "$table")"
  printf '%s' "$body" | python3 -c '
import json, sys
name = sys.argv[1]
raw = sys.stdin.read()
try:
    rows = json.loads(raw)
except Exception:
    print(f"{name:18} — unreadable response: {raw[:80]}")
    sys.exit()
if isinstance(rows, dict):                      # an error object
    print(f"{name:18} — {rows.get('message', rows)}")
elif not rows:
    print(f"{name:18} 0 rows")
else:
    print(f"{name:18} {len(rows)} rows")
    for r in rows:
        data = r.get("data", r)
        label = data.get("name") or data.get("person_name") or \
                data.get("payee") or data.get("lender") or r.get("id", "")
        extra = {k: v for k, v in data.items() if k != "name"}
        print(f"    {label}: {json.dumps(extra, default=str)}")
' "$table"
done
