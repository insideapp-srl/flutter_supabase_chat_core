#!/usr/bin/env bash
# Resets the local Supabase stack's database (`supabase start` must be
# running) and applies the chat SQL scripts from example/utils/sql exactly
# the way end users apply them, then reloads PostgREST's schema cache.
#
#   tool/local_db.sh            reset + apply
#   tool/local_db.sh --no-reset apply on top of the current database (checks
#                               the scripts are idempotent)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SQL_DIR="$ROOT/example/utils/sql"
DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"

if [[ "${1:-}" != "--no-reset" ]]; then
    (cd "$ROOT" && supabase db reset --local >/dev/null 2>&1)
fi

for f in 01_database_schema.sql 02_database_trigger.sql 03_database_policy.sql \
         04_storage.sql 05_database_view.sql 99_database_schema_permission.sql; do
    echo "applying $f"
    psql "$DB_URL" -v ON_ERROR_STOP=1 -q -o /dev/null -f "$SQL_DIR/$f" 2>&1 \
        | { grep -v -E 'NOTICE|^$' || true; }
done

psql "$DB_URL" -q -c "NOTIFY pgrst, 'reload schema';"

# `supabase db reset` restarts Postgres but not Realtime, whose Postgres
# Changes poller can stay in a degraded "recovery" state afterwards and
# silently stop delivering events. Restart it on a fresh database.
if [[ "${1:-}" != "--no-reset" ]]; then
    REALTIME="$(docker ps --format '{{.Names}}' | grep '^supabase_realtime_' | head -1)"
    if [[ -n "$REALTIME" ]]; then
        docker restart "$REALTIME" >/dev/null
        for _ in $(seq 1 30); do
            curl -sf "http://127.0.0.1:54321/realtime/v1/api/ping" >/dev/null 2>&1 && break
            sleep 1
        done
    fi
fi
echo "done"
