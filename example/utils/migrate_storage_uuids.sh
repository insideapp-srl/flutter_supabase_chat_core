#!/bin/bash
# Moves the chat attachments uploaded by v1 to the v2 room folders, after
# 01_database_schema.sql migrated a v1 database:
#   chats_assets/<old numeric room id>/<file> -> chats_assets/<room uuid>/<file>
#
#   ./migrate_storage_uuids.sh -h <host> -p <port> -d <database> -U <user> \
#       -a <api url> [-b <bucket>] [-n] [-y]
#
#   -a  Supabase API URL: https://<project-ref>.supabase.co, or the Kong URL
#       of a self-hosted instance (local stack: http://127.0.0.1:54321)
#   -b  attachments bucket (default chats_assets)
#   -n  dry run: only print what would be moved
#   -y  drop chats.room_id_migration_map at the end without asking
#
# Reads the database password from PGPASSWORD and the service role (or
# secret) key from SUPABASE_SERVICE_ROLE_KEY, asking for them when unset.
#
# For each room still using its old folder it:
#   1. copies the objects to the new folder (Storage API, server side);
#   2. rewrites the URLs of the room in one transaction: messages.source and
#      rooms."imageUrl" (the "lastMessages" snapshot follows by trigger);
#   3. deletes the old objects, only once every copy exists.
# A failure stops the script and nothing is lost: run it again, it resumes
# from where it stopped. Until a room is moved its old URLs keep working
# (the storage policies resolve the old folders through
# chats.room_id_migration_map). When no room is left, the map is no longer
# needed and is dropped (asking first, unless -y).
#
# Requires: psql and curl.
set -euo pipefail

BUCKET="chats_assets"
DRY_RUN=0
ASSUME_YES=0
while getopts h:p:d:U:a:b:ny flag; do
    case "${flag}" in
        h) DB_HOST=${OPTARG} ;;
        p) DB_PORT=${OPTARG} ;;
        d) DB_NAME=${OPTARG} ;;
        U) DB_USER=${OPTARG} ;;
        a) API_URL=${OPTARG%/} ;;
        b) BUCKET=${OPTARG} ;;
        n) DRY_RUN=1 ;;
        y) ASSUME_YES=1 ;;
        *) echo "usage: $0 -h host -p port -d database -U user -a api_url [-b bucket] [-n] [-y]" >&2; exit 1 ;;
    esac
done
: "${DB_HOST:?-h host is required}" "${DB_PORT:?-p port is required}" \
  "${DB_NAME:?-d database is required}" "${DB_USER:?-U user is required}" \
  "${API_URL:?-a api url is required}"

