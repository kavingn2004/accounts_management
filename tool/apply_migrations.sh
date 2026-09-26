#!/usr/bin/env bash
# Apply the SQL migrations to a Supabase project.
#
# Every migration is guarded by "if not exists", so running this repeatedly is
# safe — already-applied ones do nothing.
#
# The connection URI contains your database password, which is far more
# powerful than the anon key. Pass it as an argument or in SUPABASE_DB_URL;
# it is never written to a file by this script.
#
#   Supabase -> Settings -> Database -> Connection string -> URI
#
# Usage:
#   ./tool/apply_migrations.sh "postgresql://postgres:PASS@db.xxx.supabase.co:5432/postgres"
#   SUPABASE_DB_URL='postgresql://...' ./tool/apply_migrations.sh
#
# Tip: prefix the command with a space and most shells keep it out of history.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
uri="${1:-${SUPABASE_DB_URL:-}}"

if [[ -z "$uri" ]]; then
  cat >&2 <<'USAGE'
Need a connection URI.

  Supabase -> Settings -> Database -> Connection string -> URI

  ./tool/apply_migrations.sh "postgresql://postgres:PASS@db.xxx.supabase.co:5432/postgres"

Or paste the migration files into the SQL Editor instead — same result, and
the password stays in your browser.
USAGE
  exit 1
fi

command -v psql >/dev/null || { echo "psql is not installed" >&2; exit 1; }

# Only 0004 onward are written to be re-runnable. 0001-0003 build the schema
# from nothing and fail on an existing project — harmlessly, since they only
# create, but there is no reason to run them against a database that is already
# set up. Pass --all to force them anyway (a brand-new project).
if [[ "${2:-}" == '--all' || "${1:-}" == '--all' ]]; then
  files=("$root"/supabase/migrations/*.sql)
else
  files=()
  for f in "$root"/supabase/migrations/*.sql; do
    # Skip a migration whose tables are already present.
    name="$(basename "$f")"
    case "$name" in
      0001_*|0002_*|0003_*)
        if psql "$uri" -Atc \
             "select 1 from pg_tables where schemaname='public' and tablename='accounts'" \
             2>/dev/null | grep -q 1; then
          printf '  %-34s %s\n' "$name" 'skipped (schema already built)'
          continue
        fi
        ;;
    esac
    files+=("$f")
  done
fi

echo "Applying migrations…"
for file in "${files[@]}"; do
  printf '  %-34s' "$(basename "$file")"
  # ON_ERROR_STOP so a broken migration fails loudly instead of half-applying.
  if psql "$uri" -v ON_ERROR_STOP=1 -q -f "$file" >/dev/null 2>"$root/.migrate.err"; then
    echo 'ok'
  else
    echo 'FAILED'
    cat "$root/.migrate.err" >&2
    rm -f "$root/.migrate.err"
    exit 1
  fi
done
rm -f "$root/.migrate.err"

echo
echo "Tables now present:"
psql "$uri" -Atc "
  select tablename
  from pg_tables
  where schemaname = 'public'
  order by tablename;
" | sed 's/^/  /'
