#!/usr/bin/env bash
# End-to-end test of example/utils/migrate_storage_uuids.sh on the local
# stack: builds a v1 database with attachments in the old numeric room
# folders, migrates it to v2, moves the attachments and checks objects, URLs
# and the cleanup of chats.room_id_migration_map. --ps runs the PowerShell
# variant. Leaves a migrated database behind: run tool/local_db.sh
# afterwards for a clean one.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DB_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
eval "$(supabase status -o env 2>/dev/null | grep -E '^(API_URL|SERVICE_ROLE_KEY)=')"
export PGPASSWORD=postgres SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY"

fail() { echo "FAIL: $*" >&2; exit 1; }
q() { psql "$DB_URL" -X -At -c "$1" | tr -d '\r'; }
upload() {
    curl -sSf -o /dev/null -X POST -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
         -H 'Content-Type: text/plain' --data "$2" "$API_URL/storage/v1/object/chats_assets/$1"
}
download() {
    curl -sSf -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
         "$API_URL/storage/v1/object/authenticated/chats_assets/$1"
}
# --ps runs the PowerShell variant (Windows) instead of the bash one.
migrate() {
    if [[ "${VARIANT:-}" == ps ]]; then
        local flags=()
        for a in "$@"; do
            case "$a" in -n) flags+=(-dryRun) ;; -y) flags+=(-yes) ;; esac
        done
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File example/utils/migrate_storage_uuids.ps1 \
            -hostname 127.0.0.1 -port 54322 -database postgres -user postgres -apiUrl "$API_URL" "${flags[@]}" \
            | tr -d '\r'
    else
        example/utils/migrate_storage_uuids.sh -h 127.0.0.1 -p 54322 -d postgres -U postgres -a "$API_URL" "$@"
    fi
}
[[ "${1:-}" == --ps ]] && VARIANT=ps

echo "== v1 database with attachments"
tool/v1_fixture.sh
upload 11/img.png 'image bytes'
upload "11/sub/a%20b'.txt" 'nested file'
upload 10/voice.m4a 'voice bytes'
psql "$DB_URL" -X -q -c "UPDATE chats.messages SET uri = 'http://x/storage/v1/object/authenticated/chats_assets/10/voice.m4a', type = 'audio', duration = 1 WHERE id = 100"

echo "== v2 migration"
tool/local_db.sh --no-reset >/dev/null
NEW_10="$(q 'SELECT new_id FROM chats.room_id_migration_map WHERE old_id = 10')"
NEW_11="$(q 'SELECT new_id FROM chats.room_id_migration_map WHERE old_id = 11')"

echo "== dry run changes nothing"
migrate -n | tee /dev/stderr | grep -q 'dry run: 2 room(s), 3 object(s)' || fail "dry run summary"
[[ "$(q "SELECT count(*) FROM storage.objects WHERE bucket_id = 'chats_assets' AND name ~ '^[0-9]+/'")" == 3 ]] || fail "dry run moved objects"

echo "== resume after a run stopped half way (one object already copied)"
curl -sSf -o /dev/null -X POST -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
     -H 'Content-Type: application/json' \
     --data "{\"bucketId\":\"chats_assets\",\"sourceKey\":\"11/img.png\",\"destinationKey\":\"$NEW_11/img.png\"}" \
     "$API_URL/storage/v1/object/copy"
migrate -y

echo "== checks"
[[ "$(q "SELECT count(*) FROM storage.objects WHERE bucket_id = 'chats_assets' AND name ~ '^[0-9]+/'")" == 0 ]] || fail "old objects left"
[[ "$(download "$NEW_11/img.png")" == 'image bytes' ]] || fail "img.png not in the new folder"
[[ "$(download "$NEW_11/sub/a%20b'.txt")" == 'nested file' ]] || fail "nested file not in the new folder"
[[ "$(download "$NEW_10/voice.m4a")" == 'voice bytes' ]] || fail "voice.m4a not in the new folder"
[[ "$(q "SELECT count(*) FROM chats.messages WHERE source ~ '/chats_assets/[0-9]+/'")" == 0 ]] || fail "messages still point at old folders"
[[ "$(q "SELECT source FROM chats.messages WHERE type = 'image'")" == *"/chats_assets/$NEW_11/img.png" ]] || fail "image URL not rewritten"
[[ "$(q "SELECT \"lastMessages\" -> 0 ->> 'source' FROM chats.rooms WHERE id = '$NEW_11'")" == *"/chats_assets/$NEW_11/img.png" ]] || fail "lastMessages snapshot not refreshed"
[[ "$(q "SELECT to_regclass('chats.room_id_migration_map') IS NULL")" == t ]] || fail "map not dropped"

echo "== a second run has nothing to do"
migrate -y | grep -q "doesn't exist" || fail "second run"

echo "storage migration OK"