for tool in psql curl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool not found: install it and re-run" >&2; exit 1; }
done
[[ "$BUCKET" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "invalid bucket name: $BUCKET" >&2; exit 1; }

if [[ -z "${PGPASSWORD:-}" ]]; then
    read -rsp "Password for $DB_USER@$DB_HOST: " PGPASSWORD
    echo
    export PGPASSWORD
fi
if [[ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
    read -rsp "Service role (or secret) key: " SUPABASE_SERVICE_ROLE_KEY
    echo
fi

# File names travel through psql's output: keep them UTF-8 whatever the
# locale. Strips the \r of the Windows psql builds (Git Bash), harmless
# elsewhere.
export PGCLIENTENCODING=UTF8
sql() {
    psql -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME" -U "$DB_USER" \
         -v ON_ERROR_STOP=1 -X -q -At "$@" | tr -d '\r'
}

# Legacy JWT keys go in Authorization too; the new sb_secret_ keys only in
# apikey (the gateway turns them into a service role JWT).
AUTH_HEADERS=(-H "apikey: $SUPABASE_SERVICE_ROLE_KEY")
if [[ "$SUPABASE_SERVICE_ROLE_KEY" == eyJ* ]]; then
    AUTH_HEADERS+=(-H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY")
fi
RESPONSE="$(mktemp)"
trap 'rm -f "$RESPONSE"' EXIT

# POST/DELETE a JSON body to the Storage API, failing with its error message.
storage() {
    local method=$1 path=$2 body=$3 status
    status="$(curl -sS -o "$RESPONSE" -w '%{http_code}' -X "$method" \
        "${AUTH_HEADERS[@]}" -H 'Content-Type: application/json' \
        --data "$body" "$API_URL/storage/v1/$path")"
    if [[ "$status" != 2* ]]; then
        echo "Storage API $method $path failed (HTTP $status): $(cat "$RESPONSE")" >&2
        return 1
    fi
}

if [[ "$(sql -c "SELECT to_regclass('chats.room_id_migration_map') IS NOT NULL")" != "t" ]]; then
    echo "chats.room_id_migration_map doesn't exist: no v1 room to move."
    exit 0
fi

# Rooms with objects in their old folder, or URLs still pointing there.
ROOMS="$(sql <<SQL
SELECT m.old_id || ' ' || m.new_id
FROM chats.room_id_migration_map m
WHERE EXISTS (SELECT 1 FROM storage.objects o
              WHERE o.bucket_id = '$BUCKET' AND o.name LIKE m.old_id || '/%')
   OR EXISTS (SELECT 1 FROM chats.messages x
              WHERE x."roomId" = m.new_id AND x.source LIKE '%/$BUCKET/' || m.old_id || '/%')
   OR EXISTS (SELECT 1 FROM chats.rooms r
              WHERE r.id = m.new_id AND r."imageUrl" LIKE '%/$BUCKET/' || m.old_id || '/%')
ORDER BY m.old_id;
SQL
)"

ROOM_COUNT=0
OBJECT_COUNT=0
while read -r OLD_ID NEW_ID; do
    [[ -z "${OLD_ID:-}" ]] && continue
    # Both come from the map (bigint, uuid): checked anyway, since they are
    # spliced into the SQL below.
    [[ "$OLD_ID" =~ ^[0-9]+$ && "$NEW_ID" =~ ^[0-9a-f-]{36}$ ]] || {
        echo "unexpected map row: $OLD_ID -> $NEW_ID" >&2; exit 1; }
    OLD_PREFIX="$OLD_ID/"
    NEW_PREFIX="$NEW_ID/"

    # Objects of the old folder not copied yet (a previous run may have
    # stopped half way), as Storage API copy requests: Postgres builds the
    # JSON, so any file name is escaped correctly.
    TO_COPY="$(sql <<SQL
SELECT json_build_object('bucketId', o.bucket_id, 'sourceKey', o.name,
                         'destinationKey', '$NEW_PREFIX' || substr(o.name, ${#OLD_PREFIX} + 1))
FROM storage.objects o
WHERE o.bucket_id = '$BUCKET' AND o.name LIKE '$OLD_PREFIX%'
  AND NOT EXISTS (SELECT 1 FROM storage.objects d
                  WHERE d.bucket_id = '$BUCKET'
                    AND d.name = '$NEW_PREFIX' || substr(o.name, ${#OLD_PREFIX} + 1))
ORDER BY o.name;
SQL
)"
    COPIES=0
    [[ -n "$TO_COPY" ]] && COPIES="$(wc -l <<<"$TO_COPY")"
    echo "room $OLD_ID -> $NEW_ID: $COPIES object(s) to copy"
    ROOM_COUNT=$((ROOM_COUNT + 1))
    OBJECT_COUNT=$((OBJECT_COUNT + COPIES))
    [[ $DRY_RUN == 1 ]] && continue

    # 1. Copy.
    while IFS= read -r BODY; do
        [[ -z "$BODY" ]] && continue
        storage POST object/copy "$BODY"
    done <<<"$TO_COPY"

    # 2. Rewrite the URLs of the room, all or nothing.
    sql <<SQL
BEGIN;
UPDATE chats.messages
SET source = replace(source, '/$BUCKET/$OLD_PREFIX', '/$BUCKET/$NEW_PREFIX')
WHERE "roomId" = '$NEW_ID' AND source LIKE '%/$BUCKET/$OLD_PREFIX%';
UPDATE chats.rooms
SET "imageUrl" = replace("imageUrl", '/$BUCKET/$OLD_PREFIX', '/$BUCKET/$NEW_PREFIX')
WHERE id = '$NEW_ID' AND "imageUrl" LIKE '%/$BUCKET/$OLD_PREFIX%';
COMMIT;
SQL

    # 3. Delete the old objects, once every one of them has its copy.
    MISSING="$(sql <<SQL
SELECT count(*) FROM storage.objects o
WHERE o.bucket_id = '$BUCKET' AND o.name LIKE '$OLD_PREFIX%'
  AND NOT EXISTS (SELECT 1 FROM storage.objects d
                  WHERE d.bucket_id = '$BUCKET'
                    AND d.name = '$NEW_PREFIX' || substr(o.name, ${#OLD_PREFIX} + 1));
SQL
)"
    if [[ "$MISSING" != "0" ]]; then
        echo "room $OLD_ID: $MISSING object(s) without a copy, old folder kept" >&2
        exit 1
    fi
    # The Storage API deletes at most 1000 objects per request.
    DELETES="$(sql <<SQL
SELECT json_build_object('prefixes', json_agg(name ORDER BY name))
FROM (SELECT name, (row_number() OVER (ORDER BY name) - 1) / 1000 AS batch
      FROM storage.objects
      WHERE bucket_id = '$BUCKET' AND name LIKE '$OLD_PREFIX%') o
GROUP BY batch ORDER BY batch;
SQL
)"
    while IFS= read -r BODY; do
        [[ -z "$BODY" ]] && continue
        storage DELETE "object/$BUCKET" "$BODY"
    done <<<"$DELETES"
done <<<"$ROOMS"

if [[ $DRY_RUN == 1 ]]; then
    echo "dry run: $ROOM_COUNT room(s), $OBJECT_COUNT object(s) to copy"
    exit 0
fi
echo "moved $ROOM_COUNT room(s), $OBJECT_COUNT object(s) copied in this run"

# Nothing points at the old folders any more: the map is no longer needed.
LEFT="$(sql <<SQL
SELECT count(*) FROM chats.room_id_migration_map m
WHERE EXISTS (SELECT 1 FROM storage.objects o
              WHERE o.bucket_id = '$BUCKET' AND o.name LIKE m.old_id || '/%')
   OR EXISTS (SELECT 1 FROM chats.messages x
              WHERE x."roomId" = m.new_id AND x.source LIKE '%/$BUCKET/' || m.old_id || '/%');
SQL
)"
if [[ "$LEFT" != "0" ]]; then
    echo "$LEFT room(s) still use their old folder: chats.room_id_migration_map kept" >&2
    exit 1
fi
if [[ $ASSUME_YES == 0 ]]; then
    read -rp "Every attachment is in its v2 folder. Drop chats.room_id_migration_map? [y/N] " ANSWER
    [[ "$ANSWER" =~ ^[Yy]$ ]] || { echo "chats.room_id_migration_map kept"; exit 0; }
fi
sql -c 'DROP TABLE chats.room_id_migration_map'
echo "chats.room_id_migration_map dropped"
