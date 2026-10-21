#!/usr/bin/env bash
# Rebuilds the local database in the original v1 (flutter_chat_types) shape,
# using the SQL scripts shipped on the `main` branch, and fills it with a
# small, realistic data set. Used to test the v1 -> v2 migration path:
#   tool/v1_fixture.sh && tool/local_db.sh --no-reset
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
V1_REF="${V1_REF:-main}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$ROOT"
supabase db reset --local >/dev/null 2>&1
psql "$DB_URL" -q -c 'DROP SCHEMA chats CASCADE'
for f in 01_database_schema.sql 02_database_trigger.sql 03_database_policy.sql \
         04_storage.sql 05_database_view.sql 99_database_schema_permission.sql; do
    git show "$V1_REF:example/utils/sql/$f" > "$TMP/$f"
    psql "$DB_URL" -v ON_ERROR_STOP=1 -q -o /dev/null -f "$TMP/$f" 2>&1 | { grep -v NOTICE || true; }
done

psql "$DB_URL" -v ON_ERROR_STOP=1 -q <<'SQL'
insert into auth.users (id, email, aud, role) values
 ('a0000000-0000-0000-0000-000000000001','a@t.dev','authenticated','authenticated'),
 ('b0000000-0000-0000-0000-000000000002','b@t.dev','authenticated','authenticated');
update chats.users set "firstName" = 'Alice' where id = 'a0000000-0000-0000-0000-000000000001';
update chats.users set role = 'agent' where id = 'b0000000-0000-0000-0000-000000000002';
insert into chats.rooms (id, type, "userIds", "userRoles", "createdAt", "updatedAt", name) values
 (10, 'direct', '{a0000000-0000-0000-0000-000000000001,b0000000-0000-0000-0000-000000000002}', null, 1700000000000, 1700000500000, null),
 (11, 'group', '{a0000000-0000-0000-0000-000000000001,b0000000-0000-0000-0000-000000000002}', '{"a0000000-0000-0000-0000-000000000001":"admin","b0000000-0000-0000-0000-000000000002":"agent"}', 1700000000000, 1700000600000, 'Old group');
insert into chats.messages (id, "roomId", "authorId", type, text, "createdAt", "updatedAt", status, "repliedMessage") values
 (100, 10, 'a0000000-0000-0000-0000-000000000001', 'text', 'v1 hello', 1700000100000, 1700000100000, 'seen', null),
 (101, 10, 'b0000000-0000-0000-0000-000000000002', 'text', 'v1 reply', 1700000200000, null, 'sent', '{"id":"100"}'),
 (102, 11, 'a0000000-0000-0000-0000-000000000001', 'image', null, 1600000000000, null, 'sent', null);
update chats.messages
set uri = 'http://x/storage/v1/object/authenticated/chats_assets/11/img.png', width = 10, height = 10, size = 5
where id = 102;
SQL
echo "v1 fixture ready"
