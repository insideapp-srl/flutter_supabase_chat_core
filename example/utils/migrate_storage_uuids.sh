#!/bin/bash
# Moves chats_assets storage objects from their old bigint room-id folder
# (chats_assets/<old numeric id>/...) to the new uuid folder
# (chats_assets/<new uuid>/...) after 01_database_schema.sql converts
# chats.rooms to uuid ids. SQL alone can't rename objects in the storage
# backend, so this is a separate step using the Supabase CLI's Storage API
# (`supabase storage mv`) — run it once, after 01_database_schema.sql,
# during the same maintenance window.
#
# Reads the old-id -> new-id mapping from chats.room_id_migration_map (left
# behind by 01_database_schema.sql for exactly this purpose).
#
# Requires: supabase CLI (logged in), psql, jq.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="$SCRIPT_DIR/project-secrets.local.json"

DB_HOST=""
DB_PORT="5432"
DB_NAME="postgres"
DB_USER="postgres"
DB_PASSWORD=""
PROJECT_REF=""

while getopts h:p:d:U:r: flag; do
    case "${flag}" in
        h) DB_HOST=${OPTARG} ;;
        p) DB_PORT=${OPTARG} ;;
        d) DB_NAME=${OPTARG} ;;
        U) DB_USER=${OPTARG} ;;
        r) PROJECT_REF=${OPTARG} ;;
    esac
done

if [[ -z "$DB_HOST" && -f "$SECRETS_FILE" ]]; then
    echo "No -h given: reading connection info from $SECRETS_FILE"
    DB_HOST="$(jq -r '.db.host' "$SECRETS_FILE")"
    DB_PORT="$(jq -r '.db.port' "$SECRETS_FILE")"
    DB_NAME="$(jq -r '.db.database' "$SECRETS_FILE")"
    DB_USER="$(jq -r '.db.user' "$SECRETS_FILE")"
    DB_PASSWORD="$(jq -r '.db.password' "$SECRETS_FILE")"
    [[ -z "$PROJECT_REF" ]] && PROJECT_REF="$(jq -r '.ref' "$SECRETS_FILE")"
fi

if [[ -z "$DB_HOST" || -z "$PROJECT_REF" ]]; then
    echo "Usage: $0 -h <db-host> -p <db-port> -d <db-name> -U <db-user> -r <project-ref>" >&2
    echo "(or run with no flags from example/utils, if project-secrets.local.json is there)" >&2
    exit 1
fi

if [[ -z "$DB_PASSWORD" ]]; then
    read -rsp "Database password for ${DB_USER}@${DB_HOST}: " DB_PASSWORD
    echo
fi

command -v supabase >/dev/null 2>&1 || {
    echo "supabase CLI not found. See https://supabase.com/docs/guides/cli/getting-started" >&2
    exit 1
}
command -v jq >/dev/null 2>&1 || {
    echo "jq not found. Install it (e.g. 'apt install jq', 'brew install jq') and re-run." >&2
    exit 1
}

echo "Reading the old->new room id mapping from chats.room_id_migration_map..."
MAP_JSON="$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" -U "$DB_USER" -Atc "
    SELECT coalesce(jsonb_agg(jsonb_build_object('old_id', old_id, 'new_id', new_id)), '[]')
    FROM chats.room_id_migration_map;
" 2>/dev/null || echo '[]')"

MAP_COUNT="$(jq 'length' <<<"$MAP_JSON")"
if [[ "$MAP_COUNT" -eq 0 ]]; then
    echo "chats.room_id_migration_map is empty or doesn't exist — nothing to migrate"
    echo "(either this database never had bigint room ids, or 01_database_schema.sql hasn't converted any yet)."
    exit 0
fi

echo "Found $MAP_COUNT room(s) to check for chats_assets objects to move."
echo

MOVED=0
SKIPPED=0
for row in $(jq -c '.[]' <<<"$MAP_JSON"); do
    OLD_ID="$(jq -r '.old_id' <<<"$row")"
    NEW_ID="$(jq -r '.new_id' <<<"$row")"

    LS_OUTPUT="$(supabase storage ls "ss:///chats_assets/${OLD_ID}" --project-ref "$PROJECT_REF" 2>/dev/null || true)"
    if [[ -n "$LS_OUTPUT" ]]; then
        echo "Moving chats_assets/${OLD_ID} -> chats_assets/${NEW_ID}"
        supabase storage mv -r "ss:///chats_assets/${OLD_ID}" "ss:///chats_assets/${NEW_ID}" --project-ref "$PROJECT_REF"
        MOVED=$((MOVED + 1))
    else
        SKIPPED=$((SKIPPED + 1))
    fi
done

echo
echo "Done: moved $MOVED room folder(s), $SKIPPED had no chats_assets objects to move."
